#module DB

import DataStructures
using DataStructures: Accumulator, CircularBuffer, SortedDict, SortedSet
using UnicodePlots: barplot
using BenchmarkTools: prettytime
using Printf: @sprintf
import StaticArrays
using ReadWriteLocks: ReadWriteLock, ReadLock, WriteLock, read_lock, write_lock, lock!, unlock!

# using .Threads: @threads
# macro threads(a); esc(a); end

using Lazy: @forward
import Dates

import ..Utils
using ..Utils: ThreadSafe, Throttle, GCTask, stop

import ..Nostr
import ..Bech32
import ..Fetching

include("sqlite.jl")
include("psql2.jl")

hashfunc(::Type{Nostr.EventId}) = eid->eid.hash[32]
hashfunc(::Type{Nostr.PubKeyId}) = pk->pk.pk[32]
hashfunc(::Type{Tuple{Nostr.PubKeyId, Nostr.EventId}}) = p->p[1].pk[32]

MAX_MESSAGE_SIZE = Ref(300_000) |> ThreadSafe
kindints = [map(Int, collect(instances(Nostr.Kind))); [Nostr.BOOKMARKS, Nostr.HIGHLIGHT]]

term_lines = try parse(Int, strip(read(`tput lines`, String))) catch _ 15 end
threadprogress = Dict{Int, Any}() |> ThreadSafe
PROGRESS_COMPLETE = -1
progress_periodic_update = Throttle(; period=0.2)
function term_progress(fn, cnt, stats, progstr, tstart)
    #return
    tid = Threads.threadid()
    function render()
        bio = IOBuffer()
        Utils.clear_screen(bio)

        m = 1
        for (tid, (fn, cnt)) in sort(collect(threadprogress), by=kv->kv[1])
            Utils.move_cursor(bio, max(term_lines-tid-m, 1), 1)
            print(bio, @sprintf "%2d %9s  %s" tid (cnt == PROGRESS_COMPLETE ? "" : string(cnt)) fn)
        end

        Utils.move_cursor(bio, term_lines-m, 1)
        print(bio, "$(trunc(Int, time()-tstart))s $(progstr) ",
              (@sprintf "gclive: %.1fGB" Base.gc_live_bytes()/1024^3),
              " #msg: $(stats[:msg]) #any: $(stats[:any]) #exceptions: $(stats[:exceptions]) #eventhooks: $(stats[:eventhooks])-$(stats[:eventhooksexecuted]) ")

        Utils.move_cursor(bio, term_lines, 1)

        print(String(take!(bio)))
        flush(stdout)
    end
    lock(threadprogress) do threadprogress
        threadprogress[tid] = (cnt == PROGRESS_COMPLETE ? "" : fn, cnt)
        cnt == PROGRESS_COMPLETE ? render() : progress_periodic_update(render)
    end
end

SHOW_PROGRESS = Ref(true)
PRINT_EXCEPTIONS = Ref(false)

function incr(v::Ref; by=1)
    by == 0 && return
    v[] += by
end
function incr(v::ThreadSafe; by=1)
    by == 0 && return
    lock(v) do v
        incr(v; by)
    end
end
decr(v; by=1) = incr(v; by=-by)

scope_times = Dict{Symbol, Float64}()
function scope(body::Function, sym::Symbol)
    r = @timed body()
    incr(scope_times, sym; by=r.time)
    r.value
end

stat_names = Set([:msg,
                  :verifyerr,
                  :seen,
                  :seenearly,
                  :parseerr,
                  :exceptions,
                  :any,
                  :tags,
                  :pubnotes,
                  :directmsgs,
                  :eventdeletions,
                  :reactions,
                  :replies,
                  :mentions,
                  :reposts,
                  :pubkeys,
                  :users,
                  :zaps,
                  :satszapped,
                  :eventhooks,
                  :eventhooksexecuted,
                  :scheduledhooks,
                  :scheduledhooksexecuted,
                  :scoresexpired,
                 ])

function load_stats(stats_filename::String)
    stats = Dict{Symbol, Int}()
    isfile(stats_filename) && open(stats_filename) do f
        for (k, v) in JSON.parse(read(f, String))
            stats[Symbol(k)] = v 
        end
    end
    stats
end

Base.@kwdef struct StorageCommons{DBDict}
    params = (; DBDict)

    dbargs = (; rootdirectory=abspath("."))

    tstart = Ref(time())

    exceptions = CircularBuffer(500) |> ThreadSafe

    latest_file_positions = DBDict(String, Int, "latest_file_positions"; dbargs...) |> ThreadSafe

    stats_filename = "$(dbargs.rootdirectory)/stats.json"
    stats = load_stats(stats_filename) |> ThreadSafe
    stats_saving_periodically = Throttle(; period=0.2)

    message_processors = SortedDict{Symbol, Function}() |> ThreadSafe

    gc_task = Ref{Union{Nothing, GCTask}}(nothing)
end

function load_stats(commons::StorageCommons)
    lock(commons.stats) do stats
        merge!(stats, load_stats(commons.stats_filename))
    end
end

function save_stats(commons::StorageCommons)
    lock(commons.stats) do stats
        open(commons.stats_filename * ".tmp", "w+") do f
            write(f, JSON.json(stats))
        end
        mv(commons.stats_filename * ".tmp", commons.stats_filename; force=true)
    end
end

function import_msg_into_storage(msg::String, commons::StorageCommons)
    commons.stats_saving_periodically() do 
        save_stats(commons)
    end
end

abstract type EventStorage end

function incr(stats::Dict{Symbol, Int}, prop::Symbol; by=1)
    stats[prop] = get(stats, prop, 0) + by
    nothing
end

function incr(est::EventStorage, prop::Symbol; by=1)
    incr(est.commons.stats, prop; by)
end

function catch_exception(body::Function, est::EventStorage, args...)
    try
        body()
    catch ex
        incr(est, :exceptions)
        push!(est.commons.exceptions, (Dates.now(), ex, args...))
        PRINT_EXCEPTIONS[] && print_exceptions()
    end
end

struct OpenedFile
    io::IOStream
    t_last_write::Ref{Float64}
end

Base.@kwdef struct DeduplicatedEventStorage <: EventStorage
    dbargs = (; )
    commons = StorageCommons{SqliteDict}(; dbargs)

    deduped_events = ShardedSqliteSet(Nostr.EventId, "deduped_events"; dbargs...,
                                      init_queries=["create table if not exists kv (
                                                       event_id blob not null,
                                                       pubkey blob not null,
                                                       kind int not null,
                                                       created_at int not null,
                                                       processed_at int not null,
                                                       file_position int not null,
                                                       times_seen int not null
                                                     )",
                                                    "create index if not exists kv_event_id_idx on kv (event_id asc)",
                                                    "create index if not exists kv_created_at_idx on kv (created_at asc)",
                                                   ])

    files = Dict{String, OpenedFile}() |> ThreadSafe

    max_open_file_age = 2*60
    close_files_periodically = Throttle(; period=10.0)
end

