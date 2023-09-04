#module DB

import ..Filterlist
import ..TrustRank

union!(stat_names, Set([
                        :scoresexpired,
                       ]))

include("../src/psql.jl")

include("../src/notifications.jl")

Base.@kwdef struct CacheStorageExt
    commons

    pqconnstr::String

    periodic_task_running = Ref(false)
    periodic_task = Ref{Union{Nothing, Task}}(nothing)

    event_contents = ShardedSqliteDict{Nostr.EventId, String}("$(commons.directory)/db/event_contents"; commons.dbargs...,
                                                              keycolumn="event_id", valuecolumn="content",
                                                              init_queries=["create virtual table if not exists kv_fts using fts5(
                                                                               event_id unindexed,
                                                                               content,
                                                                               tokenize = \"unicode61 tokenchars '#'\"
                                                                             )"
                                                                            ])

    pubkey_zapped = ShardedSqliteSet(Nostr.PubKeyId, "$(commons.directory)/db/pubkey_zapped"; commons.dbargs...,
                                     init_queries=["create table if not exists kv (
                                                      pubkey blob primary key not null,
                                                      zaps int not null,
                                                      satszapped int not null
                                                    )",
                                                   "create index if not exists kv_pubkey on kv (pubkey asc)",
                                                   "create index if not exists kv_zaps on kv (zaps desc)",
                                                   "create index if not exists kv_satszapped on kv (satszapped desc)"])

    score_expiry = ShardedSqliteSet(Nostr.EventId, "$(commons.directory)/db/score_expiry"; commons.dbargs...,
                                    init_queries=["create table if not exists kv (
                                                     event_id blob not null,
                                                     author_pubkey blob not null,
                                                     change int not null,
                                                     expire_at int not null
                                                   )",
                                                  "create index if not exists kv_event_id on kv (event_id asc)",
                                                  "create index if not exists kv_expire_at on kv (expire_at asc)"])

    relays = SqliteDict(String, Int, "$(commons.directory)/db/relays"; commons.dbargs...,
                        init_queries=["create table if not exists kv (
                                         url string primary key not null,
                                         times_referenced int not null
                                       )",
                                      "create index if not exists kv_url on kv (url asc)",
                                      "create index if not exists kv_times_referenced on kv (times_referenced desc)",
                                     ])

    app_settings = PQDict{Nostr.PubKeyId, Nostr.Event}("app_settings", pqconnstr;
                                                       init_extra_columns=", accessed_at int8, created_at int8, event_id bytea",
                                                       init_extra_indexes=["create index if not exists app_settings_accessed_at on app_settings (accessed_at desc)"])

    app_settings_event_id = PQDict{Nostr.PubKeyId, Nostr.EventId}("app_settings_event_id", pqconnstr;
                                                                  init_extra_columns=", created_at int8, accessed_at int8",
                                                                  init_extra_indexes=["create index if not exists app_settings_event_id_created_at  on app_settings_event_id (created_at desc)",
                                                                                      "create index if not exists app_settings_event_id_accessed_at on app_settings_event_id (accessed_at desc)",
                                                                                     ])
 
    app_settings_log = PQDict{Nostr.PubKeyId, Nostr.Event}("app_settings_log", pqconnstr;
                                                           init_queries=["create table if not exists app_settings_log (
                                                                         pubkey bytea not null,
                                                                         event json not null,
                                                                         accessed_at int8 not null
                                                                         )",
                                                                         "create index if not exists app_settings_log_pubkey on app_settings_log (pubkey asc)",
                                                                         "create index if not exists app_settings_log_accessed_at on app_settings_log (accessed_at desc)",
                                                                        ])

    notifications = Notifications(; commons.directory, pqconnstr, commons.dbargs)

    notification_processors = SortedDict{Symbol, Function}() |> ThreadSafe

    notification_counter_update_lock = ReentrantLock()

    media = SqliteDict(String, Int, "$(commons.directory)/db/media"; commons.dbargs...,
                       table="media", keycolumn="url", valuecolumn="imported_at",
                       init_queries=["create table if not exists media (
                                        url text not null,
                                        media_url text not null,
                                        size text not null,
                                        animated integer not null,
                                        imported_at integer not null,
                                        download_duration number not null,
                                        width integer not null,
                                        height integer not null,
                                        mimetype text not null,
                                        category text not null,
                                        category_confidence number not null
                                     )",
                                     "create index if not exists media_url on media (url asc)",
                                     "create index if not exists media_media_url on media (media_url asc)",
                                     "create index if not exists media_url_size_animated on media (url asc, size asc, animated asc)",
                                     "create index if not exists media_imported_at on media (imported_at desc)",
                                     "create index if not exists media_category on media (category asc)",
                                    ])

    event_media = ShardedSqliteSet(Nostr.EventId, "$(commons.directory)/db/event_media"; commons.dbargs...,
                                   table="event_media", keycolumn="event_id", valuecolumn="url",
                                   init_queries=["create table if not exists event_media (
                                                   event_id blob not null,
                                                   url text not null
                                                 )",
                                                 "create index if not exists event_media_event_id on event_media (event_id asc)",
                                                 "create index if not exists event_media_url      on event_media (url asc)",
                                                ])

    preview = SqliteDict(String, Int, "$(commons.directory)/db/preview"; commons.dbargs...,
                         table="preview", keycolumn="url", valuecolumn="imported_at",
                         init_queries=["create table if not exists preview (
                                       url text not null,
                                       imported_at integer not null,
                                       download_duration number not null,
                                       mimetype text not null,
                                       category text,
                                       category_confidence number,
                                       md_title text,
                                       md_description text,
                                       md_image text,
                                       icon_url text
                                       )",
                                       "create index if not exists preview_url on preview (url asc)",
                                       "create index if not exists preview_imported_at on preview (imported_at desc)",
                                       "create index if not exists preview_category on preview (category asc)",
                                      ])

    event_preview = ShardedSqliteSet(Nostr.EventId, "$(commons.directory)/db/event_preview"; commons.dbargs...,
                                     table="event_preview", keycolumn="event_id", valuecolumn="url",
                                     init_queries=["create table if not exists event_preview (
                                                   event_id blob not null,
                                                   url text not null
                                                   )",
                                                   "create index if not exists event_preview_event_id on event_preview (event_id asc)",
                                                   "create index if not exists event_preview_url      on event_preview (url asc)",
                                                  ])

    event_hashtags = ShardedSqliteSet(Nostr.EventId, "$(commons.directory)/db/event_hashtags"; commons.dbargs...,
                                      table="event_hashtags", keycolumn="event_id", valuecolumn="hashtag",
                                      init_queries=["create table if not exists event_hashtags (
                                                       event_id blob not null,
                                                       hashtag text not null,
                                                       created_at integer not null
                                                    )",
                                                    "create index if not exists event_hashtags_event_id   on event_hashtags (event_id asc)",
                                                    "create index if not exists event_hashtags_hashtag    on event_hashtags (hashtag asc)",
                                                    "create index if not exists event_hashtags_created_at on event_hashtags (created_at desc)",
                                                   ])
    hashtags = SqliteDict(String, Int, "$(commons.directory)/db/hashtags"; commons.dbargs...,
                          table="hashtags", keycolumn="hashtag", valuecolumn="score",
                          init_queries=["create table if not exists hashtags (
                                           hashtag text not null,
                                           score integer not null
                                        )",
                                        "create index if not exists hashtags_hashtag on hashtags (hashtag asc)",
                                        "create index if not exists hashtags_score   on hashtags (score desc)",
                                       ])

    media_uploads = PQDict{Nostr.PubKeyId, Nostr.Event}("media_uploads", pqconnstr;
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
                                                                      duration real not null
                                                                      )",
                                                                      "create index if not exists media_uploads_pubkey on media_uploads (pubkey asc)",
                                                                      "create index if not exists media_uploads_created_at on media_uploads (created_at desc)",
                                                                     ])

    notification_settings = PQDict{Nostr.PubKeyId, Bool}("notification_settings", pqconnstr;
                                                         init_queries=["create table if not exists notification_settings (
                                                                       pubkey bytea not null,
                                                                       type varchar(100) not null,
                                                                       enabled bool not null
                                                                       )",
                                                                       "create index if not exists notification_settings_pubkey on notification_settings (pubkey asc)",
                                                                      ])