Base.@kwdef struct CacheStorage{SCommons, DBDict, DBSet, MembershipDBDict} <: EventStorage
    params = (; SCommons, DBDict, DBSet, MembershipDBDict)

    dbargs = (; )
    commons = SCommons(; dbargs)

    readonly = Ref(false)

    pqconnstr::Union{String,Symbol}

    verification_enabled = true

    auto_fetch_missing_events = false

    event_processors = SortedDict{Symbol, Function}() |> ThreadSafe

    tidcnts = Accumulator{Int, Int}() |> ThreadSafe

    periodic_task_running = Ref(false)
    periodic_task = Ref{Union{Nothing, Task}}(nothing)

    # event_ids      = DBSet(Nostr.EventId, "event_ids"; dbargs...)
    events = DBDict(Nostr.EventId, Nostr.Event, "events"; dbargs...)
    # events = DBDict(Nostr.EventId, Nostr.Event, "events"; dbargs...,
    #                 keycolumn="id", 
    #                 valuecolumn="json_build_object('id', encode(id, 'hex'), 'pubkey', encode(pubkey, 'hex'), 'created_at', created_at, 'kind', kind, 'tags', tags, 'content', content, 'sig', encode(sig, 'hex'))::text")

    event_created_at = DBDict(Nostr.EventId, Int, "event_created_at"; dbargs...,
                                 keycolumn="event_id", valuecolumn="created_at",
                                 init_queries=["!create table if not exists event_created_at (
                                                  event_id blob not null,
                                                  created_at int not null,
                                                  primary key (event_id)
                                                )",
                                               "create index if not exists event_created_at_created_at_idx on event_created_at (created_at desc)"])

    pubkey_events = DBSet(Nostr.PubKeyId, "pubkey_events"; dbargs..., # no replies, no mentions
                             init_queries=["!create table if not exists pubkey_events (
                                              pubkey blob not null,
                                              event_id blob not null,
                                              created_at int not null,
                                              is_reply int not null
                                            )",
                                           "create index if not exists pubkey_events_pubkey_idx on pubkey_events (pubkey asc)",
                                           "create index if not exists pubkey_events_created_at_idx on pubkey_events (created_at asc)",
                                           "create index if not exists pubkey_events_pubkey_created_at_idx on pubkey_events (pubkey, created_at)",
                                           "create index if not exists pubkey_events_pubkey_is_reply_idx on pubkey_events (pubkey, is_reply)",
                                          ])
    pubkey_ids = DBSet(Nostr.PubKeyId, "pubkey_ids"; dbargs...)

    pubkey_followers = DBSet(Nostr.PubKeyId, "pubkey_followers"; dbargs...,
                                init_queries=["!create table if not exists pubkey_followers (
                                                 pubkey blob not null,
                                                 follower_pubkey blob not null,
                                                 follower_contact_list_event_id blob not null
                                               )",
                                              "create index if not exists pubkey_followers_pubkey_idx on pubkey_followers (pubkey asc)",
                                              "create index if not exists pubkey_followers_follower_pubkey_idx on pubkey_followers (follower_pubkey asc)",
                                              "create index if not exists pubkey_followers_follower_contact_list_event_id_idx on pubkey_followers (follower_contact_list_event_id asc)"])
    pubkey_followers_cnt = DBDict(Nostr.PubKeyId, Int, "pubkey_followers_cnt"; dbargs...,
                                  init_extra_indexes=["create index if not exists pubkey_followers_cnt_value_idx on pubkey_followers_cnt (value desc)"])

    contact_lists = DBDict(Nostr.PubKeyId, Nostr.EventId, "contact_lists"; dbargs...)
    meta_data = DBDict(Nostr.PubKeyId, Nostr.EventId, "meta_data"; dbargs...)

    event_stats_init_queries = table ->
    ["!create table if not exists $table (
         event_id blob not null,
         author_pubkey blob not null,
         created_at int not null,
         likes int not null,
         replies int not null,
         mentions int not null,
         reposts int not null,
         zaps int not null,
         satszapped int not null,
         score int not null,
         score24h int not null,
         primary key (event_id)
     )",
     "create index if not exists $(table)_author_pubkey_idx on $table (author_pubkey asc)",
     "create index if not exists $(table)_created_at_idx on $table (created_at desc)",
     "create index if not exists $(table)_score_idx on $table (score desc)",
     "create index if not exists $(table)_score24h_idx on $table (score24h desc)",
     "create index if not exists $(table)_satszapped_idx on $table (satszapped desc)",
     "create index if not exists $(table)_created_at_satszapped_idx on $table (created_at, satszapped desc)",
     "create index if not exists $(table)_created_at_score24h_idx on $table (created_at, score24h desc)",
    ]
    event_stats = DBSet(Nostr.EventId, "event_stats"; dbargs...,
                        init_queries=event_stats_init_queries("event_stats"))
    # event_stats_by_pubkey = DBSet(Nostr.PubKeyId, "event_stats_by_pubkey"; dbargs...,
    #                               init_queries=event_stats_init_queries("event_stats_by_pubkey"))

    event_replies = DBSet(Nostr.EventId, "event_replies"; dbargs...,
                             init_queries=["!create table if not exists event_replies (
                                              event_id blob not null,
                                              reply_event_id blob not null,
                                              reply_created_at int not null
                                            )",
                                           "create index if not exists event_replies_event_id_idx on event_replies (event_id asc)",
                                           "create index if not exists event_replies_reply_created_at_idx on event_replies (reply_created_at asc)"])
    event_thread_parents = DBDict(Nostr.EventId, Nostr.EventId, "event_thread_parents"; dbargs...)

    event_hooks = DBSet(Nostr.EventId, "event_hooks"; dbargs...,
                           init_queries=["!create table if not exists event_hooks (
                                            event_id blob not null,
                                            funcall text not null
                                          )",
                                         "create index if not exists event_hooks_event_id_idx on event_hooks (event_id asc)"])

    scheduled_hooks = DBSet(Int, "scheduled_hooks"; dbargs...,
                                 init_queries=["!create table if not exists scheduled_hooks (
                                                  execute_at int not null,
                                                  funcall text not null
                                               )",
                                               "create index if not exists scheduled_hooks_execute_at_idx on scheduled_hooks (execute_at asc)"])

    event_pubkey_actions = DBSet(Nostr.EventId, "event_pubkey_actions"; dbargs...,
                                    init_queries=["!create table if not exists event_pubkey_actions (
                                                     event_id blob not null,
                                                     pubkey blob not null,
                                                     created_at int not null,
                                                     updated_at int not null,
                                                     replied int not null,
                                                     liked int not null,
                                                     reposted int not null,
                                                     zapped int not null,
                                                     primary key (event_id, pubkey)
                                                  )",
                                                  "create index if not exists event_pubkey_actions_event_idx on event_pubkey_actions (event_id asc)",
                                                  "create index if not exists event_pubkey_actions_pubkey_idx on event_pubkey_actions (pubkey asc)",
                                                  "create index if not exists event_pubkey_actions_created_at_idx on event_pubkey_actions (created_at desc)",
                                                  "create index if not exists event_pubkey_actions_updated_at_idx on event_pubkey_actions (updated_at desc)",
                                                 ])

    event_pubkey_action_refs = DBSet(Nostr.EventId, "event_pubkey_action_refs"; dbargs...,
                                        init_queries=["!create table if not exists event_pubkey_action_refs (
                                                         event_id blob not null,
                                                         ref_event_id blob not null,
                                                         ref_pubkey blob not null,
                                                         ref_created_at int not null,
                                                         ref_kind int not null
                                                      )",
                                                      "create index if not exists event_pubkey_action_refs_event_id_idx on event_pubkey_action_refs (event_id asc)",
                                                      "create index if not exists event_pubkey_action_refs_ref_event_id_idx on event_pubkey_action_refs (ref_event_id asc)",
                                                      "create index if not exists event_pubkey_action_refs_ref_created_at_idx on event_pubkey_action_refs (ref_created_at desc)",
                                                      "create index if not exists event_pubkey_action_refs_event_id_ref_pubkey_idx on event_pubkey_action_refs (event_id asc, ref_pubkey asc)",
                                                      "create index if not exists event_pubkey_action_refs_event_id_ref_kind_idx on event_pubkey_action_refs (event_id asc, ref_kind asc)",
                                                     ])

    deleted_events = DBDict(Nostr.EventId, Nostr.EventId, "deleted_events"; dbargs...,
                            keycolumn="event_id", valuecolumn="deletion_event_id")

    mute_list   = DBDict(Nostr.PubKeyId, Nostr.EventId, "mute_list"; dbargs...)
    mute_list_2 = DBDict(Nostr.PubKeyId, Nostr.EventId, "mute_list_2"; dbargs...)
    mute_lists  = DBDict(Nostr.PubKeyId, Nostr.EventId, "mute_lists"; dbargs...)
    allow_list  = DBDict(Nostr.PubKeyId, Nostr.EventId, "allow_list"; dbargs...)
    parameterized_replaceable_list = DBSet(Nostr.PubKeyId, "parameterized_replaceable_list"; dbargs...,
                                              init_queries=["!create table if not exists parameterized_replaceable_list (
                                                            pubkey blob not null,
                                                            identifier text not null,
                                                            created_at int not null,
                                                            event_id blob not null
                                                            )",
                                                            "create index if not exists parameterized_replaceable_list_pubkey_idx on     parameterized_replaceable_list (pubkey asc)",
                                                            "create index if not exists parameterized_replaceable_list_identifier_idx on parameterized_replaceable_list (identifier asc)",
                                                            "create index if not exists parameterized_replaceable_list_created_at_idx on parameterized_replaceable_list (created_at desc)"])

    pubkey_directmsgs = DBSet(Nostr.PubKeyId, "pubkey_directmsgs"; dbargs...,
                                 keycolumn="receiver", valuecolumn="event_id",
                                 init_queries=["!create table if not exists pubkey_directmsgs (
                                                  receiver blob not null,
                                                  sender blob not null,
                                                  created_at int not null,
                                                  event_id blob not null
                                               )",
                                               "create index if not exists pubkey_directmsgs_receiver_idx   on pubkey_directmsgs (receiver asc)",
                                               "create index if not exists pubkey_directmsgs_sender_idx     on pubkey_directmsgs (sender asc)",
                                               "create index if not exists pubkey_directmsgs_receiver_sender_idx on pubkey_directmsgs (receiver asc, sender asc)",
                                               "create index if not exists pubkey_directmsgs_receiver_event_id_idx on pubkey_directmsgs (receiver asc, event_id asc)",
                                               "create index if not exists pubkey_directmsgs_created_at_idx on pubkey_directmsgs (created_at desc)"])

    pubkey_directmsgs_cnt = DBSet(Nostr.PubKeyId, "pubkey_directmsgs_cnt"; dbargs...,
                                     keycolumn="receiver", valuecolumn="cnt",
                                     init_queries=["!create table if not exists pubkey_directmsgs_cnt (
                                                      receiver blob not null,
                                                      sender blob,
                                                      cnt int not null,
                                                      latest_at int not null,
                                                      latest_event_id blob not null
                                                   )",
                                                   "create index if not exists pubkey_directmsgs_cnt_receiver_idx on pubkey_directmsgs_cnt (receiver asc)",
                                                   "create index if not exists pubkey_directmsgs_cnt_sender_idx   on pubkey_directmsgs_cnt (sender asc)",
                                                   "create index if not exists pubkey_directmsgs_cnt_receiver_sender_idx on pubkey_directmsgs_cnt (receiver asc, sender asc)",
                                                  ])
    pubkey_directmsgs_cnt_lock = ReentrantLock()

    zap_receipts = DBSet(Nostr.EventId, "og_zap_receipts"; dbargs...,
                           init_queries=["!create table if not exists og_zap_receipts (
                                         zap_receipt_id blob not null,
                                         created_at int not null,
                                         sender blob,
                                         receiver blob,
                                         amount_sats int not null,
                                         event_id blob
                                         )",
                                         "create index if not exists og_zap_receipts_sender_idx on og_zap_receipts (sender asc)",
                                         "create index if not exists og_zap_receipts_receiver_idx on og_zap_receipts (receiver asc)",
                                         "create index if not exists og_zap_receipts_created_at_idx on og_zap_receipts (created_at asc)",
                                         "create index if not exists og_zap_receipts_amount_sats_idx on og_zap_receipts (amount_sats desc)",
                                         "create index if not exists og_zap_receipts_event_id_idx on og_zap_receipts (event_id asc)",
                                        ])
    # ext:

    pubkey_zapped = DBSet(Nostr.PubKeyId, "pubkey_zapped"; dbargs...,
                             init_queries=["!create table if not exists pubkey_zapped (
                                              pubkey blob not null,
                                              zaps int not null,
                                              satszapped int not null,
                                              primary key (pubkey)
                                            )",
                                           "create index if not exists pubkey_zapped_zaps_idx on pubkey_zapped (zaps desc)",
                                           "create index if not exists pubkey_zapped_satszapped_idx on pubkey_zapped (satszapped desc)"])

    score_expiry = DBSet(Nostr.EventId, "score_expiry"; dbargs...,
                            init_queries=["!create table if not exists score_expiry (
                                             event_id blob not null,
                                             author_pubkey blob not null,
                                             change int not null,
                                             expire_at int not null
                                           )",
                                          "create index if not exists score_expiry_event_id_idx on score_expiry (event_id asc)",
                                          "create index if not exists score_expiry_expire_at_idx on score_expiry (expire_at asc)"])

    relays = DBDict(String, Int, "relays"; dbargs...,
                    init_queries=["!create table if not exists relays (
                                     url text not null,
                                     times_referenced int not null,
                                     primary key (url)
                                   )",
                                  "create index if not exists relays_times_referenced_idx on relays (times_referenced desc)",
                                 ])

    # app settings:
    app_settings = MembershipDBDict(Nostr.PubKeyId, Nostr.Event, "app_settings"; connsel=pqconnstr,
                                       init_extra_columns=", accessed_at int8, created_at int8, event_id bytea",
                                       init_extra_indexes=["create index if not exists app_settings_accessed_at_idx on app_settings (accessed_at desc)"])

    app_settings_event_id = MembershipDBDict(Nostr.PubKeyId, Nostr.EventId, "app_settings_event_id"; connsel=pqconnstr,
                                              init_extra_columns=", created_at int8, accessed_at int8",
                                              init_extra_indexes=["create index if not exists app_settings_event_id_created_at_idx  on app_settings_event_id (created_at desc)",
                                                                  "create index if not exists app_settings_event_id_accessed_at_idx on app_settings_event_id (accessed_at desc)",
                                                                 ])
 
    app_settings_log = MembershipDBDict(Nostr.PubKeyId, Nostr.Event, "app_settings_log"; connsel=pqconnstr,
                                           init_queries=["create table if not exists app_settings_log (
                                                         pubkey bytea not null,
                                                         event json not null,
                                                         accessed_at int8 not null
                                                         )",
                                                         "create index if not exists app_settings_log_pubkey_idx on app_settings_log (pubkey asc)",
                                                         "create index if not exists app_settings_log_accessed_at_idx on app_settings_log (accessed_at desc)",
                                                        ])

    # notifications:
    notification_settings = MembershipDBDict(Nostr.PubKeyId, Bool, "notification_settings"; connsel=pqconnstr,
                                             init_queries=["create table if not exists notification_settings (
                                                           pubkey bytea not null,
                                                           type varchar(100) not null,
                                                           enabled bool not null
                                                           )",
                                                           "create index if not exists notification_settings_pubkey_idx on notification_settings (pubkey asc)",
                                                          ])

    pubkey_notifications_seen = MembershipDBDict(Nostr.PubKeyId, Int, "pubkey_notifications_seen"; connsel=pqconnstr,
                                                keycolumn="pubkey", valuecolumn="seen_until",
                                                init_extra_indexes=["create index if not exists pubkey_notifications_seen_seen_until_idx on pubkey_notifications_seen (seen_until desc)"])

    pubkey_notifications = DBSet(Nostr.PubKeyId, "pubkey_notifications"; dbargs...,
                                    init_queries=["!create table if not exists pubkey_notifications (
                                                     pubkey blob not null,
                                                     created_at int not null,
                                                     type int not null,
                                                     arg1 blob not null,
                                                     arg2 blob,
                                                     arg3 text,
                                                     arg4 text
                                                   )",
                                                  "create index if not exists pubkey_notifications_pubkey_idx on pubkey_notifications (pubkey asc)",
                                                  "create index if not exists pubkey_notifications_pubkey_created_at_idx on pubkey_notifications (pubkey asc, created_at desc)",
                                                  "create index if not exists pubkey_notifications_created_at_idx on pubkey_notifications (created_at desc)",
                                                  "create index if not exists pubkey_notifications_type_idx on pubkey_notifications (type desc)",
                                                  "create index if not exists pubkey_notifications_arg1_idx on pubkey_notifications (arg1 desc)",
                                                 ])

    pubkey_notification_cnts_init = "!create table if not exists pubkey_notification_cnts (
      pubkey blob not null,
      $(join(["type$(i|>Int) int not null default 0" for i in instances(DB.NotificationType)], ',')),
      primary key (pubkey)
    )
    "
    pubkey_notification_cnts = DBSet(Nostr.PubKeyId, "pubkey_notification_cnts"; dbargs...,
                                       keycolumn="pubkey",
                                       init_queries=[pubkey_notification_cnts_init,
                                                     "create index if not exists pubkey_notification_cnts_pubkey_idx on pubkey_notification_cnts (pubkey asc)",
                                                     ])

    notification_processors = SortedDict{Symbol, Function}() |> ThreadSafe

    notification_counter_update_lock = ReentrantLock()

    # media:
    media = DBDict(String, Int, "media"; dbargs...,
                       keycolumn="url", valuecolumn="imported_at",
                       init_queries=["!create table if not exists media (
                                        url text not null,
                                        media_url text not null,
                                        size text not null,
                                        animated int not null,
                                        imported_at int not null,
                                        download_duration number not null,
                                        width int not null,
                                        height int not null,
                                        mimetype text not null,
                                        category text not null,
                                        category_confidence number not null,
                                        duration number not null default 0.0,
                                        primary key (url)
                                     )",
                                     "create index if not exists media_media_url_idx on media (media_url asc)",
                                     "create index if not exists media_url_size_animated_idx on media (url asc, size asc, animated asc)",
                                     "create index if not exists media_imported_at_idx on media (imported_at desc)",
                                     "create index if not exists media_category_idx on media (category asc)",
                                    ])

    event_media = DBSet(Nostr.EventId, "event_media"; dbargs...,
                           keycolumn="event_id", valuecolumn="url",
                           init_queries=["!create table if not exists event_media (
                                           event_id blob not null,
                                           url text not null
                                         )",
                                         "create index if not exists event_media_event_id_idx on event_media (event_id asc)",
                                         "create index if not exists event_media_url_idx      on event_media (url asc)",
                                        ])

    preview = DBDict(String, Int, "preview"; dbargs...,
                     keycolumn="url", valuecolumn="imported_at",
                     init_queries=["!create table if not exists preview (
                                       url text not null,
                                       imported_at int not null,
                                       download_duration number not null,
                                       mimetype text not null,
                                       category text,
                                       category_confidence number,
                                       md_title text,
                                       md_description text,
                                       md_image text,
                                       icon_url text,
                                       primary key (url)
                                   )",
                                   "create index if not exists preview_imported_at_idx on preview (imported_at desc)",
                                   "create index if not exists preview_category_idx on preview (category asc)",
                                  ])

    event_preview = DBSet(Nostr.EventId, "event_preview"; dbargs...,
                             keycolumn="event_id", valuecolumn="url",
                             init_queries=["!create table if not exists event_preview (
                                           event_id blob not null,
                                           url text not null
                                           )",
                                           "create index if not exists event_preview_event_id_idx on event_preview (event_id asc)",
                                           "create index if not exists event_preview_url_idx      on event_preview (url asc)",
                                          ])

    event_hashtags = DBSet(Nostr.EventId, "event_hashtags"; dbargs...,
                              keycolumn="event_id", valuecolumn="hashtag",
                              init_queries=["!create table if not exists event_hashtags (
                                               event_id blob not null,
                                               hashtag text not null,
                                               created_at int not null
                                            )",
                                            "create index if not exists event_hashtags_event_id_idx   on event_hashtags (event_id asc)",
                                            "create index if not exists event_hashtags_hashtag_idx    on event_hashtags (hashtag asc)",
                                            "create index if not exists event_hashtags_created_at_idx on event_hashtags (created_at desc)",
                                           ])
    hashtags = DBDict(String, Int, "hashtags"; dbargs...,
                      keycolumn="hashtag", valuecolumn="score",
                      init_queries=["!create table if not exists hashtags (
                                       hashtag text not null,
                                       score int not null,
                                       primary key (hashtag)
                                    )",
                                    "create index if not exists hashtags_score_idx   on hashtags (score desc)",
                                   ])

    media_uploads = MembershipDBDict(Nostr.PubKeyId, Nostr.Event, "media_uploads"; connsel=pqconnstr,
                                        init_queries=["create table if not exists media_uploads (
                                                      pubkey bytea not null,
                                                      type varchar(50) not null,
                                                      key jsonb not null,
                                                      created_at int8 not null,
                                                      path text not null, 
                                                      size int8 not null, 
                                                      mimetype varchar(200) not null,
                                                      category varchar(100) not null, 
                                                      category_confidence real not null, 
                                                      width int8 not null, 
                                                      height int8 not null,

                                                      sha256 bytea,
                                                      moderation_category varchar
                                                      )",
                                                      "create index if not exists media_uploads_pubkey_idx on media_uploads (pubkey asc)",
                                                      "create index if not exists media_uploads_created_at_idx on media_uploads (created_at desc)",
                                                      "create index if not exists media_uploads_sha256_idx on media_uploads (sha256 asc)",
                                                      "create index if not exists media_uploads_path_idx on media_uploads (path asc)",
                                                     ])

    dyn = Dict()