end

function ext_init(est::CacheStorage)
    for q in ["create virtual table if not exists user_search using fts5(
              pubkey unindexed,
              name,
              username,
              display_name,
              displayName,
              nip05
              )",
             ]
        exec(est.pubkey_followers, q)
    end

    est.ext[].periodic_task[] = 
    errormonitor(@async while est.ext[].periodic_task_running[]
                     cnt = expire_scores(est)
                     incr(est, :scoresexpired; by=cnt)
                     sleep(1)
                 end)

    est.ext[].notification_processors[:notification_counter_update] = function (est, notif)
        lock(est.ext[].notification_counter_update_lock) do
            if !(notif.pubkey in est.ext[].notifications.pubkey_notification_cnts)
                DB.exe(est.ext[].notifications.pubkey_notification_cnts, DB.@sql("insert into kv (pubkey) values (?1)"), notif.pubkey)
            end
            nt = Int(notif.type)
            DB.exe(est.ext[].notifications.pubkey_notification_cnts, "update kv set type$nt = type$nt + 1 where pubkey = ?1", notif.pubkey)
        end
    end
##
    est.dyn[:reported] = PQDict{Nostr.PubKeyId, Bool}("reported", est.ext[].pqconnstr;
                                                      init_queries=["create table if not exists reported (
                                                                    pubkey bytea not null,
                                                                    type int8 not null,
                                                                    id bytea not null,
                                                                    created_at int8 not null,
                                                                    primary key (pubkey, type, id)
                                                                    )",
                                                                    "create index if not exists reported_pubkey on reported (pubkey asc)",
                                                                    "create index if not exists reported_created_at on reported (created_at desc)",
                                                                   ])
##
    est.dyn[:event_zapped] = DB.ShardedSqliteSet(Nostr.EventId, "$(est.commons.directory)/db/event_zapped"; est.commons.dbargs...,
                                                 table="event_zapped",
                                                 init_queries=["create table if not exists event_zapped (
                                                               event_id blob not null,
                                                               zap_sender blob not null
                                                               )",
                                                               "create index if not exists event_zapped_event_id_zap_sender on event_zapped (event_id asc, zap_sender asc)",
                                                              ])
##
end

function ext_complete(est::CacheStorage)
    est.ext[].periodic_task_running[] = false
    wait(est.ext[].periodic_task[])
end

function ext_preimport_check(est::CacheStorage, e::Nostr.Event)
    !(e.pubkey in Filterlist.import_pubkey_blocked)
end

function ext_preimport(est::CacheStorage, e::Nostr.Event)
    # try
    #     for t in e.tags
    #         flds = t.fields
    #         if length(flds) >= 3 && (flds[1] == "e" || flds[1] == "p")
    #             relay_url = flds[3]
    #             ps = split(relay_url, "://")
    #             if length(ps) >= 2
    #                 scheme = ps[1]
    #                 if scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss"
    #                     register_relay(est, relay_url)
    #                 end
    #             end
    #         end
    #     end
    # catch _
    #     PRINT_EXCEPTIONS[] && print_exceptions()
    # end
    
end

function ext_pubkey(est::CacheStorage, e::Nostr.Event)
    exe(est.ext[].pubkey_zapped, @sql("insert or ignore into kv (pubkey, zaps, satszapped) values (?1, ?2, ?3)"), e.pubkey, 0, 0)
end

function ext_metadata_changed(est::CacheStorage, e::Nostr.Event)
    catch_exception(est, (:update_user_search, e.pubkey)) do
        update_user_search(est, e.pubkey)
    end
    catch_exception(est, (:import_media_from_metadata, e.pubkey)) do
        d = JSON.parse(e.content)
        for a in ["banner", "picture"]
            if haskey(d, a)
                url = d[a]
                if !isempty(url)
                    _, ext = splitext(lowercase(url))
                    if ext in image_exts
                        DOWNLOAD_MEDIA[] && import_media_async(est, e.id, url, Media.all_variants)
                    end
                end
            end
        end
    end