end

function close_conns(est)
    for a in propertynames(est)
        v = getproperty(est, a)
        if v isa ShardedDBDict
            println("closing $a")
            close(v)
        end
    end
end

function Base.close(est::DeduplicatedEventStorage)
    close_conns(est)
    close_conns(est.commons)
end

function Base.close(est::CacheStorage)
    close_conns(est)
    close_conns(est.commons)
    est.periodic_task_running[] = false
    wait(est.periodic_task[])
end

function Base.delete!(est::EventStorage)
    close(est)
    run(`sh -c "rm -frv $(est.dbargs.rootdirectory)"`)
end

function event_stats_cb(est::CacheStorage, e::Nostr.Event, prop, increment)
    exe(est.event_stats,           "update event_stats           set $prop = $prop + ?2 where event_id = ?1", e.id, increment)
    # exe(est.event_stats_by_pubkey, "update event_stats_by_pubkey set $prop = $prop + ?2 where event_id = ?1", e.id, increment)
end

function event_hook_execute(est::CacheStorage, e::Nostr.Event, funcall::Tuple)
    catch_exception(est, e, funcall) do
        funcname, args... = funcall
        eval(Symbol(funcname))(est, e, args...)
        incr(est, :eventhooksexecuted)
    end
end

function event_hook(est::CacheStorage, eid::Nostr.EventId, funcall::Tuple)
    if eid in est.events
        e = est.events[eid]
        event_hook_execute(est, e, Tuple(JSON.parse(JSON.json(funcall))))
    else
        exe(est.event_hooks, @sql("insert into event_hooks (event_id, funcall) values (?1, ?2)"), eid, JSON.json(funcall))
    end
    incr(est, :eventhooks)