end

function ext_new_follow(est::CacheStorage, e::Nostr.Event, follow_pubkey)
    notification(est, follow_pubkey, e.created_at, NEW_USER_FOLLOWED_YOU, e.pubkey)
end

function ext_user_unfollowed(est::CacheStorage, e::Nostr.Event, follow_pubkey)
    notification(est, follow_pubkey, e.created_at, USER_UNFOLLOWED_YOU, e.pubkey)
end

function ext_reaction(est::CacheStorage, e::Nostr.Event, eid)
    event_hook(est, eid, (:score_event_cb, e.created_at, 1))
    event_hook(est, eid, (:notifications_cb, YOUR_POST_WAS_LIKED, e.id))
    event_hook(est, eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_LIKED, e.id))
    event_hook(est, eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED, "make_event_hooks", e.id))
end

DOWNLOAD_MEDIA = Ref(false)
DOWNLOAD_PREVIEWS = Ref(false)
image_exts = [".png", ".gif", ".jpg", ".jpeg", ".webp"]
video_exts = [".mp4", ".mov"]

function ext_text_note(est::CacheStorage, e::Nostr.Event)
    exe(est.ext[].event_contents, @sql("insert into kv_fts (event_id, content) values (?1, ?2)"), 
        e.id, e.content)

    for_mentiones(est, e; pubkeys_in_content=false) do tag
        if tag.fields[1] == "p" 
            if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                event_hook(est, e.id, (:notifications_cb, YOU_WERE_MENTIONED_IN_POST, pk))
            end
        elseif tag.fields[1] == "e" 
            if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
                event_hook(est, eid, (:notifications_cb, YOUR_POST_WAS_MENTIONED_IN_POST, e.id))
            end
        end
    end

    for_urls(est, e) do url
        _, ext = splitext(lowercase(url))
        if ext in image_exts
            DOWNLOAD_MEDIA[] && import_media_async(est, e.id, url, [(:original, true), (:large, true)])
        elseif ext in video_exts
            DOWNLOAD_MEDIA[] && import_media_async(est, e.id, url, [(:original, true)])
        else
            DOWNLOAD_PREVIEWS[] && import_preview_async(est, e.id, url)
        end
    end

    for_hashtags(est, e) do hashtag
        exe(est.ext[].event_hashtags, @sql("insert into event_hashtags values (?1, ?2, ?3)"),
            e.id, hashtag, e.created_at)
        if isempty(exec(est.ext[].hashtags, @sql("select 1 from hashtags where hashtag = ?1 limit 1"), (hashtag,)))
            exec(est.ext[].hashtags, @sql("insert into hashtags values (?1, ?2)"), (hashtag, 0))
        end
        d_score = +1
        exec(est.ext[].hashtags, @sql("update hashtags set score = score + ?2 where hashtag = ?1"), (hashtag, d_score))
        schedule_hook(est, trunc(Int, time()+4*3600), (:expire_hashtag_score_cb, hashtag, d_score))
    end
end

function ext_reply(est::CacheStorage, e::Nostr.Event, parent_eid)
    event_hook(est, parent_eid, (:score_event_cb, e.created_at, 10))
    event_hook(est, parent_eid, (:notifications_cb, YOUR_POST_WAS_REPLIED_TO, e.id))
    event_hook(est, parent_eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO, e.id, e.id))
    event_hook(est, parent_eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO, "make_event_hooks", e.id, e.id))
end

function ext_repost(est::CacheStorage, e::Nostr.Event, eid)
    event_hook(est, eid, (:score_event_cb, e.created_at, 3))
    event_hook(est, eid, (:notifications_cb, YOUR_POST_WAS_REPOSTED, e.id))
    event_hook(est, eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED, e.id))
    event_hook(est, eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED, "make_event_hooks", e.id))
end

ext_zap_lock = ReentrantLock()
function ext_zap(est::CacheStorage, e::Nostr.Event, parent_eid, amount_sats)
    valid_zap = isempty(TrustRank.pubkey_rank) || get(TrustRank.pubkey_rank, e.pubkey, 0.0) > 0.0
    lock(ext_zap_lock) do
        if isempty(exe(est.dyn[:event_zapped], @sql("select 1 from event_zapped where event_id = ?1 and zap_sender = ?2 limit 1"),
                       parent_eid, zap_sender(e)))
            exe(est.dyn[:event_zapped], @sql("insert into event_zapped values (?1, ?2)"),
                parent_eid, zap_sender(e))
            event_hook(est, parent_eid, (:score_event_cb, e.created_at, 20))
        end
    end
    if valid_zap
        event_hook(est, parent_eid, (:event_stats_cb, :satszapped, amount_sats))
        event_hook(est, parent_eid, (:notifications_cb, YOUR_POST_WAS_ZAPPED, e.id, amount_sats))
        event_hook(est, parent_eid, (:notifications_cb, POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED, e.id, amount_sats))
        event_hook(est, parent_eid, (:notifications_cb, POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED, "make_event_hooks", e.id, amount_sats))
    end
end

function ext_pubkey_zap(est::CacheStorage, e::Nostr.Event, zapped_pk, amount_sats)
    exe(est.ext[].pubkey_zapped, @sql("update kv set zaps = zaps + 1, satszapped = satszapped + ?2 where pubkey = ?1"), zapped_pk, amount_sats)
end

function ext_is_hidden(est::CacheStorage, eid::Nostr.EventId)
    eid in Filterlist.access_event_blocked_spam
end

# TODO refactor event scoring to use scheduled_hooks to expire scores
function score_event_cb(est::CacheStorage, e::Nostr.Event, scored_at, increment)
    tr = isempty(TrustRank.pubkey_rank) ? 1.0 : get(TrustRank.pubkey_rank, e.pubkey, 0.0)
    increment = trunc(Int, 1e10*tr*increment)

    exe(est.event_stats          , @sql("update kv set score = score + ?2 where event_id = ?1"), e.id, increment)
    exe(est.event_stats_by_pubkey, @sql("update kv set score = score + ?3 where event_id = ?2"), e.pubkey, e.id, increment)

    expire_at = scored_at+24*3600
    if expire_at > time()
        exe(est.event_stats          , @sql("update kv set score24h = score24h + ?2 where event_id = ?1"), e.id, increment)
        exe(est.event_stats_by_pubkey, @sql("update kv set score24h = score24h + ?3 where event_id = ?2"), e.pubkey, e.id, increment)
        exe(est.ext[].score_expiry   , @sql("insert into kv (event_id, author_pubkey, change, expire_at) values (?1, ?2, ?3, ?4)"),
            e.id, e.pubkey, increment, expire_at)
    end
end

function notif2namedtuple(notif::Tuple)
    notif_type = notif[3]
    (; pubkey=notif[1], created_at=notif[2], type=notif[3],
     [name => v isa ty ? v : ty(v)
      for (v, (name, ty)) in zip(notif[4:end], notification_args[notif_type])
      if !(v isa Missing)]...)
end

PG_DISABLE = Ref(true)