end

function scheduled_hook_execute(est::CacheStorage, funcall::Tuple)
    catch_exception(est, funcall) do
        funcname, args... = funcall
        eval(Symbol(funcname))(est, args...)
        incr(est, :scheduledhooksexecuted)
    end
end

function schedule_hook(est::CacheStorage, execute_at::Int, funcall::Tuple)
    if execute_at <= time()
        scheduled_hook_execute(est, funcall)
    else
        exec(est.scheduled_hooks, @sql("insert into scheduled_hooks (execute_at, funcall) values (?1, ?2)"), (execute_at, JSON.json(funcall)))
    end
    incr(est, :scheduledhooks)
end

function track_user_stats(body::Function, est::CacheStorage, pubkey::Nostr.PubKeyId)
    function isuser()
        pubkey in est.meta_data && pubkey in est.contact_lists && 
        est.contact_lists[pubkey] in est.events &&
        length([t for t in est.events[est.contact_lists[pubkey]].tags
                if length(t.fields) >= 2 && t.fields[1] == "p"]) > 0
    end
    isuser_pre = isuser()
    body()
    isuser_post = isuser()
    if     !isuser_pre &&  isuser_post; incr(est, :users)
    elseif  isuser_pre && !isuser_post; incr(est, :users; by=-1)
    end
end

function event_pubkey_action(est::CacheStorage, eid::Nostr.EventId, re::Nostr.Event, action::Symbol)
    exe(est.event_pubkey_actions, @sql("insert into event_pubkey_actions values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) on conflict do nothing"), 
        eid, re.pubkey, re.created_at, 0, false, false, false, false)
    exe(est.event_pubkey_actions, "update event_pubkey_actions set $(action) = 1, updated_at = ?3 where event_id = ?1 and pubkey = ?2", 
        eid, re.pubkey, re.created_at)
    exe(est.event_pubkey_action_refs, @sql("insert into event_pubkey_action_refs values (?1, ?2, ?3, ?4, ?5)"), 
        eid, re.id, re.pubkey, re.created_at, re.kind)
end

function zap_sender(zap_receipt::Nostr.Event)
    for tag in zap_receipt.tags
        if length(tag.fields) >= 2 && tag.fields[1] == "description"
            return Nostr.PubKeyId(JSON.parse(tag.fields[2])["pubkey"])
        end
    end
    error("invalid zap receipt event")
end

function zap_receiver(zap_receipt::Nostr.Event)
    for tag in zap_receipt.tags
        if length(tag.fields) >= 2 && tag.fields[1] == "p"
            return Nostr.PubKeyId(tag.fields[2])
        end
    end
    error("invalid zap receipt event")
end

function parse_bolt11(b::String)
    if startswith(b, "lnbc")
        amount_digits = Char[]
        unit = nothing
        for i in 5:length(b)
            c = b[i]
            if isdigit(c)
                push!(amount_digits, c)
            else
                unit = c
                break
            end
        end
        amount_sats = parse(Int, join(amount_digits)) * 100_000_000
        if     unit == 'm'; amount_sats = amount_sats ÷ 1_000
        elseif unit == 'u'; amount_sats = amount_sats ÷ 1_000_000
        elseif unit == 'n'; amount_sats = amount_sats ÷ 1_000_000_000
        elseif unit == 'p'; amount_sats = amount_sats ÷ 1_000_000_000_000
        end
        amount_sats
    else
        nothing
    end
end

MAX_SATSZAPPED = Ref(1_100_000)

re_hashref = r"\#\[([0-9]*)\]"
re_mention = r"\bnostr:((note|npub|naddr|nevent|nprofile)1\w+)\b"

function for_mentiones(body::Function, est::CacheStorage, e::Nostr.Event; pubkeys_in_content=true, resolve_parametrized_replaceable_events=true)
    content =
    if     e.kind == Int(Nostr.TEXT_NOTE) || e.kind == Int(Nostr.LONG_FORM_CONTENT)
        e.content
    elseif e.kind == Int(Nostr.REPOST)
        try JSON.parse(e.content)["content"] catch _ return end
    else
        return
    end
    mentiontags = Set()
    for m in eachmatch(re_hashref, e.content)
        ref = 1 + try parse(Int, m.captures[1]) catch _ continue end
        ref <= length(e.tags) || continue
        tag = e.tags[ref]
        length(tag.fields) >= 2 || continue
        push!(mentiontags, tag)
    end
    function push_parametrized_replaceable_event(pubkey, kind, identifier)
        for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events], 
                              @sql("select event_id from parametrized_replaceable_events where pubkey = ?1 and kind = ?2 and identifier = ?3 limit 1"), 
                              (pubkey, kind, identifier))
            push!(mentiontags, Nostr.TagAny(["e", Nostr.hex(Nostr.EventId(eid))]))
        end
    end
    for tag in e.tags
        if length(tag.fields) >= 4 && tag.fields[4] == "mention"
            if tag.fields[1] == "a"
                if resolve_parametrized_replaceable_events
                    ps = split(tag.fields[2], ':')
                    push_parametrized_replaceable_event(Nostr.PubKeyId(string(ps[2])), parse(Int, ps[1]), string(ps[3]))
                else
                    push!(mentiontags, tag)
                end
            else
                push!(mentiontags, tag)
            end
        end
    end
    for m in eachmatch(re_mention, e.content)
        s = m.captures[1]
        if startswith(s, "naddr")
            catch_exception(est, e, m) do
                if !isnothing(local r = try Dict(Bech32.nip19_decode(s)) catch _ end)
                    if resolve_parametrized_replaceable_events
                        push_parametrized_replaceable_event(r[Bech32.Author], r[Bech32.Kind], r[Bech32.Special])
                    else
                        push!(mentiontags, Nostr.TagAny(["a", "$(r[Bech32.Kind]):$(Nostr.hex(r[Bech32.Author])):$(r[Bech32.Special])"]))
                    end
                end
            end
        else
            catch_exception(est, e, m) do
                if !isnothing(local id = try Bech32.nip19_decode_wo_tlv(s) catch _ end)
                    id isa Nostr.PubKeyId || id isa Nostr.EventId || return
                    id isa Nostr.PubKeyId && !pubkeys_in_content && return
                    push!(mentiontags, Nostr.TagAny([id isa Nostr.PubKeyId ? "p" : "e", Nostr.hex(id)]))
                end
            end
        end
    end
    for tag in unique([Nostr.TagAny(t.fields[1:2]) for t in mentiontags])
        body(tag)
    end
end

function event_from_msg(m)
    t, md, d = m
    if d != nothing && length(d) >= 3 && d[1] == "EVENT"
        return (isnothing(md) ? nothing : get(md, "relay_url", nothing)), Nostr.dict2event(d[3])
    end
    nothing, nothing
end

function verify(est::EventStorage, e)
    (e.created_at < time()+300) || return false

    if !Nostr.verify(e)
        incr(est, :verifyerr)
        return false
    end
    
    return true
end

function dedup_message_log_filename(root_dir::String, created_at::Int)::String
    date = Dates.unix2datetime(created_at)
    dir = @sprintf "%s/%d/%02d" root_dir Dates.year(date) Dates.month(date)
    isdir(dir) || mkpath(dir)
    @sprintf "%s/%02d.log" dir Dates.day(date)
end

function import_msg_into_storage(msg::String, est::DeduplicatedEventStorage; force=false)
    import_msg_into_storage(msg, est.commons)

    if !force
        # fast event id extraction to skip further processing early
        eid = extract_event_id(msg)
        if !isnothing(eid) && !isempty(exe(est.deduped_events, @sql("select 1 from kv where event_id = ?1 limit 1"), 
                                           eid))
            incr(est, :seenearly)
            # exe(est.deduped_events, # this is considerably slowing down import
            #     @sql("update kv set times_seen = times_seen + 1 where event_id = ?1"), 
            #     eid)
            return false
        end
        incr(est, :seen)
    end

    relay_url, e = try
        event_from_msg(JSON.parse(msg))
    catch _
        incr(est, :parseerr)
        rethrow()
    end

    e isa Nostr.Event || return false
    verify(est, e) || return false

    incr(est, :any)

    fn = dedup_message_log_filename(est.dbargs.rootdirectory * "/messages", e.created_at)

    pos = lock(est.files) do files
        fout = get!(files, fn) do
            OpenedFile(open(fn, "a"), Ref(time()))
            # open(fn * ".inuse") do; end
        end
        pos = position(fout.io)
        println(fout.io, msg)
        flush(fout.io)
        fout.t_last_write[] = time()

        est.close_files_periodically() do
            closed_files = String[]
            for (fn, f) in collect(files)
                if time()-f.t_last_write[] >= est.max_open_file_age
                    close(f.io)
                    # rm(fn * ".inuse")
                    push!(closed_files, fn)
                end
            end
            for fn in closed_files
                delete!(est.files, fn)
            end
        end

        isempty(exe(est.deduped_events, @sql("select 1 from kv where event_id = ?1 limit 1"), eid)) ? pos : nothing
    end

    isnothing(pos) || exe(est.deduped_events,
                          @sql("insert into kv (event_id, pubkey, kind, created_at, processed_at, file_position, times_seen) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)"), 
                          e.id, e.pubkey, e.kind, e.created_at, trunc(Int, time()), pos, 1)

    lock(est.commons.message_processors) do message_processors
        for func in values(message_processors)
            catch_exception(est, func, msg) do
                Base.invokelatest(func, est, msg)
            end
        end
    end

    true