function notification(
        est::CacheStorage,
        pubkey::Nostr.PubKeyId, notif_created_at::Int, notif_type::NotificationType,
        args...
    )
    PG_DISABLE[] && return

    pubkey in est.ext[].app_settings || return

    callargs = (; pubkey, notif_created_at, notif_type, args)

    for a in args
        a isa Nostr.PubKeyId && a == pubkey && return
        if a isa Nostr.EventId && (ext_is_hidden(est, a) ||
                                   try Base.invokelatest(Main.eval(:(App.is_hidden)), pubkey, :content, est.events[a].pubkey) catch _ false end)
           # push!(Main.stuff, (:hidden, a, callargs))
           return
       end
    end

    catch_exception(est, :notification_settings, callargs) do
        if !isempty(local r = DB.exe(est.ext[].notification_settings, 
                                     @sql("select enabled from notification_settings where pubkey = ?1 and type = ?2 limit 1"),
                                     pubkey, string(notif_type)))
            r[1][1]
        else
            true
        end
    end || return

    @assert length(args) <= 4
    @assert length(notification_args[notif_type]) == length(args)

    args = (args..., [nothing for _ in 1:4-length(args)]...)

    notif = (pubkey, notif_created_at, notif_type, args...)
    exe(est.ext[].notifications.pubkey_notifications, @sql("insert into kv values (?1, ?2, ?3, ?4, ?5, ?6, ?7)"),
        pubkey, notif[2:end]...)

    notif_d = notif2namedtuple(notif)

    lock(est.ext[].notification_processors) do notification_processors
        for func in values(notification_processors)
            catch_exception(est, func, notif_d) do
                Base.invokelatest(func, est, notif_d)
            end
        end
    end
end