end

function prune(est::DeduplicatedEventStorage, keep_after::Int)
    exec(est.deduped_events, @sql("delete from kv where created_at < ?1"), (keep_after,))
end

fetch_requests = Dict() |> ThreadSafe
fetch_requests_periodic = Throttle(; period=2.0)
FETCH_REQUEST_DURATION = Ref(60)

function fetch(filter)
    lock(fetch_requests) do fetch_requests
        haskey(fetch_requests, filter) && return
        Fetching.fetch(filter)
        fetch_requests[filter] = time()
        fetch_requests_periodic() do
            flushed = Set()
            for (k, t) in collect(fetch_requests)
                time() - t > FETCH_REQUEST_DURATION[] && push!(flushed, k)
            end
            for k in flushed
                delete!(fetch_requests, k)
            end
        end
    end
end

function fetch_user_metadata(est::CacheStorage, pubkey::Nostr.PubKeyId)
    kinds = []
    pubkey in est.meta_data || push!(kinds, Int(Nostr.SET_METADATA))
    pubkey in est.contact_lists || push!(kinds, Int(Nostr.CONTACT_LIST))
    isempty(kinds) || fetch((; kinds, authors=[pubkey]))
end

function fetch_event(est::CacheStorage, eid::Nostr.EventId)
    # eid in est.event_ids || fetch((; ids=[eid]))
end

function fetch_missing_events(est::CacheStorage, e::Nostr.Event)
    est.auto_fetch_missing_events && catch_exception(est, msg) do
        for tag in e.tags
            if length(tag.fields) >= 2
                if tag.fields[1] == "e"
                    if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
                        fetch_event(est, eid)
                    end
                elseif tag.fields[1] == "p"
                    if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                        fetch_user_metadata(est, pk)
                    end
                end
            end
        end
    end
end

event_stats_fields = "event_id,
                      author_pubkey,
                      created_at,
                      likes, 
                      replies, 
                      mentions, 
                      reposts, 
                      zaps, 
                      satszapped, 
                      score, 
                      score24h"
event_stats_fields_cnt = length(split(event_stats_fields, ','))
event_stats_insert_q = register_query("insert into event_stats           ($event_stats_fields) values (?1, ?2,  ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)")
# event_stats_by_pubkey_insert_q = register_query("insert into event_stats_by_pubkey ($event_stats_fields) values (?2, ?1,  ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)")

already_imported_check_lock = ReentrantLock()
parameterized_replaceable_list_lock = ReentrantLock()

function import_msg_into_storage(msg::String, est::CacheStorage; force=false, disable_daily_stats=false)
    length(msg) > MAX_MESSAGE_SIZE[] && return false

    import_msg_into_storage(msg, est.commons)

    relay_url, e = try
        event_from_msg(JSON.parse(msg))
    catch _
        incr(est, :parseerr)
        rethrow()
    end

    e isa Nostr.Event || return false

    import_event(est, e; force, disable_daily_stats, relay_url)
end

function import_event(est::CacheStorage, e::Nostr.Event; force=false, disable_daily_stats=false, relay_url=nothing)
    est.readonly[] && return false

    lock(est.tidcnts) do tidcnts; tidcnts[Threads.threadid()] += 1; end

    est.verification_enabled && !verify(est, e) && return false

    should_import = lock(already_imported_check_lock) do
        if e.id in est.events || !ext_preimport_check(est, e)
            false
        else
            # push!(est.event_ids, e.id)
            est.events[e.id] = e
            true
        end
    end

    e.kind in kindints || (30000 <= e.kind < 40000) || return false

    (force || should_import) || return false

    lock(est.event_processors) do event_processors
        for func in values(event_processors)
            catch_exception(est, func, e) do
                Base.invokelatest(func, e)
            end
        end
    end

    incr(est, :any)

    est.event_created_at[e.id] = e.created_at

    if !isnothing(relay_url)
        est.dyn[:event_relay][e.id] = relay_url
    end

    if !(e.pubkey in est.pubkey_ids)
        push!(est.pubkey_ids, e.pubkey)
        incr(est, :pubkeys)
        exe(est.pubkey_followers_cnt, @sql("insert into pubkey_followers_cnt (key, value) values (?1,  ?2) on conflict do nothing"), e.pubkey, 0)
        est.auto_fetch_missing_events && fetch_user_metadata(est, e.pubkey)
        ext_pubkey(est, e)
    end


    ext_preimport(est, e)

    begin
        local is_pubkey_event = false
        local is_reply = false
        if e.kind == Int(Nostr.TEXT_NOTE)
            is_pubkey_event = true
            for tag in e.tags
                if length(tag.fields) >= 2 && tag.fields[1] == "e"
                    is_reply = !(length(tag.fields) >= 4 && tag.fields[4] == "mention")
                    break
                end
            end
        elseif e.kind == Int(Nostr.REPOST)
            is_pubkey_event = true
        end
        if is_pubkey_event
            exe(est.pubkey_events, @sql("insert into pubkey_events (pubkey, event_id, created_at, is_reply) values (?1, ?2, ?3, ?4)"),
                e.pubkey, e.id, e.created_at, is_reply)
            # catch_exception(est, :import_recent_events) do
            #     re = est.dyn[:recent_events]
            #     lock(write_lock(re.rwlock)) do
            #         push!(re.ss, (e.created_at, trunc(Int, time()), is_reply, e.pubkey, e.id))
            #         while length(re.ss) > re.capacity[]
            #             delete!(re.ss, last(re.ss))
            #         end
            #     end
            # end
        end
    end

    incr(est, :tags; by=length(e.tags))

    # disable_daily_stats || catch_exception(est, e.id) do
    #     lock(est.commons.stats) do _
    #         d = string(Dates.Date(Dates.now()))
    #         if !dyn_exists(est, :daily_stats, :human_event, d, e.pubkey)
    #             dyn_insert(est, :daily_stats, :human_event, d, e.pubkey)
    #             dyn_inc(est, :daily_stats, :active_users, d)
    #             ext_is_human(est, e.pubkey) && dyn_inc(est, :daily_stats, :active_humans, d)
    #         end
    #     end
    # end

    catch_exception(est, e.id) do
        if e.kind == Int(Nostr.TEXT_NOTE) || e.kind == Int(Nostr.LONG_FORM_CONTENT)
            for (tbl, q, key_vals) in [(est.event_stats,           event_stats_insert_q,           (e.id,     e.pubkey)),
                                       # (est.event_stats_by_pubkey, event_stats_by_pubkey_insert_q, (e.pubkey,     e.id)),
                                      ]
                args = [key_vals..., e.created_at]
                append!(args, [0 for _ in 1:(event_stats_fields_cnt-length(args))])
                exe(tbl, q, args...)
            end
        end
    end

    catch_exception(est, e.id) do
        if     e.kind == Int(Nostr.SET_METADATA)
            track_user_stats(est, e.pubkey) do
                k = e.pubkey
                if !haskey(est.meta_data, k) || (e.created_at > est.events[est.meta_data[k]].created_at)
                    est.meta_data[k] = e.id
                    ext_metadata_changed(est, e)
                    update_pubkey_ln_address(est, e.pubkey)
                end
            end
        elseif e.kind == Int(Nostr.CONTACT_LIST)
            track_user_stats(est, e.pubkey) do
                if !haskey(est.contact_lists, e.pubkey) || (e.created_at > est.events[est.contact_lists[e.pubkey]].created_at)
                    import_contact_list(est, e)
                end
            end
            # try
            #     for relay_url in collect(keys(JSON.parse(e.content)))
            #         register_relay(est, relay_url)
            #     end
            # catch _ end
        elseif e.kind == Int(Nostr.REACTION)
            incr(est, :reactions)
            for tag in e.tags
                if tag.fields[1] == "e"
                    if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
                        c = e.content
                        if isempty(c) || c[1] in "🤙+❤️"
                            ext_is_hidden(est, e.id) || event_hook(est, eid, (:event_stats_cb, :likes, +1))
                            event_pubkey_action(est, eid, e, :liked)
                            ext_reaction(est, e, eid)
                        end
                    end
                end
            end

            fetch_missing_events(est, e)

        elseif e.kind == Int(Nostr.TEXT_NOTE)
            incr(est, :pubnotes)

            ext_text_note(est, e)

            function parse_eid(tag)
                if length(tag.fields) >= 4 
                    if     tag.fields[1] == "e"
                        return (try Nostr.EventId(tag.fields[2]) catch _ end)
                    elseif tag.fields[1] == "a" 
                        kind, pk, identifier = map(string, split(tag.fields[2], ':'))
                        kind = parse(Int, kind)
                        pk = Nostr.PubKeyId(pk)
                        for (eid,) in exec(est.dyn[:parametrized_replaceable_events], 
                                           @sql("select event_id from parametrized_replaceable_events where pubkey = ?1 and kind = ?2 and identifier = ?3 limit 1"), 
                                           (pk, kind, identifier))
                            return Nostr.EventId(eid)
                        end
                    end
                end
                nothing
            end

            parent_eid = nothing
            for tag in e.tags
                if length(tag.fields) >= 4 && tag.fields[4] == "reply"
                    reid = parse_eid(tag)
                    if !isnothing(reid)
                        parent_eid = reid
                    end
                end
            end
            isnothing(parent_eid) && for tag in e.tags
                if length(tag.fields) >= 4 && tag.fields[4] == "root"
                    reid = parse_eid(tag)
                    if !isnothing(reid)
                        parent_eid = reid
                        break
                    end
                end
            end
            isnothing(parent_eid) && for tag in e.tags
                if length(tag.fields) >= 2 && (tag.fields[1] == "e" || tag.fields[1] == "a") && (length(tag.fields) < 4 || tag.fields[4] != "mention")
                    reid = parse_eid(tag)
                    if !isnothing(reid)
                        parent_eid = reid
                    end
                end
            end
            if !isnothing(parent_eid)
                incr(est, :replies)
                ext_is_hidden(est, e.id) || !is_trusted_user(est, e.pubkey) || event_hook(est, parent_eid, (:event_stats_cb, :replies, +1))
                exe(est.event_replies, @sql("insert into event_replies (event_id, reply_event_id, reply_created_at) values (?1, ?2, ?3)"),
                    parent_eid, e.id, e.created_at)
                event_pubkey_action(est, parent_eid, e, :replied)
                est.event_thread_parents[e.id] = parent_eid
                ext_reply(est, e, parent_eid)
            end

            fetch_missing_events(est, e)

        elseif e.kind == Int(Nostr.DIRECT_MESSAGE)
            import_directmsg(est, e)

        elseif e.kind == Int(Nostr.EVENT_DELETION)
            for tag in e.tags
                if length(tag.fields) >= 2 && tag.fields[1] == "e"
                    if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
                        if eid in est.events
                            de = est.events[eid]
                            if de.pubkey == e.pubkey
                                incr(est, :eventdeletions)
                                est.deleted_events[eid] = e.id
                            end
                        end
                    end
                end
            end
        elseif e.kind == Int(Nostr.REPOST)
            incr(est, :reposts)
            for tag in e.tags
                if tag.fields[1] == "e"
                    if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
                        ext_is_hidden(est, e.id) || event_hook(est, eid, (:event_stats_cb, :reposts, +1))
                        event_pubkey_action(est, eid, e, :reposted)
                        ext_repost(est, e, eid)
                        break
                    end
                end
            end

            fetch_missing_events(est, e)

        elseif e.kind == Int(Nostr.ZAP_RECEIPT)
            # TODO zap auth
            amount_sats = 0
            parent_eid = nothing
            zapped_pk = nothing
            description = nothing
            for tag in e.tags
                if length(tag.fields) >= 2
                    if tag.fields[1] == "e"
                        parent_eid = try Nostr.EventId(tag.fields[2]) catch _ end
                    elseif tag.fields[1] == "p"
                        zapped_pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end
                    elseif tag.fields[1] == "bolt11"
                        b = tag.fields[2]
                        if !isnothing(local amount = parse_bolt11(b))
                            if amount <= MAX_SATSZAPPED[]
                                amount_sats = amount
                            end
                        end
                    elseif tag.fields[1] == "description"
                        description = try JSON.parse(tag.fields[2]) catch _ nothing end
                    end
                end
            end
            if amount_sats > 0 && !isnothing(description) && !isnothing(zapped_pk)
                zapper_ok = Ref(false)
                catch_exception(est, :zapper_check) do # TODO: move to bg task
                    if zapped_pk in est.meta_data
                        mdeid = est.meta_data[zapped_pk]
                        if mdeid in est.events
                            md = est.events[mdeid]
                            d = JSON.parse(md.content)
                            if !isnothing(local lnurl =
                                          if haskey(d, "lud16")
                                              name, domain = split(strip(d["lud16"]), '@')
                                              "https://$(domain)/.well-known/lnurlp/$name"
                                          elseif haskey(d, "lud06")
                                              String(Bech32.decode("lnurl", d["lud06"]))
                                          else
                                              nothing
                                          end)
                                dd = JSON.parse(String(HTTP.request("GET", lnurl;
                                                                    retry=false, connect_timeout=10, readtimeout=10, proxy=Main.PROXY).body))
                                if haskey(dd, "nostrPubkey")
                                    zapper_ok[] = Nostr.PubKeyId(dd["nostrPubkey"]) == e.pubkey
                                end
                            end
                        end
                    end
                end

                if zapper_ok[]
                    incr(est, :zaps)
                    incr(est, :satszapped; by=amount_sats)
                    if !isnothing(parent_eid)
                        event_hook(est, parent_eid, (:event_stats_cb, :zaps, +1))
                        event_pubkey_action(est, parent_eid, 
                                            Nostr.Event(e.id, zap_sender(e), e.created_at, e.kind, 
                                                        e.tags, e.content, e.sig),
                                            :zapped)
                        ext_zap(est, e, parent_eid, amount_sats)
                    end
                    ext_pubkey_zap(est, e, zapped_pk, amount_sats)
                end
            end
        elseif e.kind == Int(Nostr.MUTE_LIST)
            est.mute_list[e.pubkey] = e.id
        elseif e.kind == Int(Nostr.CATEGORIZED_PEOPLE)
            for tag in e.tags
                if length(tag.fields) >= 2
                    if tag.fields[1] == "d" && tag.fields[2] == "mute"
                        est.mute_list_2[e.pubkey] = e.id
                        break
                    elseif tag.fields[1] == "d" && tag.fields[2] == "mutelists"
                        est.mute_lists[e.pubkey] = e.id
                        break
                    elseif tag.fields[1] == "d" && tag.fields[2] == "allowlist"
                        est.allow_list[e.pubkey] = e.id
                        break
                    else tag.fields[1] == "d"
                        identifier = tag.fields[2]
                        lock(parameterized_replaceable_list_lock) do
                            DB.exe(est.parameterized_replaceable_list, @sql("delete from parameterized_replaceable_list where pubkey = ?1 and identifier = ?2"), e.pubkey, identifier)
                            DB.exe(est.parameterized_replaceable_list, @sql("insert into parameterized_replaceable_list values (?1,?2,?3,?4)"), e.pubkey, identifier, e.created_at, e.id)
                        end
                        break
                    end
                end
            end
        elseif e.kind == Int(Nostr.RELAY_LIST_METADATA)
            if !haskey(est.dyn[:relay_list_metadata], e.pubkey) || est.events[est.dyn[:relay_list_metadata][e.pubkey]].created_at < e.created_at
                est.dyn[:relay_list_metadata][e.pubkey] = e.id
            end
        elseif e.kind == Int(Nostr.BOOKMARKS)
            if !haskey(est.dyn[:bookmarks], e.pubkey) || est.events[est.dyn[:bookmarks][e.pubkey]].created_at < e.created_at
                est.dyn[:bookmarks][e.pubkey] = e.id
            end
        elseif e.kind == Int(Nostr.LONG_FORM_CONTENT)
            ext_long_form_note(est, e)
        end
    end

    catch_exception(est, e.id) do
        if 30000 <= e.kind < 40000
            for tag in e.tags
                if length(tag.fields) >= 2 && tag.fields[1] == "d"
                    identifier = tag.fields[2]
                    lock(parameterized_replaceable_list_lock) do
                        # TODO check created_at
                        DB.exec(est.dyn[:parametrized_replaceable_events], @sql("delete from parametrized_replaceable_events where pubkey = ?1 and kind = ?2 and identifier = ?3"), (e.pubkey, e.kind, identifier))
                        DB.exec(est.dyn[:parametrized_replaceable_events], @sql("insert into parametrized_replaceable_events values (?1,?2,?3,?4,?5)"), (e.pubkey, e.kind, identifier, e.id, e.created_at))
                    end
                    break
                end
            end
        end
    end

    for (funcall,) in exe(est.event_hooks, @sql("select funcall from event_hooks where event_id = ?1"), e.id)
        event_hook_execute(est, e, Tuple(JSON.parse(funcall)))
    end
    exe(est.event_hooks, @sql("delete from event_hooks where event_id = ?1"), e.id)

    return true
end

function import_contact_list(est::CacheStorage, e::Nostr.Event; notifications=true, newonly=false)
    old_follows = Set{Nostr.PubKeyId}()

    if !newonly
        if haskey(est.contact_lists, e.pubkey)
            for tag in est.events[est.contact_lists[e.pubkey]].tags
                if length(tag.fields) >= 2 && tag.fields[1] == "p"
                    follow_pubkey = try Nostr.PubKeyId(tag.fields[2]) catch _ continue end
                    push!(old_follows, follow_pubkey)
                end
            end
        end
    end

    est.contact_lists[e.pubkey] = e.id

    new_follows = Set{Nostr.PubKeyId}()
    for tag in e.tags
        if length(tag.fields) >= 2 && tag.fields[1] == "p"
            follow_pubkey = try Nostr.PubKeyId(tag.fields[2]) catch _ continue end
            push!(new_follows, follow_pubkey)
        end
    end

    for follow_pubkey in new_follows
        follow_pubkey in old_follows && continue
        exe(est.pubkey_followers, @sql("insert into pubkey_followers (pubkey, follower_pubkey, follower_contact_list_event_id) values (?1, ?2, ?3)"),
            follow_pubkey, e.pubkey, e.id)
        exe(est.pubkey_followers_cnt, @sql("update pubkey_followers_cnt set value = value + 1 where key = ?1"),
            follow_pubkey)
        notifications && notification(est, follow_pubkey, e.created_at, NEW_USER_FOLLOWED_YOU, e.pubkey)
    end
    for follow_pubkey in old_follows
        follow_pubkey in new_follows && continue
        # exe(est.pubkey_followers, @sql("delete from pubkey_followers where pubkey = ?1 and follower_pubkey = ?2 and follower_contact_list_event_id = ?3"),
        #     follow_pubkey, e.pubkey, est.contact_lists[e.pubkey])
        exe(est.pubkey_followers, @sql("delete from pubkey_followers where pubkey = ?1 and follower_pubkey = ?2"),
            follow_pubkey, e.pubkey)
        exe(est.pubkey_followers_cnt, @sql("update pubkey_followers_cnt set value = value - 1 where key = ?1"),
            follow_pubkey)
        notifications && notification(est, follow_pubkey, e.created_at, USER_UNFOLLOWED_YOU, e.pubkey)
    end
end