function notifications_cb(est::CacheStorage, e::Nostr.Event, notif_type, args...)
    notif_type isa Int && (notif_type = NotificationType(notif_type))

    conv(f, v) = v isa String ? f(v) : v

    if     notif_type in [YOUR_POST_WAS_ZAPPED,
                          YOUR_POST_WAS_LIKED,
                          YOUR_POST_WAS_REPOSTED]
        e0 = est.events[conv(Nostr.EventId, args[1])]
        e0_pubkey = notif_type == YOUR_POST_WAS_ZAPPED ? zap_sender(e0) : e0.pubkey
        notification(est, e.pubkey, e0.created_at, notif_type,
                     #= your_post =# e.id, #= who =# e0_pubkey, args[2:end]...)

    elseif notif_type == YOUR_POST_WAS_REPLIED_TO
        e0 = est.events[conv(Nostr.EventId, args[1])]
        notification(est, e.pubkey, e0.created_at, notif_type,
                     #= your_post =# e.id, #= who =# e0.pubkey, #= reply =# e0.id, args[2:end]...)

    elseif notif_type == YOU_WERE_MENTIONED_IN_POST
        you = conv(Nostr.PubKeyId, args[1])
        notification(est, you, e.created_at, notif_type,
                     #= their_post =# e.id)

    elseif notif_type == YOUR_POST_WAS_MENTIONED_IN_POST
        e0 = est.events[conv(Nostr.EventId, args[1])]
        notification(est, e.pubkey, e.created_at, notif_type,
                     #= your_post =# e.id, #= their_post =# e0.id)

    elseif notif_type in [POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED,
                          POST_YOU_WERE_MENTIONED_IN_WAS_LIKED,
                          POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED,
                          POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO,
                         ]
        e0 = est.events[conv(Nostr.EventId, args[1])]
        e0_pubkey = notif_type == POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED ? zap_sender(e0) : e0.pubkey
        for_mentiones(est, e; pubkeys_in_content=false) do tag
            if tag.fields[1] == "p" 
                if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                    notification(est, pk, e0.created_at, notif_type,
                                 e.id, e0_pubkey, args[2:end]...)
                end
            end
        end

    elseif notif_type in [POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED,
                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED,
                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED,
                          POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO,
                         ]
        if args[1] == "make_event_hooks"
            e0 = est.events[conv(Nostr.EventId, args[2])]
            for_mentiones(est, e) do tag
                if tag.fields[1] == "e" 
                    if !isnothing(local eid = try Nostr.EventId(tag.fields[2]) catch _ end)
                        event_hook(est, eid, (:notifications_cb, notif_type, "make_notification", e0.id, e.id, args[3:end]...))
                    end
                end
            end
        elseif args[1] == "make_notification"
            e0 = est.events[conv(Nostr.EventId, args[2])]
            e1 = est.events[conv(Nostr.EventId, args[3])]
            e0_pubkey = notif_type == POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED ? zap_sender(e0) : e0.pubkey
            notification(est, e.pubkey, e0.created_at, notif_type,
                         e1.id, #= your_post =# e.id, #= who =# e0_pubkey, args[4:end]...)
        end
    end
end

update_user_search_exceptions = CircularBuffer(100) |> ThreadSafe
function update_user_search(est::CacheStorage, pubkey::Nostr.PubKeyId)
    get(est.pubkey_followers_cnt, pubkey, 0) >= 3 || return false
    DB.exec(est.pubkey_followers, @sql("delete from user_search where pubkey = ?1"), (pubkey,))
    try
        local c = JSON.parse(est.events[est.meta_data[pubkey]].content)
        !isnothing(c) || return false
        c isa Dict || return false
        # isempty(get(c, "nip05", "")) && continue
        DB.exec(est.pubkey_followers, @sql("insert into user_search values (?1, ?2, ?3, ?4, ?5, ?6)"), 
                (pubkey, [get(c, a, nothing) for a in ["name", "username", "display_name", "displayName", "nip05"]]...))
    catch ex push!(update_user_search_exceptions, (; t=time(), ex, pubkey)) end
    true
end

function expire_scores(est::CacheStorage) # should be called periodically
    tnow = trunc(Int, time())
    cnt = 0
    #@threads
    for dbconn in est.ext[].score_expiry.dbconns
        for (eid, pkid, change) in exe(dbconn, @sql("select event_id, author_pubkey, change from kv where expire_at <= ?1"), (tnow,))
            eid = Nostr.EventId(eid)
            pkid = Nostr.PubKeyId(pkid)
            exe(est.event_stats          , @sql("update kv set score24h = score24h - ?2 where event_id = ?1"), eid, change)
            exe(est.event_stats_by_pubkey, @sql("update kv set score24h = score24h - ?3 where author_pubkey = ?1 and event_id = ?2"), pkid, eid, change)
            cnt += 1
        end
        exe(dbconn, @sql("delete from kv where expire_at <= ?1"), (tnow,))
    end
    cnt
end

function reconnect_pq_tables(est::CacheStorage)
    for d in [est.ext[].app_settings]
        close(d)
        empty!(d.dbconns)
        push!(d.dbconns, LibPQConn([LibPQ.Connection(est.ext[].pqconnstr)
                                    for _ in 1:Threads.nthreads()]) |> ThreadSafe)
    end
end

# function register_relay(est::CacheStorage, relay_url::String) # TDB use est.contact_lists for mining relays
#     exe(est.ext[].relays, @sql("insert or ignore into kv (url, times_referenced) values (?1, 0)"), relay_url)
#     exe(est.ext[].relays, @sql("update kv set times_referenced = times_referenced + 1 where url = ?1"), relay_url)
# end

function expire_hashtag_score_cb(est::CacheStorage, hashtag, d_score)
    exec(est.ext[].hashtags, @sql("update hashtags set score = score - ?2 where hashtag = ?1"), (hashtag, d_score))
end

re_hashtag = r"\#([0-9a-zA-Z]+)"

function for_hashtags(body::Function, est::CacheStorage, e::Nostr.Event)
    e.kind == Int(Nostr.TEXT_NOTE) || return
    for m in eachmatch(re_hashtag, e.content)
        body(String(m.captures[1]))
    end
end

re_url = r"https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)"

function for_urls(body::Function, est::CacheStorage, e::Nostr.Event)
    e.kind == Int(Nostr.TEXT_NOTE) || return
    for m in eachmatch(re_url, e.content)
        body(String(m.match))
    end
end

MEDIA_SERVER = Ref("https://primal.b-cdn.net")

import URIs
import HTTP
import ..Media

function media_url(url, size, anim)
    "$(MEDIA_SERVER[])/media-cache?s=$(size)&a=$(anim)&u=$(URIs.escapeuri(url))"
end

function import_media(est::CacheStorage, eid::Nostr.EventId, url::String, variant_specs::Vector)
    try
        catch_exception(est, :import_media, eid, url) do
            dldur = @elapsed (r = Media.media_variants(est, url, variant_specs; sync=true))
            isnothing(r) && return
            if isempty(exe(est.ext[].event_media, @sql("select 1 from event_media where event_id = ?1 and url = ?2"), eid, url))
                exe(est.ext[].event_media, @sql("insert into event_media values (?1, ?2)"),
                    eid, url)
            end
            for ((size, anim), media_url) in r
                if isempty(exe(est.ext[].media, @sql("select 1 from media where url = ?1 and size = ?2 and animated = ?3 limit 1"), url, size, anim))
                    fn = abspath(Media.MEDIA_PATH[] * "/.." * URIs.parse_uri(media_url).path)
                    _, ext = splitext(lowercase(url))
                    m = if ext in image_exts
                        try match(r", ([0-9]+) ?x ?([0-9]+)(, |$)", read(pipeline(`file -b $fn`; stdin=devnull), String))
                        catch _ nothing end
                    elseif ext in video_exts
                        try match(r"([0-9]+)x([0-9]+)", read(pipeline(`ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 $fn`; stdin=devnull), String))
                        catch _ nothing end
                    end
                    # @show (url, dldur, stat(fn).size, fn, m)
                    if !isnothing(m)
                        width, height = isnothing(m) ? (0, 0) : (parse(Int, m[1]), parse(Int, m[2]))
                        mimetype = try
                            String(chomp(read(pipeline(`file -b --mime-type $fn`; stdin=devnull), String)))
                        catch _
                            "application/octet-stream"
                        end
                        category = ""
                        exe(est.ext[].media, @sql("insert into media values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)"),
                            url, media_url, size, anim, trunc(Int, time()), dldur, width, height, mimetype, category, 1.0)
                    end
                    @async begin HTTP.get(Media.cdn_url(url, size, anim); readtimeout=15, connect_timeout=5).body; nothing; end
                    # @async begin @show (HTTP.get((@show Media.cdn_url(url, size, anim)); readtimeout=15, connect_timeout=5).body |> length); nothing; end
                end
            end
        end
    finally
        Media.update_media_queue_executor_taskcnt(-1)
    end
end

function import_media_async(est::CacheStorage, eid::Nostr.EventId, url::String, variant_specs::Vector)
    tsk = @task import_media(est, eid, url, variant_specs)
    Media.media_queue(tsk)
end

import_preview_lock = ReentrantLock()
function import_preview(est::CacheStorage, eid::Nostr.EventId, url::String)
    try
        catch_exception(est, :import_preview, eid, url) do
            if isempty(exe(est.ext[].preview, @sql("select 1 from preview where url = ?1 limit 1"), url))
                dldur = @elapsed (r = begin
                                      r = Media.fetch_resource_metadata(url)
                                      if !isempty(r.image)
                                          try 
                                              import_media(est, eid, r.image, Media.all_variants) 
                                              @async begin HTTP.get(Media.cdn_url(r.icon_url, :o, true); readtimeout=15, connect_timeout=5).body; nothing; end
                                          catch _ end
                                      end
                                      if !isempty(r.icon_url)
                                          try
                                              import_media(est, eid, r.icon_url, [(:original, true)]) 
                                              @async begin HTTP.get(Media.cdn_url(r.icon_url, :o, true); readtimeout=15, connect_timeout=5).body; nothing; end
                                          catch _ end
                                      end
                                      r
                                  end)
                lock(import_preview_lock) do
                    if isempty(exe(est.ext[].preview, @sql("select 1 from preview where url = ?1 limit 1"), url))
                        category = ""
                        exe(est.ext[].preview, @sql("insert into preview values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"),
                            url, trunc(Int, time()), dldur, r.mimetype, category, 1.0,
                            r.title, r.description, r.image, r.icon_url)
                        if isempty(exe(est.ext[].event_preview, @sql("select 1 from event_preview where event_id = ?1 and url = ?2"), eid, url))
                            exe(est.ext[].event_preview, @sql("insert into event_preview values (?1, ?2)"),
                                eid, url)
                        end
                    end
                end
            end
        end
    finally
        Media.update_media_queue_executor_taskcnt(-1)
    end
end

function import_preview_async(est::CacheStorage, eid::Nostr.EventId, url::String)
    tsk = @task import_preview(est, eid, url)
    Media.media_queue(tsk)
end