function import_directmsg(est::CacheStorage, e::Nostr.Event)
    incr(est, :directmsgs)
    for tag in e.tags
        if length(tag.fields) >= 2 && tag.fields[1] == "p"
            if !isnothing(local receiver = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                hidden = ext_is_hidden(est, e.pubkey) || try Base.invokelatest(Main.App.is_hidden, est, receiver, :content, e.pubkey) catch _ false end
                # @show (receiver, e.pubkey, hidden)
                if !hidden
                    lock(est.pubkey_directmsgs_cnt_lock) do
                        isempty(exe(est.pubkey_directmsgs, @sql("select 1 from pubkey_directmsgs where receiver = ?1 and event_id = ?2 limit 1"), receiver, e.id)) &&
                        exe(est.pubkey_directmsgs, @sql("insert into pubkey_directmsgs values (?1, ?2, ?3, ?4)"), receiver, e.pubkey, e.created_at, e.id)

                        cond = "receiver = ?1 and (case when ?2::bytea is null then sender is null else sender = ?2 end)"
                        for sender in [nothing, e.pubkey]
                            # if receiver in [Main.test_pubkeys[:pedja]]
                            #     @show e
                            # end
                            if isempty(exe(est.pubkey_directmsgs_cnt, "select * from pubkey_directmsgs_cnt where $cond limit 1", receiver, sender))
                                exe(est.pubkey_directmsgs_cnt, "insert into pubkey_directmsgs_cnt values (?1, ?2, ?3, ?4, ?5)", receiver, sender, 0, e.created_at, e.id)
                            end
                            exe(est.pubkey_directmsgs_cnt, "update pubkey_directmsgs_cnt set cnt = cnt + ?3 where $cond", receiver, sender, +1)
                            r = exe(est.pubkey_directmsgs_cnt, "select latest_at from pubkey_directmsgs_cnt where $cond limit 1", receiver, sender)
                            if !isempty(r)
                                prev_latest_at = r[1][1]
                                if e.created_at >= prev_latest_at
                                    exe(est.pubkey_directmsgs_cnt, "update pubkey_directmsgs_cnt set latest_at = ?3, latest_event_id = ?4 where $cond", receiver, sender, e.created_at, e.id)
                                end
                            end
                        end
                    end
                end

                break
            end
        end
    end
end

function run_scheduled_hooks(est::CacheStorage)
    for (ctid, funcall) in exec(est.scheduled_hooks, @sql("select ctid, funcall from scheduled_hooks where execute_at <= ?1"), (trunc(Int, time()),))
        scheduled_hook_execute(est, Tuple(JSON.parse(funcall)))
        exec(est.scheduled_hooks, @sql("delete from scheduled_hooks where ctid = ?1"), (string(ctid),))
    end
end

function prune(deduped_storage::DeduplicatedEventStorage, cache_storage::CacheStorage, keep_after::Int)
    # WIP
    @threads for dbconn in deduped_storage.events.dbconns
        eids = [Nostr.EventId(eid) for eid in exe(dbconn, @sql("select event_id from kv where created_at < ?1"), (keep_after,))]
        for eid in eids
            # delete!(cache_storage.event_ids, eid)
            delete!(cache_storage.events, eid)
            exec(cache_storage.pubkey_followers, @sql("delete from kv where follower_contact_list_event_id = ?1"), (eid,))
            exec(cache_storage.event_hooks, @sql("delete from kv where event_id = ?1"), (eid,))
        end

        # cache_storage.pubkey_ids?
        #
        for c in [cache_storage.event_stats]
            exec(c, @sql("delete from kv where created_at < ?1"), (keep_after,))
        end
        exec(cache_storage.event_replies, @sql("delete from kv where reply_created_at < ?1"), (keep_after,))

        # cache_storage.contact_lists ?
        # cache_storage.meta_data ?

        # cache_storage.event_thread_parents ?
    end
end

function dump_to_directory(ssd::ShardedDBDict{K, V}, target_dir) where {K, V}
    for (i, dbconn) in enumerate(ssd.dbconns)
        lock(dbconn) do dbconn
            dbfn = @sprintf "%s/%02x.sqlite" target_dir i
            println("writing to ", dbfn)
            isfile(dbfn) && rm(dbfn)
            exe(dbconn, "vacuum into '$dbfn'")
            sleep(0.1)
        end
    end
end

function dump_to_directory(est::EventStorage, target_dir)
    # TBD
    for a in propertynames(est)
        v = getproperty(est, a)
        if v isa ShardedSqliteDict
            println("dumping $a")
            #dump_to_directory(v, target_dir)
        end
    end
end

function vacuum(est::EventStorage)
    for a in propertynames(est)
        v = getproperty(est, a)
        if v isa ShardedSqliteDict
            println("vacuuming $a")
            for dbconn in v.dbconns
                exe(dbconn, "vacuum")
            end
        end
    end
end

# function vacuum_some_tables(est::CacheStorageSqlite)
#     for ssd in [
#                 est.event_hooks,
#                 est.meta_data,
#                 est.contact_lists,
#                ]
#         @time for dbconn in ssd.dbconns
#             DB.exe(dbconn, "vacuum")
#         end
#     end
# end

print_exceptions_lock = ReentrantLock()
chunked_reading_lock = ReentrantLock()

function print_exceptions()
    lock(print_exceptions_lock) do
        @show Threads.threadid()
        Utils.print_exceptions()
    end
end

function init(commons::StorageCommons, running)
    isdir(commons.dbargs.rootdirectory) || mkpath(commons.dbargs.rootdirectory)

    for prop in stat_names
        haskey(commons.stats, prop) || (commons.stats[prop] = 0)
    end
    load_stats(commons)

    commons.tstart[] = time()

    commons.gc_task[] = GCTask(; period=15)
    nothing
end

function init(est::DeduplicatedEventStorage, running=Ref(true))
    init(est.commons, running)
end

function init(est::CacheStorage, running=Ref(true); noperiodic=false)
    init(est.commons, running)

    ext_init(est)
##
    # est.dyn[:dyn] = est.params.DBSet(Nostr.EventId, "dyn"; est.dbargs...,
    #                                     init_queries=["!create table if not exists dyn (
    #                                                   c1, c2, c3, c4, c5
    #                                                   )",
    #                                                   "create index if not exists dyn_c1 on dyn (c1 asc)",
    #                                                   "create index if not exists dyn_c2 on dyn (c2 asc)",
    #                                                   "create index if not exists dyn_c3 on dyn (c3 asc)",
    #                                                   "create index if not exists dyn_c4 on dyn (c4 asc)",
    #                                                   "create index if not exists dyn_c5 on dyn (c5 asc)",
    #                                                  ])
##
    est.dyn[:pubkey_ln_address] = est.params.DBDict(Nostr.PubKeyId, String, "pubkey_ln_address"; est.dbargs...,
                                                    keycolumn="pubkey",
                                                    valuecolumn="ln_address",
                                                    init_extra_indexes=["create index if not exists pubkey_ln_address_ln_address_idx on pubkey_ln_address (ln_address asc)",
                                                                       ])
##
    est.dyn[:relay_list_metadata] = est.params.DBDict(Nostr.PubKeyId, Nostr.EventId, "relay_list_metadata"; est.dbargs...,
                                                      keycolumn="pubkey",
                                                      valuecolumn="event_id")
##
    est.dyn[:bookmarks] = est.params.DBDict(Nostr.PubKeyId, Nostr.EventId, "bookmarks"; est.dbargs...,
                                            keycolumn="pubkey",
                                            valuecolumn="event_id")
##
    est.dyn[:event_relay] = est.params.DBDict(Nostr.EventId, String, "event_relay"; est.dbargs...,
                                              keycolumn="event_id",
                                              valuecolumn="relay_url")
##
    est.dyn[:parametrized_replaceable_events] = est.params.DBSet(Nostr.PubKeyId, "parametrized_replaceable_events"; est.dbargs...,
                                                                 init_queries=["!create table if not exists parametrized_replaceable_events (
                                                                               pubkey blob not null,
                                                                               kind int not null,
                                                                               identifier text not null,
                                                                               event_id blob not null,
                                                                               created_at int not null
                                                                               )",
                                                                               "create index if not exists parametrized_replaceable_events_pubkey_idx     on parametrized_replaceable_events (pubkey asc)",
                                                                               "create index if not exists parametrized_replaceable_events_kind_idx       on parametrized_replaceable_events (kind asc)",
                                                                               "create index if not exists parametrized_replaceable_events_identifier_idx on parametrized_replaceable_events (identifier asc)",
                                                                               "create index if not exists parametrized_replaceable_events_created_at_idx on parametrized_replaceable_events (created_at desc)"])
##
    # let l = ReentrantLock()
    #     est.dyn[:recent_events] = (; 
    #                                rwlock   = ReadWriteLock(0, false, l, Threads.Condition(l)),
    #                                ss       = SortedSet{Tuple{Int, Int, Bool, Nostr.PubKeyId, Nostr.EventId}}(DataStructures.Reverse),
    #                                capacity = Ref(3_000_000))
    # end
##
    
    if !noperiodic
        est.periodic_task_running[] = true
        est.periodic_task[] = errormonitor(@async while est.periodic_task_running[]
                                               catch_exception(est, :periodic) do
                                                   Base.invokelatest(periodic, est)
                                               end
                                               Utils.active_sleep(60.0, est.periodic_task_running)
                                           end)
    end
end

function periodic(est::CacheStorage)
    est.readonly[] && return
    run_scheduled_hooks(est)
    cnt = expire_scores(est)
    incr(est, :scoresexpired; by=cnt)
end

function find_message_logs(src_dirs::Vector{String}; files_newer_than::Real=0)
    fns = []
    for src_dir in src_dirs
        for (dir, _, fs) in walkdir(src_dir)
            for fn in fs
                endswith(fn, ".log") || continue
                ffn = "$dir/$fn"
                !isnothing(files_newer_than) && stat(ffn).mtime < files_newer_than && continue
                push!(fns, ffn)
            end
        end
    end
    sort(fns)
end

function import_to_storage(
        est::EventStorage, src_dirs::Vector{String};
        running=Ref(true)|>ThreadSafe, files_newer_than::Real=0,
        max_threads=Threads.nthreads())
    init(est, running)

    empty!(threadprogress)

    fns = find_message_logs(src_dirs; files_newer_than)

    fnpos = []
    chunksize = 100_000_000
    for fn in fns
        last_pos = get(est.commons.latest_file_positions, fn, 0)
        for p in 0:chunksize:filesize(fn)
            end_pos = min(p+chunksize, filesize(fn))
            end_pos > last_pos && push!(fnpos, (; fn, start_pos=p, end_pos))
        end
    end

    fnpos = sort(fnpos, by=fnp->fnp.start_pos)

    thrcnt = Ref(0) |> ThreadSafe
    fnposcnt = Ref(0) |> ThreadSafe

    @time @sync for (fnidx, fnp) in collect(enumerate(fnpos))
        while running[] && thrcnt[] >= max_threads; sleep(0.05); end
        running[] || break
        incr(thrcnt)
        Threads.@spawn begin
            catch_exception(est, fnp) do
                # running[] || continue
                try
                    file_pos = max(fnp.start_pos - 2*MAX_MESSAGE_SIZE[], 0)
                    open(fnp.fn) do flog
                        seek(flog, file_pos); file_pos > 0 && readline(flog)
                        msgcnt_ = Ref(0)
                        chunk_done = false
                        while running[]
                            (chunk_done = (eof(flog) || position(flog) >= fnp.end_pos)) && break

                            SHOW_PROGRESS[] && (msgcnt_[] % 1000 == 0) && term_progress((@sprintf "[%5d] %s" fnidx fnp.fn), msgcnt_[], est.commons.stats, "$(fnposcnt[])/$(length(fnpos))", est.commons.tstart[])
                            msgcnt_[] += 1

                            msg = readline(flog)
                            # isempty(msg) && break

                            length(msg) > MAX_MESSAGE_SIZE[] && continue

                            catch_exception(est, msg) do
                                import_msg_into_storage(msg, est)
                            end
                        end
                        incr(est, :msg; by=msgcnt_[])
                        chunk_done && lock(est.commons.latest_file_positions) do latest_file_positions
                            latest_file_positions[fnp.fn] = max(position(flog), get(latest_file_positions, fnp.fn, 0))
                        end
                    end
                finally
                    SHOW_PROGRESS[] && term_progress(fnp.fn, PROGRESS_COMPLETE, est.commons.stats, "$(fnposcnt[])/$(length(fnpos))", est.commons.tstart[])
                    incr(fnposcnt)
                end
            end
            decr(thrcnt)
        end
    end
    while thrcnt[] > 0; sleep(0.1); end

    save_stats(est.commons)

    complete(est)

    report_result(est)
end

function extract_event_id(msg::String)
    pat = "\"id\":\""
    r1 = findnext(pat, msg, 1)
    if !isnothing(r1)
        r2 = findnext(pat, msg, r1[end]+1)
        if isnothing(r2) # check if we see only one id key
            eid = try
                eidhex = msg[r1[end]+1:findnext("\"", msg, r1[end]+1)[1]-1]
                Nostr.EventId(eidhex)
            catch _ end
            if !isnothing(eid)
                return eid
            end
        end
    end
    nothing
end

function complete(commons::StorageCommons)
    stop(commons.gc_task[])
end

function complete(est::DeduplicatedEventStorage)
    complete(est.commons)

    lock(est.files) do files
        for (fn, f) in collect(files)
            close(f.io)
        end
        empty!(files)
    end
end

function complete(est::CacheStorage)
    complete(est.commons)

    ext_complete(est)
end

function report_result(commons::StorageCommons)
    println("#msgbytes: $(sum(values(commons.latest_file_positions))/(1024^3)) GB")
    println("stats:")
    for (k, v) in sort(collect(pairs(getstats(commons.stats))))
        println(@sprintf "  %20s => %d" k v)
    end
end
@forward EventStorage.commons report_result
function report_result(est::CacheStorage)
    report_result(est.commons)
    println("dicts:")
    println(barplot(map(string, [Nostr.SET_METADATA, Nostr.CONTACT_LIST]), map(length, [est.meta_data, est.contact_lists])))
end

function getstats(stats)
    lock(stats) do stats
        (; (prop => get(stats, prop, 0) for prop in stat_names)...)
    end
end

function mon(est::EventStorage)
    local running = Ref(true)
    tsk = @async begin; readline(); running[] = false; println("stopping"); end
    local pc = nothing
    while running[]
        c = get(est.commons.stats, :any, 0)
        isnothing(pc) && (pc = c)
        print("  ", c-pc, " msg/s         \r")
        pc = c
        sleep(1)
    end
end

function dyn_exists(est, args...)
    where = join((" and c$i = ?$i" for i in 1:length(args)))
    !isempty(DB.exec(est.dyn[:dyn], "select 1 from dyn where true $where limit 1", args))
end
function dyn_select(est, args...; limit=nothing, columns=nothing)
    where = join((" and c$i = ?$i" for i in 1:length(args)))
    isnothing(limit) || (where *= " limit $limit")
    columns = isnothing(columns) ? "*" : join(("c$i" for i in columns), ',')
    DB.exec(est.dyn[:dyn], "select $columns from dyn where true $where", args)
end
function dyn_insert(est, args...)
    cols = join(("c$i" for i in 1:length(args)), ',')
    vals = join(("?$i" for i in 1:length(args)), ',')
    DB.exec(est.dyn[:dyn], "insert into dyn ($cols) values ($vals)", args)
end
function dyn_delete(est, args...)
    where = join((" and c$i = ?$i" for i in 1:length(args)))
    DB.exec(est.dyn[:dyn], "delete from dyn where true $where", args)
end
function dyn_get(est, args...)
    r = dyn_select(est, args...; limit=1, columns=[length(args)+1])
    isempty(r) ? nothing : r[1][1]
end
function dyn_set(est, args...; limit=nothing)
    where = join((" and c$i = ?$i" for i in 1:length(args)-1))
    isnothing(limit) || (where *= " limit $limit")
    DB.exec(est.dyn[:dyn], "update dyn set c$(length(args)) = ?$(length(args)) where true $where", args)
end
function dyn_inc(est, args...; by=+1)
    cnt = dyn_get(est, args...)
    if isnothing(cnt) 
        dyn_insert(est, args..., 0)
        cnt = 0
    end
    cnt += by
    dyn_set(est, args..., cnt)
    cnt
end

function update_pubkey_ln_address(est::CacheStorage, pubkey::Nostr.PubKeyId)
    pubkey in est.meta_data || return
    eid = est.meta_data[pubkey]
    eid in est.events || return
    d = try JSON.parse(est.events[eid].content) catch _ end
    if d isa Dict
        lud16 = get(d, "lud16", nothing)
        !isnothing(lud16) && (est.dyn[:pubkey_ln_address][pubkey] = lud16)
    end
end

function Base.lock(body::Function, l::Union{ReadLock, WriteLock})
    lock!(l)
    try
        body()
    finally
        unlock!(l)
    end
end

function recent_events_init(est::CacheStorage; days=2, running=Utils.PressEnterToStop())
    rs = DB.exec(est.pubkey_events, "select pubkey, event_id, created_at, is_reply from pubkey_events where created_at>=?1 order by created_at desc", (trunc(Int,time()-days*24*3600),))
    re = est.dyn[:recent_events]
    lock(write_lock(re.rwlock)) do
        empty!(re.ss)
        for (i, r) in enumerate(rs)
            yield()
            running[] || break
            print("recent_events_init: $i / $(length(rs))\r")
            pk, eid, created_at, is_reply = Nostr.PubKeyId(r[1]), Nostr.EventId(r[2]), r[3], r[4]
            push!(re.ss, (created_at, created_at, is_reply, pk, eid))
        end
    end
    length(rs)
end

function import_messages(est::CacheStorage, filename::String; pos=0, cond=e->true, running=Utils.PressEnterToStop())
    total = Ref(0)
    imported = Ref(0)
    condcnt = Ref(0)
    kindstats = Accumulator{Int, Int}()
    open(filename) do f
        if pos != 0
            seek(f, pos)
            readline()
        end
        while !eof(f)
            running[] || break
            yield()
            msg = readline(f)
            try
                d = JSON.parse(msg)
                if d[3][1] == "EVENT"
                    e = Nostr.Event(d[3][3])
                    kindstats[e.kind] += 1
                    if cond(e)
                        condcnt[] += 1
                        import_msg_into_storage(msg, est) && (imported[] += 1)
                    end
                end
            catch ex
                println(ex)
            end
            total[] += 1
            if total[] % 1000 == 0
                print("total: $(total[])  cond: $(condcnt[])  imported: $(imported[])\r")
            end
        end
    end
    (; total=total[], cond=condcnt[], imported=imported[], kindstats)
end

function iterate_events_in_file(body::Function, filename::String; pos=0, cond=e->true, running=Utils.PressEnterToStop(), silent=false)
    total = Ref(0)
    condcnt = Ref(0)
    open(filename) do f
        if pos != 0
            seek(f, pos)
            readline()
        end
        while !eof(f)
            running[] || break
            msg = readline(f)
            try
                d = JSON.parse(msg)
                if d[3][1] == "EVENT"
                    e = Nostr.Event(d[3][3])
                    if cond(e)
                        condcnt[] += 1
                        body(e) == :stop && break
                    end
                end
                total[] += 1
                if total[] % 1000 == 0
                    yield()
                    !silent && print("total: $(total[])  cond: $(condcnt[])\r")
                end
            catch ex
                println(ex)
            end
        end
    end
    nothing
end

include("cache_storage_ext.jl")

function sendtolog(tag, fc; server=:p7)
   Postgres.execute(server, "insert into log values (\$1, \$2, \$3, \$4, \$5)",
                    [Dates.now(), gethostname(), string(Main.NODEIDX), tag, JSON.json(fc)])
end

