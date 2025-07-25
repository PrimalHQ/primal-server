module App

import JSON

# using .Threads: @threads
macro threads(a); esc(a); end

import DataStructures
using DataStructures: OrderedSet, CircularBuffer, Accumulator
import Sockets
import Dates

import ..DB
import ..Nostr
using ..Utils: ThreadSafe, Throttle
using ..Postgres: @P, pgparams
using ..PostgresMacros: @p0_str, @p0tl_str, @ms_str
import ..Bech32

exposed_functions = Set([:feed,
                         :feed_2,
                         :thread_view,
                         :network_stats,
                         :contact_list,
                         :is_user_following,
                         :user_infos,
                         :user_followers,
                         :mutual_follows,
                         :events,
                         :event_actions,
                         :user_profile,
                         :user_profile_followed_by,
                         :get_directmsg_contacts,
                         :reset_directmsg_count,
                         :reset_directmsg_counts,
                         :get_directmsgs,
                         :mutelist,
                         :mutelists,
                         :allowlist,
                         :parameterized_replaceable_list,
                         :parametrized_replaceable_event,
                         :parametrized_replaceable_events,
                         :search_filterlist,
                         :import_events,
                         :zaps_feed,
                         :user_zaps,
                         :user_zaps_by_satszapped,
                         :user_zaps_sent,
                         :event_zaps_by_satszapped,
                         :server_name,
                         :nostr_stats,
                         :is_hidden_by_content_moderation,
                         :user_of_ln_address,
                         :get_user_relays,
                         :get_user_relays_2,
                         :get_bookmarks,
                         :get_highlights,
                         :long_form_content_feed,
                         :long_form_content_thread_view,
                         :get_recommended_reads,
                         :get_reads_topics,
                         :get_featured_authors,
                         :creator_paid_tiers,

                         :get_reads_feeds,
                         :mega_feed_directive,
                         :get_dvm_feeds,
                         :dvm_feed_info,
                         :enrich_feed_events,
                         :get_home_feeds,
                         :get_featured_dvm_feeds,

                         :explore_zaps,
                         :explore_people,
                         :explore_media,
                         :explore_topics,

                         :set_last_time_user_was_online,

                         :client_config,

                         :membership_media_management_stats,
                         :membership_media_management_uploads,
                         :membership_media_management_delete,
                         :membership_recovery_contact_lists,
                         :membership_recover_contact_list,
                         :membership_content_stats,
                         :membership_content_backup,
                         :membership_content_rebroadcast_start,
                         :membership_content_rebroadcast_cancel,
                         :membership_content_rebroadcast_status,

                         :membership_legends_leaderboard,
                         :membership_premium_leaderboard,

                         :nip19_decode,

                         # :mute_thread,
                         # :unmute_thread,
                        
                         :update_push_notification_token,

                         :articles_stats,
                         :drafts,
                         :top_article,

                         :get_recommended_blossom_servers,
                         :replaceable_event,

                         :follow_lists,
                         :follow_list,
                        ])

exposed_async_functions = Set([:net_stats, 
                               :directmsg_count,
                               :directmsg_count_2,
                               :rebroadcasting_status,
                              ])

EVENT_STATS=10_000_100
NET_STATS=10_000_101
USER_PROFILE=10_000_105
REFERENCED_EVENT=10_000_107
RANGE=10_000_113
EVENT_ACTIONS_COUNT=10_000_115
DIRECTMSG_COUNT=10_000_117
DIRECTMSG_COUNTS=10_000_118
EVENT_IDS=10_000_122
PARTIAL_RESPONSE=10_000_123
IS_USER_FOLLOWING=10_000_125
EVENT_IMPORT_STATUS=10_000_127
ZAP_EVENT=10_000_129
FILTERING_REASON=10_000_131
USER_FOLLOWER_COUNTS=10_000_133
DIRECTMSG_COUNT_2=10_000_134
NOSTR_STATS=10_000_136
IS_HIDDEN_BY_CONTENT_MODERATION=10_000_137
USER_PUBKEY=10_000_138
USER_RELAYS=10_000_139
EVENT_RELAYS=10_000_141
LONG_FORM_METADATA=10_000_144
RECOMMENDED_READS=10_000_145
READS_TOPICS=10_000_146
CREATOR_PAID_TIERS=10_000_147
FEATURED_AUTHORS=10_000_148
HIGHLIGHT_GROUPS=10_000_151

READS_FEEDS=10_000_152
HOME_FEEDS=10_000_153
# FEATURED_DVM_FEEDS=10_000_154

DVM_FEED_FOLLOWS_ACTIONS=10_000_156
USER_FOLLOWER_COUNT_INCREASES=10_000_157
USER_PRIMAL_NAMES=10_000_158
DVM_FEED_METADATA=10_000_159

# COLLECTION_ORDER=10_000_161

SHOW_PRIMAL_SUPPORT=10_000_162
MEMBERSHIP_MEDIA_MANAGEMENT_STATS=10_000_163
MEMBERSHIP_MEDIA_MANAGEMENT_UPLOADS=10_000_164
MEMBERSHIP_RECOVERY_CONTACT_LISTS=10_000_165
MEMBERSHIP_CONTENT_STATS=10_000_166
MEMBERSHIP_CONTENT_REBROADCAST_STATUS=10_000_167
MEMBERSHIP_LEGEND_CUSTOMIZATION=10_000_168
MEMBERSHIP_COHORTS=10_000_169
MEMBERSHIP_LEGEND_LEADERBOARD=10_000_170
MEMBERSHIP_PREMIUM_LEADERBOARD=10_000_171

USER_TRUSTRANKS=10_000_172

NIP19_DECODE_RESULT=10_000_173

ARTICLES_STATS=10_000_174

RECOMMENDED_BLOSSOM_SERVERS=10_000_175

cast(value, type) = value isa type ? value : type(value)
castmaybe(value, type) = (isnothing(value) || ismissing(value)) ? value : cast(value, type)

safekind(e) = e isa Dict ? e["kind"] : e.kind

PRINT_EXCEPTIONS = Ref(false)
exceptions = CircularBuffer(200)

DAG_OUTPUTS_DB = Ref{Any}(nothing) |> ThreadSafe

function catch_exception(body::Function, args...; rethrow_exception=false, kwargs...)
    try
        body()
    catch ex
        push!(exceptions, (; t=Dates.now(), ex, args, kwargs...))
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        rethrow_exception && rethrow()
        nothing
    end
end

function range(
        res::Vector, order_by;
        by=r->r[2], 
        element_id=function (r)
            if r[1] isa Nostr.Event
                Nostr.hex(r[1].id)
            elseif r[1] isa Nostr.EventId || r[1] isa Nostr.PubKeyId
                Nostr.hex(r[1])
            elseif r[1] isa Vector{UInt8}
                bytes2hex(r[1])
            elseif r[1] isa String
                r[1]
            else
                println("range element_id: $((typeof(r[1]), r[1]))")
                "?"
            end
        end)
    if isempty(res)
        [(; kind=Int(RANGE), content=JSON.json((; order_by, elements=[])))]
    else
        since = min(by(res[1]), by(res[end]))
        until = max(by(res[1]), by(res[end]))
        elements = try
            [element_id(r) for r in sort(res; by=r->-by(r))]
        catch _; [] end
        [(; kind=Int(RANGE), content=JSON.json((; since, until, order_by, elements))),
         # (; kind=Int(COLLECTION_ORDER), content=JSON.json((; order_by, elements)))
        ]
    end
end

function follows(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)::Vector{Nostr.PubKeyId}
    if pubkey in est.contact_lists 
        res = Nostr.PubKeyId[]
        cid = est.contact_lists[pubkey]
        if cid in est.events
            for t in est.events[cid].tags
                if length(t.fields) >= 2 && t.fields[1] == "p"
                    try push!(res, Nostr.PubKeyId(t.fields[2])) catch _ end
                end
            end
        end
        # res
        first(res, 5000)
    else
        []
    end
end

function event_stats(est::DB.CacheStorage, eid::Nostr.EventId)
    r = DB.exe(est.event_stats, DB.@sql("select likes, replies, mentions, reposts, zaps, satszapped, score, score24h from event_stats where event_id = ?1"), eid)
    if isempty(r)
        @debug "event_stats: ignoring missing event $(eid)"
        []
    else
        es = zip([:likes, :replies, :mentions, :reposts, :zaps, :satszapped, :score, :score24h], r[1])
        [(; 
             kind=Int(EVENT_STATS),
             content=JSON.json((; event_id=eid, es..., bookmarks=0)))]
    end
end

function event_actions_cnt(est::DB.CacheStorage, eid::Nostr.EventId, user_pubkey::Nostr.PubKeyId)
    r = DB.exe(est.event_pubkey_actions, DB.@sql("select replied, liked, reposted, zapped from event_pubkey_actions where event_id = ?1 and pubkey = ?2"), eid, user_pubkey)
    if isempty(r)
        []
    else
        ea = zip([:replied, :liked, :reposted, :zapped], map(Bool, r[1]))
        [(; 
          kind=Int(EVENT_ACTIONS_COUNT),
          content=JSON.json((; event_id=eid, ea...)))]
    end
end

function event_actions(est::DB.CacheStorage; 
        event_id=nothing,
        pubkey=nothing, identifier=nothing,
        kind::Int, 
        limit=100, offset=0,
    )
    limit <= 1000 || error("limit too big")
    event_id = castmaybe(event_id, Nostr.EventId)
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)

    res = []
    pks = Set{Nostr.PubKeyId}()

    r = if !isnothing(event_id)
        DB.exe(est.event_pubkey_action_refs, DB.@sql("
                        select ref_event_id, ref_pubkey from event_pubkey_action_refs 
                        where event_id = ?1 and ref_kind = ?2 
                        order by ref_created_at desc
                        limit ?3 offset ?4"),
               event_id, kind, limit, offset)
                        
    elseif !isnothing(pubkey) && !isnothing(identifier) 
        Postgres.pex(DAG_OUTPUTS_DB[], pgparams() do P "
                        SELECT
                            ref_event_id, 
                            ref_pubkey
                        FROM
                            reads_versions,
                            event_pubkey_action_refs
                        WHERE 
                            reads_versions.pubkey = $(@P pubkey) AND 
                            reads_versions.identifier = $(@P identifier) AND 
                            reads_versions.eid = event_pubkey_action_refs.event_id AND
                            event_pubkey_action_refs.ref_kind = $(@P kind)
                        ORDER BY
                            event_pubkey_action_refs.ref_created_at DESC
                        LIMIT $(@P limit) OFFSET $(@P offset)
                    " end...)
    else
        []
    end

    for (reid, pk) in r
        push!(pks, Nostr.PubKeyId(pk))
        reid = Nostr.EventId(reid)
        reid in est.events && push!(res, est.events[reid])
    end

    [res; user_infos(est; pubkeys=collect(pks))]
end

THash = Vector{UInt8}
parsed_mutelists = Dict{Nostr.PubKeyId, Tuple{Nostr.EventId, Any}}() |> ThreadSafe
compiled_content_moderation_rules = Dict{Union{Nostr.PubKeyId,Nothing}, Tuple{THash, Any}}() |> ThreadSafe

function compile_content_moderation_rules(est::DB.CacheStorage, pubkey)
    cmr = (; 
           pubkeys = Dict{Nostr.PubKeyId, NamedTuple{(:parent, :scopes), Tuple{Nostr.PubKeyId, Set{Symbol}}}}(),
           groups = Dict{Symbol, NamedTuple{(:scopes,), Tuple{Set{Symbol}}}}(),
           pubkeys_allowed = Set{Nostr.PubKeyId}(),
           blocked_threads = Set{Nostr.EventId}(), # scope: content
           blocked_hashtags = Set{String}(), # scope: content
           blocked_words = Set{String}(), # scope: content
          )
    r = catch_exception(:compile_content_moderation_rules, (; pubkey)) do
        settings = ext_user_get_settings(est, pubkey)
        (isnothing(settings) || !get(settings, "applyContentModeration", false)) && return cmr

        eids = Set{Nostr.EventId}()

        push!(eids, settings["id"])

        if !isnothing(pubkey)
            ml = (; 
                  pubkeys = Dict{Nostr.PubKeyId, Set{Symbol}}(),
                  groups = Dict{Symbol, Set{Symbol}}(),
                  blocked_threads = Set{Nostr.EventId}(),
                  blocked_hashtags = Set{String}(),
                  blocked_words = Set{String}(),
                 )

            if pubkey in est.mute_lists
                local mlseid = est.mute_lists[pubkey]
                push!(eids, mlseid)

                pml = get(parsed_mutelists, pubkey, nothing)
                if isnothing(pml) || pml[1] != mlseid
                    for tag in est.events[mlseid].tags
                        if length(tag.fields) >= 2
                            if tag.fields[1] == "p"
                                scopes = if length(tag.fields) >= 5
                                    Set([Symbol(s) for s in JSON.parse(tag.fields[5])])
                                else
                                    Set{Symbol}([:content, :trending])
                                end
                                if !isempty(scopes)
                                    ml.pubkeys[Nostr.PubKeyId(tag.fields[2])] = scopes
                                end
                                # elseif tag.fields[1] == "group"
                                #     ml.groups[Symbol(tag.fields[2])] = if length(tag.fields) >= 3
                                #         Set([Symbol(s) for s in JSON.parse(tag.fields[3])])
                                #     else
                                #         Set{Symbol}()
                                #     end
                            end
                        end
                    end
                    parsed_mutelists[pubkey] = (mlseid, ml)
                else
                    ml = pml[2]
                end
            end

            pks = Set{Nostr.PubKeyId}()

            push!(eids, settings["id"])

            pubkey in est.mute_lists && push!(eids, est.mute_lists[pubkey])
            pubkey in est.allow_list && push!(eids, est.allow_list[pubkey])

            for pk in [pubkey; collect(keys(ml.pubkeys))]
                for tbl in [est.mute_list, est.mute_list_2, est.allow_list]
                    pk in tbl && push!(eids, tbl[pk])
                end
            end
        end

        eids = sort(collect(eids))

        h = SHA.sha256(vcat([0x00], [eid.hash for eid in eids]...))

        cmr_ = get(compiled_content_moderation_rules, pubkey, nothing)
        !isnothing(cmr_) && cmr_[1] == h && return cmr_[2]

        catch_exception(:compile_content_moderation_rules_calc, (; pubkey)) do
            !isnothing(pubkey) && for ppk in [pubkey, collect(keys(ml.pubkeys))...]
                for tbl in [est.mute_list, est.mute_list_2]
                    if ppk in tbl
                        for tag in est.events[tbl[ppk]].tags
                            if length(tag.fields) >= 2
                                if tag.fields[1] == "p"
                                    if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                                        cmr.pubkeys[pk] = (; parent=ppk, 
                                                           scopes=haskey(ml.pubkeys, ppk) ? ml.pubkeys[ppk] : Set{Symbol}())
                                    end
                                elseif tag.fields[1] == "e"
                                    try push!(cmr.blocked_threads, Nostr.EventId(tag.fields[2])) catch _ end
                                elseif tag.fields[1] == "t"
                                    push!(cmr.blocked_hashtags, tag.fields[2])
                                elseif tag.fields[1] == "word"
                                    push!(cmr.blocked_words, tag.fields[2])
                                end
                            end
                        end
                    end
                end
            end

            for cm in settings["contentModeration"]
                scopes = Set([Symbol(s) for s in cm["scopes"]])
                if !isempty(scopes)
                    cmr.groups[Symbol(cm["name"])] = (; scopes)
                end
            end

            !isnothing(pubkey) && if pubkey in est.allow_list
                for tag in est.events[est.allow_list[pubkey]].tags
                    if length(tag.fields) >= 2 && tag.fields[1] == "p"
                        if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                            push!(cmr.pubkeys_allowed, pk)
                        end
                    end
                end
            end
        end

        compiled_content_moderation_rules[pubkey] = (h, cmr)

        ext_invalidate_cached_content_moderation(est, pubkey)

        cmr
    end
    r isa NamedTuple ? r : cmr
end

function import_content_moderation_rules(est::DB.CacheStorage, user_pubkey)
    cmr = compile_content_moderation_rules(est, user_pubkey)
    Postgres.transaction(DAG_OUTPUTS_DB[]) do sess
        for tbl in [
                    :cmr_pubkeys_scopes,
                    :cmr_pubkeys_parent,
                    :cmr_groups,
                    :cmr_pubkeys_allowed,
                    :cmr_threads,
                    :cmr_hashtags,
                    :cmr_words,
                    :cmr_hashtags_2,
                    :cmr_words_2,
                   ]
            Postgres.execute(sess, "delete from $tbl where user_pubkey = \$1", [user_pubkey])
        end
        for (pk, p) in cmr.pubkeys
            for scope in (isempty(p.scopes) ? [:content, :trending] : p.scopes)
                Postgres.execute(sess, "insert into cmr_pubkeys_scopes values (\$1, \$2, \$3::cmr_scope)", [user_pubkey, pk, scope])
            end
            Postgres.execute(sess, "insert into cmr_pubkeys_parent values (\$1, \$2, \$3)", [user_pubkey, pk, p.parent])
        end
        for (grp, g) in cmr.groups
            for scope in (isempty(g.scopes) ? [:content, :trending] : g.scopes)
                Postgres.execute(sess, "insert into cmr_groups values (\$1, \$2::cmr_grp, \$3::cmr_scope)", [user_pubkey, grp, scope])
            end
        end
        for pk in cmr.pubkeys_allowed
            Postgres.execute(sess, "insert into cmr_pubkeys_allowed values (\$1, \$2)", [user_pubkey, pk])
        end
        for scope in [:content, :trending]
            for eid in cmr.blocked_threads
                Postgres.execute(sess, "insert into cmr_threads values (\$1, \$2, \$3::cmr_scope)", [user_pubkey, eid, scope])
            end
            for ht in cmr.blocked_hashtags
                Postgres.execute(sess, "insert into cmr_hashtags values (\$1, \$2, \$3::cmr_scope)", [user_pubkey, ht, scope])
            end
            for w in cmr.blocked_words
                Postgres.execute(sess, "insert into cmr_words values (\$1, \$2, \$3::cmr_scope)", [user_pubkey, w, scope])
            end
            function make_tsquery(ws)
                res = []
                for w in ws
                    w = replace(w, r"[^a-zA-Z0-9_]" => " ")
                    w = replace(w, r"\s+" => " ")
                    w = string(strip(w))
                    w = "\"$(replace(w, " "=>"\\ "))\""
                    push!(res, w)
                end
                res = join(res, " | ")
                # @show ws=>res
                res
            end
            isempty(cmr.blocked_hashtags) || Postgres.execute(sess, "insert into cmr_hashtags_2 values (\$1, \$2::cmr_scope, to_tsquery('simple', \$3))", 
                                                              [user_pubkey, scope, make_tsquery(cmr.blocked_hashtags)])
            isempty(cmr.blocked_words) || Postgres.execute(sess, "insert into cmr_words_2 values (\$1, \$2::cmr_scope, to_tsquery('simple', \$3))", 
                                                           [user_pubkey, scope, make_tsquery(cmr.blocked_words)])
        end
    end
end

is_hidden(est::DB.CacheStorage, user_pubkey, scope::Symbol, pubkey::Nostr.PubKeyId) = false
is_hidden(est::DB.CacheStorage, user_pubkey, scope::Symbol, eid::Nostr.EventId) = false

function is_hidden_(est::DB.CacheStorage, cmr::NamedTuple, user_pubkey, scope::Symbol, pubkey::Nostr.PubKeyId)
    pubkey in cmr.pubkeys_allowed && return false
    if haskey(cmr.pubkeys, pubkey)
        scopes = cmr.pubkeys[pubkey].scopes
        isempty(scopes) ? true : scope in scopes
    else
        ext_is_hidden_by_group(est, cmr, user_pubkey, scope, pubkey)
    end
end
function is_hidden_(est::DB.CacheStorage, cmr::NamedTuple, user_pubkey, scope::Symbol, eid::Nostr.EventId)
    eid in est.events && is_hidden(est, user_pubkey, scope, est.events[eid].pubkey) && return true
    ext_is_hidden_by_group(est, cmr, user_pubkey, scope, eid)
end

RELAY_URL_MAP = Dict{String, String}()

RESPONSE_MESSAGES_CACHE_ENABLED = Ref(false)
response_messages_for_posts_cache_periodic = Throttle(; period=300.0)
response_messages_for_posts_cache = Dict{Tuple{Nostr.EventId, Union{Nothing, Nostr.PubKeyId}}, Any}() |> ThreadSafe
response_messages_for_posts_reids_cache = Dict{Tuple{Nostr.EventId}, Any}() |> ThreadSafe
response_messages_for_posts_res_meta_data_cache = Dict{Nostr.EventId, Any}() |> ThreadSafe
response_messages_for_posts_mds_cache = Dict{Nostr.EventId, Any}() |> ThreadSafe

function response_messages_for_posts(
        est::DB.CacheStorage, eids::Vector{Nostr.EventId}; 
        res_meta_data=Dict(), user_pubkey=nothing,
        include_top_zaps=true,
        time_exceeded=()->false,
    )
    if RESPONSE_MESSAGES_CACHE_ENABLED[]
        response_messages_for_posts_cache_periodic() do
            empty!(response_messages_for_posts_cache)
            empty!(response_messages_for_posts_reids_cache)
            empty!(response_messages_for_posts_res_meta_data_cache)
            empty!(response_messages_for_posts_mds_cache)
        end
    end

    function mkres()
        (;
         res = OrderedSet(),
         pks = Set{Nostr.PubKeyId}(),
         event_relays = Dict{Nostr.EventId, String}(),
         reids = Set{Nostr.EventId}(),
        )
    end

    function handle_event(
            body::Function, eid::Nostr.EventId; 
            wrapfun::Function=identity, 
            res::OrderedSet, pks::Set{Nostr.PubKeyId}, event_relays::Dict{Nostr.EventId, String},
            reids::Set{Nostr.EventId}, 
        )
        ext_is_hidden(est, eid) && return
        eid in est.deleted_events && return

        e = if eid in est.events
            est.events[eid]
        # elseif !isempty(local r = Postgres.execute(:p1, "select * from events where id = \$1 limit 1", [eid])[2])
        #     event_from_row(r[1])
        else
            return
        end

        # is_hidden(est, user_pubkey, :content, e.pubkey) && return
        # ext_is_hidden(est, e.pubkey) && return

        # e.kind == Int(Nostr.REPOST) && try 
        #     hide = false
        #     for t in e.tags
        #         if t.fields[1] == "p"
        #             pk = Nostr.PubKeyId(t.fields[2])
        #             hide |= is_hidden(est, user_pubkey, :content, pk) || ext_is_hidden(est, pk) 
        #         end
        #     end
        #     hide
        # catch _ false end && return

        if e.kind == Int(Nostr.LONG_FORM_CONTENT)
            words = length(split(e.content))
            # push!(res, wrapfun((; e.id, kind=10_000_000 + e.kind, e.pubkey, e.created_at, e.tags, content=first(e.content, 1000))))
            push!(res, wrapfun(e))
            union!(res, [(; kind=Int(LONG_FORM_METADATA), content=JSON.json((; event_id=e.id, words)))])
        else
            push!(res, wrapfun(e))
        end

        union!(res, e.kind == Int(Nostr.LONG_FORM_CONTENT) ? 
               ext_long_form_event_stats(est, e.id) : 
               event_stats(est, e.id))
        # isnothing(user_pubkey) || union!(res, event_actions_cnt(est, e.id, user_pubkey))
        isnothing(user_pubkey) || push!(reids, e.id)
        push!(pks, e.pubkey)
        union!(res, ext_event_response(est, e))
        
        if !isempty(local relay = get(est.dyn[:event_relay], eid, ""))
            event_relays[eid] = relay
        end

        if include_top_zaps
            union!(res, [e for e in event_zaps_by_satszapped(est; event_id=eid, limit=5, user_pubkey)
                         if safekind(e) != Int(RANGE) && safekind(e) != Int(Nostr.TEXT_NOTE) && safekind(e) != Int(Nostr.LONG_FORM_CONTENT)])
            # 1==1 && if user_pubkey == Main.test_pubkeys[:qa]
                e.kind == Int(Nostr.LONG_FORM_CONTENT) && for t in e.tags
                    if length(t.fields) >= 2 && t.fields[1] == "d"
                        identifier = t.fields[2]
                        union!(res, [e for e in event_zaps_by_satszapped(est; pubkey=e.pubkey, identifier, limit=5, user_pubkey)
                                     if safekind(e) != Int(RANGE) && safekind(e) != Int(Nostr.TEXT_NOTE) && safekind(e) != Int(Nostr.LONG_FORM_CONTENT)])
                        break
                    end
                end
            # end
        end

        extra_tags = Nostr.Tag[]
        DB.for_mentiones(est, e) do tag
            push!(extra_tags, tag)
        end
        all_tags = vcat(e.tags, extra_tags)
        for tag in all_tags
            tag = tag.fields
            if length(tag) >= 2
                if tag[1] == "e" && !isnothing(local subeid = try Nostr.EventId(tag[2]) catch _ end)
                    body(subeid)
                elseif tag[1] == "p" && !isnothing(local pk = try Nostr.PubKeyId(tag[2]) catch _ end)
                    push!(pks, pk)
                elseif tag[1] == "a"
                    if !isnothing(local args = try
                                      kind, pk, identifier = map(string, split(tag[2], ':'))
                                      kind = parse(Int, kind)
                                      (Nostr.PubKeyId(pk), kind, identifier)
                                  catch _ end)
                        for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events],
                                              DB.@sql("select event_id from parametrized_replaceable_events where pubkey = ?1 and kind = ?2 and identifier = ?3 limit 1"),
                                              args)
                            body(Nostr.EventId(eid))
                        end
                    end
                end
            end
        end
    end

    r2 = mkres()

    event_relays = r2.event_relays

    # @time "eids" 
    for eid in eids
        r = RESPONSE_MESSAGES_CACHE_ENABLED[] ? get(response_messages_for_posts_cache, (eid, #=user_pubkey=#nothing), nothing) : nothing

        if isnothing(r)
            r = mkres()

            # @time "handle_event" 
            handle_event(eid; r.res, r.pks, r.event_relays, r.reids) do subeid
                yield()
                time_exceeded() && return
                handle_event(subeid; wrapfun=e->(; kind=Int(REFERENCED_EVENT), e.pubkey, content=JSON.json(e)), r.res, r.pks, r.event_relays, r.reids) do subeid
                    yield()
                    time_exceeded() && return
                    handle_event(subeid; wrapfun=e->(; kind=Int(REFERENCED_EVENT), e.pubkey, content=JSON.json(e)), r.res, r.pks, r.event_relays, r.reids) do _
                    end
                end
            end

            response_messages_for_posts_cache[(eid, #=user_pubkey=#nothing)] = r
        end

        union!(r2.res, r.res)
        union!(r2.pks, r.pks)
        event_relays = union(event_relays, r.event_relays)
        union!(r2.reids, r.reids)
    end

    res_meta_data = res_meta_data |> ThreadSafe
    # @time "pks" 
    for pk in r2.pks
        if !haskey(res_meta_data, pk) && pk in est.meta_data
            mdid = est.meta_data[pk]
            if mdid in est.events
                res_meta_data[pk] = if RESPONSE_MESSAGES_CACHE_ENABLED[]
                    lock(response_messages_for_posts_res_meta_data_cache) do response_messages_for_posts_res_meta_data_cache
                        get!(response_messages_for_posts_res_meta_data_cache, mdid) do
                            est.events[mdid]
                        end
                    end
                else
                    est.events[mdid]
                end
            end
        end
    end

    !isempty(event_relays) && union!(r2.res, [(; kind=Int(EVENT_RELAYS), content=JSON.json(Dict([Nostr.hex(k)=>get(RELAY_URL_MAP, v, v) for (k, v) in event_relays])))])

    res = copy(r2.res)

    # @time "reids" 
    isnothing(user_pubkey) || for reid in r2.reids
        union!(res, event_actions_cnt(est, reid, user_pubkey))
    end
       
    # @time "mds" 
    for md in values(res_meta_data)
        push!(res, md)
        union!(res, 
               if RESPONSE_MESSAGES_CACHE_ENABLED[]
                   lock(response_messages_for_posts_mds_cache) do response_messages_for_posts_mds_cache
                       get!(response_messages_for_posts_mds_cache, md.id) do
                           ext_event_response(est, md)
                       end
                   end
               else
                   ext_event_response(est, md)
               end)
    end

    if !isempty(r2.pks)
        union!(res, primal_verified_names(est, collect(r2.pks)))
    end

    collect(res)
end

function feed(
        est::DB.CacheStorage;
        pubkey=nothing, notes::Union{Symbol,String}=:follows, include_replies=false,
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing,
        time_exceeded=()->false,
        kwargs...,
    )
    feed_2(est; pubkey, notes, include_replies,
           since, until, limit, offset, order=:desc,
           user_pubkey, time_exceeded, kwargs...)
end

function feed_2(
        est::DB.CacheStorage;
        pubkey=nothing, notes::Union{Symbol,String}=:follows, include_replies=false,
        kinds=nothing,
        since::Union{Nothing,Int}=nothing, until::Union{Nothing,Int}=nothing, limit::Int=20, offset::Int=0, order::Union{Nothing,Symbol,String}=nothing,
        user_pubkey=nothing,
        time_exceeded=()->false,
        usepgfuncs=false,
        apply_humaness_check=false,
    )
    limit <= 1000 || error("limit too big")

    order = 
    if !isnothing(order)
        Symbol(order)
    elseif !isnothing(until)
        :desc
    elseif !isnothing(since)
        :asc
    else
        :desc
    end
    order in [:asc, :desc] || error("invalid order")

    since = isnothing(since) ? 0 : since
    until = isnothing(until) ? trunc(Int, time()) : until

    notes = Symbol(notes)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    tdur1 = tdur2 = 0
    events_scanned = 0

    posts = [] |> ThreadSafe
    if pubkey isa Nothing
        # @threads for dbconn in est.pubkey_events
        #     append!(posts, map(Tuple, DB.exe(dbconn, DB.@sql("select event_id, created_at from pubkey_events 
        #                                                       where created_at >= ?1 and created_at <= ?2 and (is_reply = 0 or is_reply = ?3)
        #                                                       order by created_at desc limit ?4 offset ?5"),
        #                                      (since, until, Int(include_replies), limit, offset))))
        # end
    elseif notes == :replies
        if usepgfuncs
            q = "select distinct e, e->>'created_at' from feed_user_authored(\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8) f(e) where e is not null order by e->>'created_at' desc"
            res = [r[1] for r in Postgres.pex(DAG_OUTPUTS_DB[], q, 
                                              [pubkey, since, until, 1, limit, offset, user_pubkey, false])]
            return res
        end
        append!(posts, map(Tuple, DB.exe(est.pubkey_events, 
                                         "select event_id, created_at from pubkey_events 
                                         where pubkey = ?1 and created_at >= ?2 and created_at <= ?3 and is_reply = 1
                                         order by created_at $order limit ?4 offset ?5",
                           pubkey, since, until, limit, offset)))
    elseif notes == :bookmarks
        if !isempty(local r = get_bookmarks(est; pubkey))
            bm = r[1]
            eids = []
            for t in bm.tags
                if length(t.fields) >= 2 
                    if     t.fields[1] == "e" && !isnothing(local eid = try Nostr.EventId(t.fields[2]) catch _ end)
                        push!(eids, eid)
                    elseif t.fields[1] == "a"
                        try
                            kind, pk, identifier = map(string, split(t.fields[2], ':'))
                            kind = parse(Int, kind)
                            pk = Nostr.PubKeyId(pk)
                            for (eid,) in DB.exe(est.dyn[:parametrized_replaceable_events], 
                                                 DB.@sql("select event_id from parametrized_replaceable_events 
                                                         where pubkey = ?1 and identifier = ?2 and kind = ?3"), 
                                                 pk, identifier, kind)
                                push!(eids, Nostr.EventId(eid))
                            end
                        catch ex
                            println(ex)
                        end
                    end
                end
            end
            bms = []
            for eid in eids
                if eid in est.events 
                    e = est.events[eid]
                    !isnothing(kinds) && !(e.kind in kinds) && continue
                    if eid in est.event_created_at
                        created_at = est.event_created_at[eid]
                        push!(bms, (collect(eid.hash), created_at))
                    end
                end
            end
            i = 0
            for (eid, created_at) in sort(bms; by=r->-r[2])
                length(posts) >= limit && break
                if since <= created_at <= until
                    i >= offset && push!(posts, (eid, created_at))
                    i += 1
                end
            end
        end
    elseif notes == :user_media_thumbnails
        for (eid, created_at) in Postgres.pex(DAG_OUTPUTS_DB[], "
            SELECT
                DISTINCT es.id, es.created_at
            FROM
                events es,
                event_media em
            WHERE 
                es.pubkey = \$1 AND 
                es.kind = $(Int(Nostr.TEXT_NOTE)) AND 
                es.id = em.event_id AND
                NOT EXISTS (SELECT 1 FROM event_preview ep WHERE ep.event_id = em.event_id) AND
                es.created_at >= \$2 AND es.created_at <= \$3
            ORDER BY
                es.created_at DESC
            LIMIT \$4 OFFSET \$5
            ", [pubkey, since, until, limit, offset])
            push!(posts, (eid, created_at))
        end
    else
        tdur2 = @elapsed begin
            if notes == :follows
                if usepgfuncs
                    if !isempty(Postgres.pex(DAG_OUTPUTS_DB[], "select 1 from pubkey_followers pf where pf.follower_pubkey = ?1 limit 1", (pubkey,)))
                        q = "select distinct e, e->>'created_at' from feed_user_follows(\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8) f(e) where e is not null order by e->>'created_at' desc"
                        return [r[1] for r in Postgres.pex(DAG_OUTPUTS_DB[], q, 
                                                           [pubkey, since, until, Int(include_replies), limit, offset, user_pubkey, apply_humaness_check])]
                    end
                end
                if !isempty(Postgres.pex(DAG_OUTPUTS_DB[], "select 1 from pubkey_followers pf where pf.follower_pubkey = ?1 limit 1", (pubkey,)))
                    append!(posts, map(Tuple, Postgres.pex(DAG_OUTPUTS_DB[],
                                                           "select pe.event_id, pe.created_at 
                                                           from pubkey_events pe, pubkey_followers pf
                                                           where pf.follower_pubkey = ?1 and pf.pubkey = pe.pubkey and pe.created_at >= ?2 and pe.created_at <= ?3 and (pe.is_reply = 0 or pe.is_reply = ?4)
                                                           order by pe.created_at $order limit ?5 offset ?6",
                                                           (pubkey, since, until, Int(include_replies), limit, offset))))
                end
            elseif notes == :authored
                (is_user_blocked(pubkey, :csam) || is_user_blocked(pubkey, :impersonation)) && return []
                if usepgfuncs
                    q = "select distinct e, e->>'created_at' from feed_user_authored(\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8) f(e) where e is not null order by e->>'created_at' desc"
                    res = [r[1] for r in Postgres.pex(DAG_OUTPUTS_DB[], q, 
                                                      [pubkey, since, until, Int(include_replies), limit, offset, user_pubkey, false])]
                    return res
                end
                append!(posts, map(Tuple, Postgres.pex(DAG_OUTPUTS_DB[],
                                                       "select pe.event_id, pe.created_at 
                                                       from pubkey_events pe
                                                       where pe.pubkey = ?1 and pe.created_at >= ?2 and pe.created_at <= ?3 and (pe.is_reply = 0 or pe.is_reply = ?4)
                                                       order by pe.created_at $order limit ?5 offset ?6",
                                                       (pubkey, since, until, Int(include_replies), limit, offset))))
            else
                error("unsupported type of notes")
            end
        end
    end

    posts = first(sort(posts.wrapped, by=p->p[2], rev=order!=:asc), limit)

    eids = [Nostr.EventId(eid) for (eid, _) in posts]

    # if user_pubkey == Main.test_pubkeys[:qa]
    #     Main.stuffd[:eids] = eids
    # end

    tdur3 = @elapsed (res = response_messages_for_posts(est, eids; user_pubkey, time_exceeded))

    # @show (tdur1, tdur2, tdur3)

    vcat(res, range(posts, :created_at))
end

function thread_view(est::DB.CacheStorage; 
        event_id, 
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        # usepgfuncs=false, 
        usepgfuncs=true, 
        user_pubkey=nothing, 
        apply_humaness_check=false,
        kwargs...)
    event_id = cast(event_id, Nostr.EventId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    (is_user_blocked(est.events[event_id].pubkey, :csam) || is_user_blocked(est.events[event_id].pubkey, :impersonation)) && return []

    est.auto_fetch_missing_events && DB.fetch_event(est, event_id)

    if usepgfuncs
        include_parent_posts = get(kwargs, :include_parent_posts, true)
        res = map(first, Postgres.pex(DAG_OUTPUTS_DB[], "select * from thread_view(\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)",
                                      [event_id, limit, since, until, offset, user_pubkey, apply_humaness_check, include_parent_posts]))
        return res
    end

    res = OrderedSet()

    hidden = is_hidden(est, user_pubkey, :content, event_id) || ext_is_hidden(est, event_id) || event_id in est.deleted_events

    hidden || union!(res, thread_view_replies(est; event_id, limit, since, until, offset, user_pubkey))
    union!(res, thread_view_parents(est; event_id, user_pubkey))

    collect(res)
end

function thread_view_replies(est::DB.CacheStorage;
        event_id,
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing,
    )
    limit <= 1000 || error("limit too big")
    event_id = cast(event_id, Nostr.EventId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    posts = Tuple{Nostr.EventId, Int}[]
    for (reid, created_at) in DB.exe(est.event_replies, DB.@sql("select reply_event_id, reply_created_at from event_replies
                                                                 where event_id = ?1 and reply_created_at >= ?2 and reply_created_at <= ?3
                                                                 order by reply_created_at desc limit ?4 offset ?5"),
                                     event_id, since, until, limit, offset)
        push!(posts, (Nostr.EventId(reid), created_at))
    end
    posts = first(sort(posts, by=p->-p[2]), limit)
    
    reids = [reid for (reid, _) in posts]
    [response_messages_for_posts(est, reids; user_pubkey); range(posts, :created_at)]
end

function thread_view_parents(est::DB.CacheStorage; event_id, user_pubkey=nothing)
    event_id = cast(event_id, Nostr.EventId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    posts = Tuple{Nostr.EventId, Int}[]
    peid = event_id
    while true
        if peid in est.events
            push!(posts, (peid, est.events[peid].created_at))
        else
            @debug "missing thread parent event $peid not found in storage"
        end
        if peid in est.event_thread_parents
            peid = est.event_thread_parents[peid]
        else
            break
        end
    end

    posts = sort(posts, by=p->p[2])

    reids = [reid for (reid, _) in posts]

    response_messages_for_posts(est, reids; user_pubkey)
end

NETWORK_STATS_URL = Ref{Any}(nothing)

function network_stats(est::DB.CacheStorage)
    if !isnothing(NETWORK_STATS_URL[])
        r = JSON.parse(String(HTTP.request("GET", NETWORK_STATS_URL[], [], JSON.json(["network_stats", (;)])).body))
        (; kind=Int(NET_STATS), content=r[2])
    else
        lock(est.commons.stats) do stats
            (;
             kind=Int(NET_STATS),
             content=JSON.json((;
                                [k => get(stats, k, 0)
                                 for k in [:users,
                                           :pubkeys,
                                           :pubnotes,
                                           :reactions,
                                           :reposts,
                                           :any,
                                           :zaps,
                                           :satszapped,
                                          ]]...)))
        end
    end
end

function user_scores(est::DB.CacheStorage, pubkeys::Vector{Nostr.PubKeyId})
    d = Dict()
    # for pk in pubkeys
    #     rs = DB.exec(est.dyn[:pubkey_trustrank], "select rank from pubkey_trustrank where pubkey = ?1", [pk])
    #     isempty(rs) || (d[Nostr.hex(pk)] = trunc(Int, rs[1][1]*10000000000))
    # end
    d = Dict([(Nostr.hex(pubkey), get(est.pubkey_followers_cnt, pubkey, 0))
              for pubkey in pubkeys])
    isempty(d) ? [] : [(; kind=Int(USER_SCORES), content=JSON.json(d))]
end
function user_scores(est::DB.CacheStorage, res_meta_data)
    user_scores(est, Nostr.PubKeyId[e.pubkey for e in collect(res_meta_data)])
end

function user_trustranks(est::DB.CacheStorage, pubkeys::Vector{Nostr.PubKeyId})
    d = Dict()
    for pk in pubkeys
        rs = DB.exec(est.dyn[:pubkey_trustrank], "select rank from pubkey_trustrank where pubkey = ?1", [pk])
        isempty(rs) || (d[Nostr.hex(pk)] = rs[1][1])
    end
    isempty(d) ? [] : [(; kind=Int(USER_TRUSTRANKS), content=JSON.json(d))]
end

function contact_list(est::DB.CacheStorage; pubkey, extended_response=true)
    pubkey = cast(pubkey, Nostr.PubKeyId)

    res = []

    if pubkey in est.contact_lists
        eid = est.contact_lists[pubkey]
        eid in est.events && push!(res, est.events[eid])
    end

    extended_response && append!(res, user_infos(est; pubkeys=follows(est, pubkey)))

    res
end

function is_user_following(est::DB.CacheStorage; pubkey, user_pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)
    [(; 
      kind=Int(IS_USER_FOLLOWING),
      content=JSON.json(user_pubkey in follows(est, pubkey)))]
end

import MbedTLS
user_infos_cache_periodic = Throttle(; period=60.0)
user_infos_cache = Dict{NTuple{20, UInt8}, Any}() |> ThreadSafe

function user_infos(est::DB.CacheStorage; pubkeys::Vector, usepgfuncs=false, apply_humaness_check=false)
    return user_infos_1(est; pubkeys, usepgfuncs, apply_humaness_check)

    user_infos_cache_periodic() do
        empty!(user_infos_cache)
    end
    bio = IOBuffer()
    for pk in pubkeys
        write(bio, castmaybe(pk, Nostr.PubKeyId).pk)
    end
    k = NTuple{20, UInt8}(MbedTLS.digest(MbedTLS.MD_SHA1, take!(bio)))
    lock(user_infos_cache) do user_infos_cache
        get!(user_infos_cache, k) do
            user_infos_1(est; pubkeys)
        end
    end
end

function castnamedtuple(d)
    if     d isa NamedTuple; d
    elseif d isa Dict; d["kind"] < 10_000_000 ? Nostr.Event(d) : (; [Symbol(k)=>v for (k, v) in d]...)
    elseif d isa Missing; nothing
    else; error("invalid argument: $d")
    end
end
        
function primal_verified_names(est::DB.CacheStorage, pubkeys::Vector)
    pks = '{'*join([Nostr.hex(pk) for pk in pubkeys], ',')*'}'
    res = []
    append!(res, [castnamedtuple(e) for (e,) in Postgres.pex(DAG_OUTPUTS_DB[], "select * from primal_verified_names(array(select decode(unnest(\$1::text[]), 'hex')))", [pks])])
    append!(res, [castnamedtuple(e) for (e,) in Postgres.pex(DAG_OUTPUTS_DB[], "select * from  user_blossom_servers(array(select decode(unnest(\$1::text[]), 'hex')))", [pks])])
    return res

    # res_primal_names = Dict()
    # res_legend_customization = Dict()
    # res_cohorts = Dict()
    # for pk in pubkeys
    #     for name in Main.InternalServices.nostr_json_query_by_pubkey(pk; default_name=true)
    #         res_primal_names[pk] = name
    #     end
    #     for (_, style, custom_badge, avatar_glow) in Postgres.execute(:membership, "select * from membership_legend_customization where pubkey = \$1", [pk])[2]
    #         res_legend_customization[pk] = (; style, custom_badge, avatar_glow)
    #     end
    #     for (cohort_1, cohort_2, tier, valid_until) in Postgres.execute(:membership, "
    #                                                                     select cohort_1, cohort_2, tier, valid_until 
    #                                                                     from memberships where 
    #                                                                     pubkey = \$1 and (tier = 'premium' or tier = 'premium-legend')
    #                                                                     ", [pk])[2]
    #         res_cohorts[pk] = (; cohort_1, cohort_2, tier, expires_on=ismissing(valid_until) ? nothing : trunc(Int, Dates.datetime2unix(valid_until)))
    #     end
    # end

    # res = []
    # if !isempty(res_primal_names)
    #     push!(res, (; kind=USER_PRIMAL_NAMES, content=JSON.json(Dict([Nostr.hex(pk)=>name for (pk, name) in res_primal_names]))))
    # end
    # if !isempty(res_legend_customization)
    #     push!(res, (; kind=MEMBERSHIP_LEGEND_CUSTOMIZATION, content=JSON.json(Dict([Nostr.hex(pk)=>r for (pk, r) in res_legend_customization]))))
    # end
    # if !isempty(res_cohorts)
    #     push!(res, (; kind=MEMBERSHIP_COHORTS, content=JSON.json(Dict([Nostr.hex(pk)=>r for (pk, r) in res_cohorts]))))
    # end
    # res
end

function user_follower_counts(est::DB.CacheStorage, pubkeys::Vector)
    [(; kind=USER_FOLLOWER_COUNTS,
      content=JSON.json(Dict([Nostr.hex(pk)=>get(est.pubkey_followers_cnt, pk, 0) for pk in pubkeys])))]
end

function user_infos_1(est::DB.CacheStorage; pubkeys::Vector, usepgfuncs=true, apply_humaness_check=false)
    pubkeys = [pk isa Nostr.PubKeyId ? pk : Nostr.PubKeyId(pk) for pk in pubkeys]

    if usepgfuncs
        return [castnamedtuple(e) for (e,) in Postgres.pex(DAG_OUTPUTS_DB[], "select * from user_infos(\$1::text[])", 
                                                           ['{'*join(['"'*Nostr.hex(pk)*'"' for pk in pubkeys], ',')*'}']
                                                           ) if !(e isa Missing)]
    end

    res_meta_data = Dict() |> ThreadSafe
    for pk in pubkeys 
        if pk in est.meta_data
            eid = est.meta_data[pk]
            eid in est.events && (res_meta_data[pk] = est.events[eid])
        end
    end
    res_meta_data_arr = []
    for pk in pubkeys
        if haskey(res_meta_data, pk) 
            push!(res_meta_data_arr, res_meta_data[pk])
        end
    end
    res = [
           res_meta_data_arr..., user_scores(est, res_meta_data_arr)..., 
           user_follower_counts(est, pubkeys)...,
           primal_verified_names(est, pubkeys)...,
          ]
    ext_user_infos(est, res, res_meta_data_arr)
    res
end

function user_followers(est::DB.CacheStorage; pubkey, limit=200)
    limit <= 1000 || error("limit too big")
    pubkey = cast(pubkey, Nostr.PubKeyId)
    pks = Set{Nostr.PubKeyId}()

    for r in DB.exe(est.pubkey_followers, 
                    DB.@sql("select pf1.follower_pubkey 
                            from pubkey_followers pf1, pubkey_followers pf2
                            where 
                              pf1.pubkey = ?1 and pf2.pubkey = pf1.follower_pubkey and pf2.follower_pubkey = ?1
                            "), pubkey)
        length(pks) < limit || break
        pk = Nostr.PubKeyId(r[1])
        pk in pks || push!(pks, pk)
    end

    length(pks) < limit && for r in DB.exe(est.pubkey_followers, 
                    DB.@sql("select distinct pf.follower_pubkey, pfc.value
                            from pubkey_followers pf, pubkey_followers_cnt pfc 
                            where pf.pubkey = ?1 and pf.follower_pubkey = pfc.key
                            order by pfc.value desc
                            limit ?2"), pubkey, limit-length(pks))
        length(pks) < limit || break
        pk = Nostr.PubKeyId(r[1])
        pk in pks || push!(pks, pk)
    end

    user_infos(est; pubkeys=collect(pks), usepgfuncs=true)
end

function mutual_follows(est::DB.CacheStorage; pubkey, user_pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)
    pks = Set{Nostr.PubKeyId}()
    for pk in follows(est, user_pubkey)
        if !isempty(DB.exe(est.pubkey_followers, 
                           DB.@sql("select 1 from pubkey_followers 
                                   where pubkey = ?1 and follower_pubkey = ?2
                                   limit 1"), pubkey, pk))
            push!(pks, pk)
        end
    end
    user_infos(est; pubkeys=collect(pks))
end

function events(
        est::DB.CacheStorage; 
        event_ids::Vector=[], extended_response::Bool=false, user_pubkey=nothing,
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        idsonly=false, usepgfuncs=true,
    )
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    if isempty(event_ids)
        event_ids = [r[1] for r in DB.exec(est.event_created_at, 
                                           DB.@sql("select event_id from event_created_at 
                                                   where created_at >= ?1 and created_at <= ?2 
                                                   order by created_at asc 
                                                   limit ?3 offset ?4"),
                                           (since, until, limit, offset))]
    end

    event_ids = [cast(eid, Nostr.EventId) for eid in event_ids]

    if idsonly
        [(; kind=Int(EVENT_IDS), ids=event_ids)]
    elseif !extended_response
        res = [] |> ThreadSafe
        @threads for eid in event_ids 
        # for eid in event_ids 
            eid in est.events && push!(res, est.events[eid])
        end
        sort(res.wrapped; by=e->e.created_at)
    else
        if usepgfuncs
            res = []
            posts = Tuple{Nostr.EventId, Int}[]
            for eid in event_ids
                e = est.events[eid]
                push!(posts, (eid, e.created_at))
                if e.kind == Int(Nostr.ZAP_RECEIPT)
                    try
                        for t in e.tags
                            if t.fields[1] == "description"
                                pk = Nostr.PubKeyId(JSON.parse(t.fields[2])["pubkey"])
                                if pk in est.meta_data
                                    md = est.events[est.meta_data[pk]]
                                    push!(res, md)
                                end
                            end
                        end
                    catch _ end
                end
            end
            [res; enrich_feed_events_pg(est; posts, user_pubkey)]
        else
            response_messages_for_posts(est, event_ids; user_pubkey)
        end
    end
end

blocked_user_profiles = Set{Nostr.PubKeyId}() |> ThreadSafe

function is_user_blocked(pubkey::Nostr.PubKeyId, grp)::Bool
    pubkey in blocked_user_profiles && return true
    isempty(Postgres.execute(:p0, "select 1 from filterlist where grp = \$2 and target_type = 'pubkey' and target = \$1 and blocked limit 1", 
                             [pubkey, grp])[2]) || return true
    false
end

function user_profile(est::DB.CacheStorage; pubkey, user_pubkey=nothing)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    (is_user_blocked(pubkey, :csam) || is_user_blocked(pubkey, :impersonation)) && return []

    est.auto_fetch_missing_events && DB.fetch_user_metadata(est, pubkey)

    res = [] |> ThreadSafe

    pubkey in est.meta_data && push!(res, est.events[est.meta_data[pubkey]])

    note_count  = DB.exe(est.pubkey_events, DB.@sql("select count(1) from pubkey_events where pubkey = ?1 and is_reply = 0"), pubkey)[1][1]
    reply_count = DB.exe(est.pubkey_events, DB.@sql("select count(1) from pubkey_events where pubkey = ?1 and is_reply = 1"), pubkey)[1][1]
    long_form_note_count = DB.exe(est.dyn[:parametrized_replaceable_events], DB.@sql("select count(1) from parametrized_replaceable_events where pubkey = ?1 and kind = ?2"), pubkey, Int(Nostr.LONG_FORM_CONTENT))[1][1]
    # subscribable = any(e.kind == 37001 for e in creator_paid_tiers(est; pubkey))

    # time_joined_r = DB.exe(est.pubkey_events, DB.@sql("select created_at from pubkey_events
    #                                                    where pubkey = ?1
    #                                                    order by created_at asc limit 1"), pubkey)
    time_joined_r = DB.exe(est.pubkey_events, DB.@sql("with a as (select created_at from pubkey_events where pubkey = ?1) 
                                                      select min(created_at) from a"), pubkey)

    time_joined = isempty(time_joined_r) ? nothing : time_joined_r[1][1];

    relay_count = length(Set([t[2] for t in get_user_relays(est; pubkey)[end].tags]))

    push!(res, (;
                kind=Int(USER_PROFILE),
                content=JSON.json((;
                                   pubkey,
                                   follows_count=length(follows(est, pubkey)),
                                   followers_count=get(est.pubkey_followers_cnt, pubkey, 0),
                                   note_count,
                                   long_form_note_count,
                                   reply_count,
                                   time_joined,
                                   relay_count,
                                   # subscribable,
                                   ext_user_profile(est, pubkey)...,
                                  ))))
    append!(res, ext_user_profile_media(est, pubkey))

    append!(res, primal_verified_names(est, [pubkey]))

    !isnothing(user_pubkey) && is_hidden(est, user_pubkey, :content, pubkey) && append!(res, search_filterlist(est; pubkey, user_pubkey))
    
    append!(res, user_profile_live_streams(est, pubkey))

    res.wrapped
end

function user_profile_live_streams(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)
    res = []
    for (e,) in Postgres.execute(:p0, "
        SELECT get_event_jsonb(pre.event_id)
        FROM parametrized_replaceable_events pre, basic_tags bt
        WHERE pre.kind = 30311 AND pre.created_at >= extract(epoch from now() - interval '2d')::int8
          AND pre.event_id = bt.id AND bt.tag = 'p' AND bt.arg1 = \$1
          AND EXISTS (SELECT 1 FROM events es WHERE pre.event_id = es.id
                                                AND 'status' IN (SELECT jsonb_array_elements(es.tags)->>0)
                                                AND 'live' IN (SELECT jsonb_array_elements(es.tags)->>1))
        ", [pubkey])[2]
        e = castnamedtuple(e) 
        push!(res, e)
    end
    for (e,) in Postgres.execute(:p0, "
        SELECT get_event_jsonb(pre.event_id)
        FROM parametrized_replaceable_events pre
        WHERE pre.kind = 30311 AND pre.created_at >= extract(epoch from now() - interval '2d')::int8 AND pre.pubkey = \$1
          AND EXISTS (SELECT 1 FROM events es WHERE pre.event_id = es.id
                                                AND 'status' IN (SELECT jsonb_array_elements(es.tags)->>0)
                                                AND 'live' IN (SELECT jsonb_array_elements(es.tags)->>1))
        ", [pubkey])[2]
        e = castnamedtuple(e) 
        push!(res, e)
    end
    collect(Set(res))
end

function user_profile_followed_by(est::DB.CacheStorage; pubkey, user_pubkey, limit=10)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)
    limit = min(20, limit)

    res = []
    res_mds = []
    pks = Nostr.PubKeyId[]
    for r in Postgres.execute(DAG_OUTPUTS_DB[],
                              pgparams() do P "
                                  select 
                                      pf1.pubkey
                                  from 
                                    pubkey_followers pf1, 
                                    pubkey_followers pf2,
                                    pubkey_followers_cnt pfc
                                  where 
                                      $(@P user_pubkey) = pf1.follower_pubkey and 
                                      pf1.pubkey = pf2.follower_pubkey and
                                      pf2.pubkey = $(@P pubkey) and
                                      pf1.pubkey = pfc.key
                                  group by pf1.pubkey
                                  order by max(pfc.value) desc limit $(@P limit)
                              " end...)[2]
        pk = Nostr.PubKeyId(r[1])
        if pk in est.meta_data
            mdid = est.meta_data[pk]
            if mdid in est.events
                md = est.events[mdid]
                push!(res, md)
                push!(res_mds, md)
                push!(pks, pk)
                append!(res, ext_event_response(est, md))
            end
        end
    end

    append!(res, user_scores(est, res_mds))
    append!(res, primal_verified_names(est, pks))

    res
end

function parse_event_from_user(event_from_user::Dict)
    e = Nostr.Event(event_from_user)
    # e.created_at > time() - 300 || error("event is too old")
    e.created_at < time() + 300 || error("event from the future")
    Nostr.verify(e) || error("verification failed")
    e
end

function get_directmsg_count(est::DB.CacheStorage; receiver, sender=nothing)
    receiver = cast(receiver, Nostr.PubKeyId)
    sender = castmaybe(sender, Nostr.PubKeyId)
    
    cnt = 0
    for (c,) in DB.exe(est.pubkey_directmsgs_cnt,
                       DB.@sql("select cnt from pubkey_directmsgs_cnt 
                               where receiver = ?1 and (case when ?2::bytea is null then sender is null else sender = ?2 end) 
                               limit 1"),
                       receiver, sender)
        cnt = c
        break
    end
    [(; kind=Int(DIRECTMSG_COUNT), cnt)]
end

function get_directmsg_count_2(est::DB.CacheStorage; receiver, sender=nothing)
    cnt = get_directmsg_count(est; receiver, sender)[1].cnt
    [(; kind=Int(DIRECTMSG_COUNT_2), content=JSON.json(cnt))]
end

function get_directmsg_contacts(
        est::DB.CacheStorage; 
        user_pubkey, relation::Union{String,Symbol}=:any,
        limit=10000, offset=0, since=0, until=trunc(Int, time()),
    )
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)
    # if 1==1 && user_pubkey in [Main.test_pubkeys[:pedja], Main.test_pubkeys[:qa], Main.test_pubkeys[:miljan], Main.test_pubkeys[:moysie]]
        get_directmsg_contacts_2(est; user_pubkey, relation, limit, offset, since, until)
    # else
    #     get_directmsg_contacts_1(est; user_pubkey, relation, limit, offset, since, until)
    # end
end

function get_directmsg_contacts_1(
        est::DB.CacheStorage; 
        user_pubkey, relation::Union{String,Symbol}=:any,
        limit=10000, offset=0, since=0, until=trunc(Int, time()),
    )
    limit = min(10000, limit)
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)
    relation = cast(relation, Symbol)

    fs = Set(follows(est, user_pubkey))

    d = Dict{Nostr.PubKeyId, Dict{Symbol, Any}}()
    for (peer, cnt, latest_at, latest_event_id) in 
        vcat(DB.exe(est.pubkey_directmsgs_cnt,
                    DB.@sql("select sender, cnt, latest_at, latest_event_id
                            from pubkey_directmsgs_cnt
                            where receiver = ?1 and sender is not null and latest_at >= ?2 and latest_at <= ?3
                            order by latest_at desc limit ?4"), user_pubkey, since, until, 300),
             DB.exe(est.pubkey_directmsgs_cnt,
                    DB.@sql("select receiver, 0, latest_at, latest_event_id
                            from pubkey_directmsgs_cnt
                            where sender = ?1 and latest_at >= ?2 and latest_at <= ?3
                            order by latest_at desc limit ?4"), user_pubkey, since, until, 300))

        peer = Nostr.PubKeyId(peer)
        
        is_hidden(est, user_pubkey, :content, peer) && continue

        if relation != :any
            if     relation == :follows; peer in fs || continue
            elseif relation == :other;   peer in fs && continue
            else; error("invalid relation")
            end
        end
        
        latest_event_id = Nostr.EventId(latest_event_id)
        if !haskey(d, peer)
            d[peer] = Dict([:cnt=>cnt, :latest_at=>latest_at, :latest_event_id=>latest_event_id])
        end
        if d[peer][:latest_at] < latest_at
            d[peer][:latest_at] = latest_at
            d[peer][:latest_event_id] = latest_event_id
        end
        if d[peer][:cnt] < cnt
            d[peer][:cnt] = cnt
        end
    end

    d = sort(collect(d); by=x->-x[2][:latest_at])[offset+1:min(length(d), offset+limit)]

    evts = []
    mds = []
    mdextra = []
    for (peer, p) in d
        if p[:latest_event_id] in est.events
            push!(evts, est.events[p[:latest_event_id]])
        end
        if peer in est.meta_data
            mdeid = est.meta_data[peer]
            if mdeid in est.events
                md = est.events[mdeid]
                push!(mds, md)
                union!(mdextra, ext_event_response(est, md))
            end
        end
    end

    append!(evts, primal_verified_names(est, map(first, d)))

    d = [Nostr.hex(peer)=>p for (peer, p) in d]

    [(; kind=Int(DIRECTMSG_COUNTS), content=JSON.json(Dict(d))), 
     evts..., mds..., mdextra..., 
     range(d, :latest_at; by=x->x[2][:latest_at])...]
end

function get_directmsg_contacts_2(
        est::DB.CacheStorage; 
        user_pubkey, relation::Union{String,Symbol}=:any,
        limit=300, offset=0, since=0, until=trunc(Int, time()),
    )
    limit = min(300, limit)
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)
    relation = cast(relation, Symbol)

    fs = Set(follows(est, user_pubkey))
    d = Dict{Nostr.PubKeyId, Dict{Symbol, Any}}()
    function accept_result(r)
        for (latest_event_id, latest_at, peer, cnt) in [r]
            peer = Nostr.PubKeyId(peer)
            
            is_hidden(est, user_pubkey, :content, peer) && continue
            (is_user_blocked(peer, :csam) || is_user_blocked(peer, :impersonation)) && continue

            if relation != :any
                if     relation == :follows; peer in fs || continue
                elseif relation == :other;   peer in fs && continue
                else; error("invalid relation")
                end
            end
            
            latest_event_id = Nostr.EventId(latest_event_id)
            if !haskey(d, peer)
                d[peer] = Dict([:cnt=>cnt, :latest_at=>latest_at, :latest_event_id=>latest_event_id])
            end
            if d[peer][:latest_at] < latest_at
                d[peer][:latest_at] = latest_at
                d[peer][:latest_event_id] = latest_event_id
            end
            if d[peer][:cnt] < cnt
                d[peer][:cnt] = cnt
            end
        end

        length(d) < limit+offset ? true : :done
    end

    Postgres.transaction(DAG_OUTPUTS_DB[]) do session
        fetch_results(session, since, until, 10000, offset; timeout=5.0,
                      sql_generator=function (s, u, rs_)
                          ("select latest_event_id, latest_at, sender, cnt 
                           from pubkey_directmsgs_cnt
                           where receiver = \$1 and sender is not null and latest_at >= \$2 and latest_at <= \$3
                           order by latest_at desc", 
                           (user_pubkey, s, u))
                      end,
                      accept_result)
        fetch_results(session, since, until, 10000, offset; timeout=5.0,
                      sql_generator=function (s, u, rs_)
                          ("select latest_event_id, latest_at, receiver, 0 
                           from pubkey_directmsgs_cnt
                           where sender = \$1 and latest_at >= \$2 and latest_at <= \$3
                           order by latest_at desc", 
                           (user_pubkey, since, until))
                      end,
                      accept_result)
    end

    d = sort(collect(d); by=x->-x[2][:latest_at])[offset+1:min(length(d), offset+limit)]

    evts = []
    mds = []
    mdextra = []
    for (peer, p) in d
        if p[:latest_event_id] in est.events
            push!(evts, est.events[p[:latest_event_id]])
        end
        if peer in est.meta_data
            mdeid = est.meta_data[peer]
            if mdeid in est.events
                md = est.events[mdeid]
                push!(mds, md)
                union!(mdextra, ext_event_response(est, md))
            end
        end
    end

    append!(evts, primal_verified_names(est, map(first, d)))

    d = [Nostr.hex(peer)=>p for (peer, p) in d]

    [(; kind=Int(DIRECTMSG_COUNTS), content=JSON.json(Dict(d))), 
     evts..., mds..., mdextra..., 
     range(d, :latest_at; by=x->x[2][:latest_at])...]
end

reset_directmsg_count_lock = ReentrantLock()

function reset_directmsg_count(est::DB.CacheStorage; event_from_user::Dict, sender, replicated=false)
    replicated || replicate_request(:reset_directmsg_count; event_from_user, sender)
    est.readonly[] && return []

    e = parse_event_from_user(event_from_user)

    receiver = e.pubkey
    sender = cast(sender, Nostr.PubKeyId)

    cond = "receiver = ?1 and (case when ?2::bytea is null then sender is null else sender = ?2 end)"

    lock(reset_directmsg_count_lock) do
        r = DB.exe(est.pubkey_directmsgs_cnt,
                   "select cnt from pubkey_directmsgs_cnt where $cond",
                   receiver, sender)
        if !isempty(r)
            for s in [sender, nothing]
                DB.exe(est.pubkey_directmsgs_cnt,
                       "update pubkey_directmsgs_cnt 
                       set cnt = greatest(0, cnt - ?3)
                       where $cond",
                       receiver, s, r[1][1])
            end
        end
    end
    []
end

function reset_directmsg_counts(est::DB.CacheStorage; event_from_user::Dict, replicated=false)
    replicated || replicate_request(:reset_directmsg_counts; event_from_user)
    est.readonly[] && return []

    e = parse_event_from_user(event_from_user)

    receiver = e.pubkey

    lock(reset_directmsg_count_lock) do
        DB.exe(est.pubkey_directmsgs_cnt,
               DB.@sql("update pubkey_directmsgs_cnt 
                       set cnt = 0
                       where receiver = ?1"),
               receiver)
    end
    []
end

function get_directmsgs(
        est::DB.CacheStorage; 
        receiver, sender, 
        since::Int=0, until::Int=trunc(Int, time()), limit::Int=20, offset::Int=0
    )
    isnothing(sender) && return [] # FIXME

    receiver = cast(receiver, Nostr.PubKeyId)
    sender = cast(sender, Nostr.PubKeyId)

    msgs = []
    res = []
    for (eid, created_at) in DB.exe(est.pubkey_directmsgs,
                                    DB.@sql("select event_id, created_at from pubkey_directmsgs where 
                                            ((receiver = ?1 and sender = ?2) or (receiver = ?2 and sender = ?1)) and
                                            created_at >= ?3 and created_at <= ?4 
                                            order by created_at desc limit ?5 offset ?6"),
                                    receiver, sender, since, until, limit, offset)
        e = est.events[Nostr.EventId(eid)]
        push!(res, e)
        push!(msgs, (e, created_at))
    end

    res_meta_data = Dict()
    for pk in [receiver, sender]
        if !haskey(res_meta_data, pk) && pk in est.meta_data
            mdid = est.meta_data[pk]
            if mdid in est.events
                res_meta_data[pk] = est.events[mdid]
            end
        end
    end

    res_meta_data = collect(values(res_meta_data))
    append!(res, res_meta_data)
    ext_user_infos(est, res, res_meta_data)
    append!(res, primal_verified_names(est, [sender, receiver]))

    [res..., range(msgs, :created_at)...]
end

function response_messages_for_list(est::DB.CacheStorage, tables, pubkey, extended_response=true)
    pubkey = cast(pubkey, Nostr.PubKeyId)

    res = []
    push_event(eid) = eid in est.events && push!(res, est.events[eid])
    for tbl in tables
        pubkey in tbl && push_event(tbl[pubkey])
    end

    if extended_response
        res_meta_data = Dict{Nostr.PubKeyId, Any}()
        for e in res
            for tag in e.tags
                if length(tag.fields) == 2 && tag.fields[1] == "p"
                    if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                        if !haskey(res_meta_data, pk) && pk in est.meta_data
                            mdid = est.meta_data[pk]
                            if mdid in est.events
                                res_meta_data[pk] = est.events[mdid]
                            end
                        end
                    end
                end
            end
        end
        pks = collect(keys(res_meta_data))
        res_meta_data = collect(values(res_meta_data))
        append!(res, res_meta_data)
        append!(res, user_scores(est, res_meta_data))
        ext_user_infos(est, res, res_meta_data)
        append!(res, primal_verified_names(est, pks))
    end

    res
end

function mutelist(est::DB.CacheStorage; pubkey, extended_response=true)
    response_messages_for_list(est, [est.mute_list, est.mute_list_2], pubkey, extended_response)
end
function mutelists(est::DB.CacheStorage; pubkey, extended_response=true)
    response_messages_for_list(est, [est.mute_lists], pubkey, extended_response)
end
function allowlist(est::DB.CacheStorage; pubkey, extended_response=true)
    response_messages_for_list(est, [est.allow_list], pubkey, extended_response)
end

function parametrized_replaceable_events_extended_response(est::DB.CacheStorage, eids::Vector{Nostr.EventId})
    res = []
    res_meta_data = Dict{Nostr.PubKeyId, Nostr.Event}()
    for eid in eids
        eid in est.events || continue
        e = est.events[eid]
        for tag in e.tags
            if length(tag.fields) == 2 && tag.fields[1] == "p"
                if !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                    if !haskey(res_meta_data, pk) && pk in est.meta_data
                        mdid = est.meta_data[pk]
                        if mdid in est.events
                            res_meta_data[pk] = est.events[mdid]
                        end
                    end
                end
            end
        end
    end
    pks = collect(keys(res_meta_data))
    res_meta_data = collect(values(res_meta_data))
    append!(res, res_meta_data)
    append!(res, user_scores(est, res_meta_data))
    ext_user_infos(est, res, res_meta_data)
    append!(res, primal_verified_names(est, pks))
    res
end

function parameterized_replaceable_list(est::DB.CacheStorage; pubkey, identifier::String, extended_response=true)
    pubkey = cast(pubkey, Nostr.PubKeyId)

    eids = [Nostr.EventId(eid) for (eid,) in DB.exe(est.parameterized_replaceable_list, 
                                                    DB.@sql("select event_id from parameterized_replaceable_list where pubkey = ?1 and identifier = ?2"), 
                                                    pubkey, identifier)]

    res = Any[est.events[eid] for eid in eids]
    extended_response && append!(res, parametrized_replaceable_events_extended_response(est, eids))
    res
end

function parametrized_replaceable_event(est::DB.CacheStorage; pubkey, kind::Int, identifier::String, extended_response=true, user_pubkey=nothing)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    eids = [Nostr.EventId(eid) 
            for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events], 
                                  DB.@sql("select event_id from parametrized_replaceable_events 
                                          where pubkey = ?1 and kind = ?2 and identifier = ?3"), 
                                  (pubkey, kind, identifier))]
    res = OrderedSet{Any}([est.events[eid] for eid in eids])
    if extended_response
        union!(res, parametrized_replaceable_events_extended_response(est, eids))
        union!(res, response_messages_for_posts(est, eids; user_pubkey))
    end
    collect(res)
end

function parametrized_replaceable_events(est::DB.CacheStorage; events::Vector, extended_response=true)
    res = []
    for r in events
        append!(res, parametrized_replaceable_event(est; pubkey=r["pubkey"], kind=r["kind"], identifier=r["identifier"], extended_response))
    end
    res
end

function replaceable_event(est::DB.CacheStorage; pubkey, kind::Int)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    res = []
    for (eid,) in Postgres.execute(:p0, "select event_id from replaceable_events where pubkey = \$1 and kind = \$2", [pubkey, kind])[2]
        eid = Nostr.EventId(eid) 
        eid in est.events && push!(res, est.events[eid])
    end
    res
end

function search_filterlist(est::DB.CacheStorage; pubkey, user_pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)
    cmr = compile_content_moderation_rules(est, user_pubkey)
    res = nothing
    if pubkey in cmr.pubkeys_allowed
        res = (; action=:allow, pubkey=user_pubkey)
        [est.events[est.meta_data[user_pubkey]], 
         (; kind=Int(FILTERING_REASON), content=JSON.json(res))]
    elseif haskey(cmr.pubkeys, pubkey)
        res = (; action=:block, pubkey=cmr.pubkeys[pubkey].parent)
        [est.events[est.meta_data[res.pubkey]], 
         (; kind=Int(FILTERING_REASON), content=JSON.json(res))]
    else
        for (grpname, g) in cmr.groups
            if grpname == :primal_spam && pubkey in Filterlist.access_pubkey_blocked_spam
                res = (; action=:block, group=grpname)
                break
            elseif grpname == :primal_nsfw && any([is_hidden_on_primal_nsfw(est, user_pubkey, scope, pubkey) for scope in [:content, :trending]])
                res = (; action=:block, group=grpname)
                break
            end
        end
    end
    isnothing(res) ? [] : [ (; kind=Int(FILTERING_REASON), content=JSON.json(res))]
end

IMPORT_EVENTS_SERVER = Ref{Any}(nothing)

function import_events(est::DB.CacheStorage; events::Vector=[], replicated=false)
    replicated || replicate_request(:import_events; events)
    est.readonly[] && return []
    isnothing(IMPORT_EVENTS_SERVER[]) && return []

    cnt = Ref(0)
    errcnt = Ref(0)
    for e in events
        e = Nostr.Event(e)
        try
            DB.add_human_override(est, e.pubkey, true, "import_events")
            cnt[] += Main.rex(IMPORT_EVENTS_SERVER[]..., :(let e = $e
                                                               msg = JSON.json([time(), nothing, ["EVENT", "", e]])
                                                               est = Main.cache_storage
                                                               cnt = 0
                                                               if DB.import_msg_into_storage(msg, est)
                                                                   cnt += 1
                                                               end
                                                               try
                                                                   o = Main.App.DAG_OUTPUTS[][2]
                                                                   Main.DAG.import_basic_tags(Main.App.DAG_OUTPUTS_DB[], o.events, o.basic_tags, e.created_at, e.created_at)
                                                                   Main.DAG.import_event_mentions(est, o.event_mentions, e)
                                                               catch ex
                                                                   println("import_events: import_event_mentions error: $ex")
                                                               end
                                                               Main.App.ext_import_event(est, e)
                                                               cnt
                                                           end
                                                          ))
        catch ex
            println("import_events: error: $ex")
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            errcnt[] += 1
        end
    end
    [(; kind=Int(EVENT_IMPORT_STATUS), content=JSON.json((; imported=cnt[], errors=errcnt[])))]
end

function response_messages_for_zaps(est, zaps; kinds=nothing, order_by=:created_at, user_pubkey=nothing)
    res_meta_data = Dict()
    res = []
    for (zap_receipt_id, created_at, event_id, sender, receiver, amount_sats) in zaps
        # if user_pubkey == Main.test_pubkeys[:qa]
        #     e = est.events[Nostr.EventId(zap_receipt_id)]
        #     println([JSON.parse(t.fields[2])["pubkey"] for t in e.tags if t.fields[1] == "description"])
        # end
        hidden = false
        try
            sender = Nostr.PubKeyId(sender)
            receiver = Nostr.PubKeyId(receiver)
            hidden |= !isnothing(user_pubkey) && is_hidden(est, user_pubkey, :content, sender)
            hidden |= is_hidden(est, receiver, :content, sender)
        catch _
            Utils.print_exceptions()
        end
        hidden && continue

        for pk in [sender, receiver]
            if !haskey(res_meta_data, pk) && pk in est.meta_data
                mdid = est.meta_data[pk]
                if mdid in est.events
                    res_meta_data[pk] = est.events[mdid]
                end
            end
        end

        zap_receipt_id = Nostr.EventId(zap_receipt_id)
        zap_receipt_id in est.events && push!(res, est.events[zap_receipt_id])
        if !ismissing(event_id)
            event_id = Nostr.EventId(event_id)
            event_id in est.events && push!(res, est.events[event_id])
        end

        push!(res, (; kind=Int(ZAP_EVENT), content=JSON.json((; 
                                                              event_id, 
                                                              created_at, 
                                                              sender=castmaybe(sender, Nostr.PubKeyId),
                                                              receiver=castmaybe(receiver, Nostr.PubKeyId),
                                                              amount_sats,
                                                              zap_receipt_id))))
    end

    res_meta_data = collect(values(res_meta_data))
    append!(res, res_meta_data)
    append!(res, user_scores(est, res_meta_data))
    append!(res, primal_verified_names(est, [e.pubkey for e in res_meta_data]))
    ext_user_infos(est, res, res_meta_data)

    res_ = []
    by = if order_by == :created_at; r->r[2]
    elseif order_by == :amount_sats; r->r[6]
    else; error("invalid order_by")
    end
    for e in [collect(OrderedSet(res)); range(zaps, order_by; by)]
        if isnothing(kinds) || (hasproperty(e, :kind) && getproperty(e, :kind) in kinds)
            push!(res_, e)
        end
    end
    res_
end

function zaps_feed(
        est::DB.CacheStorage;
        pubkeys,
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        kinds=nothing,
        time_exceeded=()->false,
    )
    limit=min(50, limit)
    limit <= 1000 || error("limit too big")
    pubkeys = [cast(pubkey, Nostr.PubKeyId) for pubkey in pubkeys]

    # pks = collect(union(pubkeys, [follows(est, pubkey) for pubkey in pubkeys]...))
    pks = pubkeys

    zaps = [] |> ThreadSafe
    @threads for p in pks
    # for p in pks
        time_exceeded() && break
        append!(zaps, map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts 
                                                                   where (sender = ?1 or receiver = ?2) and created_at >= ?3 and created_at <= ?4
                                                                   order by created_at desc limit ?5 offset ?6"),
                                         (p, p, since, until, limit, offset))))
    end

    zaps = sort(zaps.wrapped, by=z->-z[2])[1:min(limit, length(zaps))]

    response_messages_for_zaps(est, zaps; kinds)
end

function user_zaps(
        est::DB.CacheStorage;
        sender=nothing, receiver=nothing,
        kinds=nothing,
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
    )
    limit = min(50, limit)
    limit <= 1000 || error("limit too big")
    sender = castmaybe(sender, Nostr.PubKeyId)
    receiver = castmaybe(receiver, Nostr.PubKeyId)

    zaps = if !isnothing(sender)
        map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts 
                                                     where sender = ?1 and created_at >= ?2 and created_at <= ?3
                                                     order by created_at desc limit ?4 offset ?5"),
                           (sender, since, until, limit, offset)))
    elseif !isnothing(receiver)
        map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts 
                                                     where receiver = ?1 and created_at >= ?2 and created_at <= ?3
                                                     order by created_at desc limit ?4 offset ?5"),
                           (receiver, since, until, limit, offset)))
    else
        error("either sender or receiver argument has to be specified")
    end

    zaps = sort(zaps, by=z->-z[2])[1:min(limit, length(zaps))]

    response_messages_for_zaps(est, zaps; kinds)
end

function user_zaps_by_satszapped(
        est::DB.CacheStorage;
        receiver=nothing,
        limit::Int=20, since::Int=0, until=nothing, offset::Int=0,
    )
    limit <= 1000 || error("limit too big")
    receiver = cast(receiver, Nostr.PubKeyId)

    isnothing(until) && (until = 100_000_000_000)
    zaps = map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts 
                                                        where receiver = ?1 and amount_sats >= ?2 and amount_sats <= ?3
                                                        order by amount_sats desc limit ?4 offset ?5"),
                              (receiver, since, until, limit, offset)))

    zaps = sort(zaps, by=z->-z[6])[1:min(limit, length(zaps))]

    response_messages_for_zaps(est, zaps; order_by=:amount_sats)
end

function user_zaps_sent(
        est::DB.CacheStorage;
        sender,
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
    )
    limit <= 1000 || error("limit too big")
    sender = cast(sender, Nostr.PubKeyId)

    zaps = map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts 
                                                        where sender = ?1 and created_at >= ?2 and created_at <= ?3
                                                        order by created_at desc limit ?4 offset ?5"),
                              (sender, since, until, limit, offset)))

    zaps = sort(zaps, by=z->-z[2])[1:min(limit, length(zaps))]

    response_messages_for_zaps(est, zaps; order_by=:created_at)
end

function event_zaps_by_satszapped(
        est::DB.CacheStorage;
        event_id=nothing,
        pubkey=nothing, identifier=nothing,
        limit::Int=20, since::Int=0, until=nothing, offset::Int=0,
        user_pubkey=nothing,
    )
    limit <= 1000 || error("limit too big")
    event_id = castmaybe(event_id, Nostr.EventId)
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    isnothing(until) && (until = 100_000_000_000)

    r = if !isnothing(event_id)
        DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts 
                                          where event_id = ?1 and amount_sats >= ?2 and amount_sats <= ?3
                                          order by amount_sats desc limit ?4 offset ?5"),
                (event_id, since, until, limit, offset))

    elseif !isnothing(pubkey) && !isnothing(identifier) 
        Postgres.pex(DAG_OUTPUTS_DB[], pgparams() do P "
                      SELECT
                          zap_receipts.eid        as zap_receipt_id,
                          zap_receipts.created_at as created_at,
                          zap_receipts.target_eid as event_id,
                          zap_receipts.sender     as sender,
                          zap_receipts.receiver   as receiver,
                          zap_receipts.satszapped as amount_sats 
                      FROM
                          reads_versions,
                          zap_receipts
                      WHERE 
                          reads_versions.pubkey = $(@P pubkey) AND 
                          reads_versions.identifier = $(@P identifier) AND 
                          reads_versions.eid = zap_receipts.target_eid AND 
                          zap_receipts.satszapped >= $(@P since) AND 
                          zap_receipts.satszapped <= $(@P until)
                      ORDER BY
                          zap_receipts.satszapped DESC
                      LIMIT $(@P limit) OFFSET $(@P offset)
                  " end...)
    else
        []
    end

    zaps = map(Tuple, r)
    zaps = first(sort(zaps, by=z->-z[6]), limit)

    response_messages_for_zaps(est, zaps; order_by=:amount_sats, user_pubkey)
end

server_index() = Int(Sockets.getipaddr().host >> 8 & 0xff)-10
function server_name(est::DB.CacheStorage)
    [(; content=JSON.json((; server=server_index(), node=Main.NODEIDX)))]
end

REPLICATE_TO_SERVERS = []

function replicate_request(reqname::Union{String, Symbol}; kwargs...)
    msg = JSON.json(["REQ", "replicated_request", (; cache=[reqname, (; kwargs..., replicated=true)])])
    for (addr, port) in REPLICATE_TO_SERVERS
        errormonitor(@async HTTP.WebSockets.open("ws://$addr:$port"; connect_timeout=2, readtimeout=2) do ws
            HTTP.WebSockets.send(ws, msg)
            # println("replicated: ", msg)
        end)
    end
end

function nostr_stats(est::DB.CacheStorage)
    res = [r[1:4] for r in DB.dyn_select(est, :daily_stats, :active_humans)]
    [(; kind=Int(NOSTR_STATS), content=JSON.json(res))]
end

function is_hidden_by_content_moderation(est::DB.CacheStorage; user_pubkey=nothing, scope=:content, pubkeys=[], event_ids=[])
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    scope = cast(scope, Symbol)
    pubkeys = [cast(pk, Nostr.PubKeyId) for pk in pubkeys]
    event_ids = [cast(eid, Nostr.EventId) for eid in event_ids]
    res = (; 
           pubkeys=Dict([Nostr.hex(pk)=>is_hidden(est, user_pubkey, scope, pk) for pk in pubkeys]),
           event_ids=Dict([Nostr.hex(eid)=>is_hidden(est, user_pubkey, scope, eid) for eid in event_ids]))
    [(; kind=Int(IS_HIDDEN_BY_CONTENT_MODERATION), content=JSON.json(res))]
end

function user_of_ln_address(est::DB.CacheStorage; ln_address::String)
    if !isempty(local r = DB.exec(est.dyn[:pubkey_ln_address], 
                                  DB.@sql("select pubkey from pubkey_ln_address where ln_address = ?1"), 
                                  (ln_address,)))
        pubkey = Nostr.PubKeyId(r[1][1])
        [(; kind=Int(USER_PUBKEY), content=JSON.json((; pubkey))), user_infos(est; pubkeys=[pubkey])...]
    else
        []
    end
end

function get_user_relays(est::DB.CacheStorage; pubkey)
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    res = []
    relays = Set()
    if haskey(est.dyn[:relay_list_metadata], pubkey)
        eid = est.dyn[:relay_list_metadata][pubkey]
        if haskey(est.events, eid)
            e = est.events[eid]
            # push!(res, e)
            for t in e.tags
                if length(t.fields) >= 2 && t.fields[1] == "r"
                    push!(relays, ["r", t.fields[2:end]...])
                end
            end
        end
    end
    if isempty(relays) && haskey(est.contact_lists, pubkey)
        eid = est.contact_lists[pubkey]
        if haskey(est.events, eid)
            e = est.events[eid]
            # push!(res, e)
            d = try JSON.parse(e.content) catch _ Dict() end
            for (url, dd) in d
                for (k, v) in dd
                    v && !isempty(url) && push!(relays, ["r", url, k])
                end
            end
        end
    end
    push!(res, (; kind=Int(USER_RELAYS), pubkey, tags=sort(collect(relays))))
    res
end

function get_user_relays_2(est::DB.CacheStorage; pubkeys)
    res = []
    for pk in pubkeys
        append!(res, get_user_relays(est; pubkey=pk))
    end
    res
end

function get_bookmarks(est::DB.CacheStorage; pubkey)
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    res = []
    if haskey(est.dyn[:bookmarks], pubkey)
        eid = est.dyn[:bookmarks][pubkey]
        if haskey(est.events, eid)
            e = est.events[eid]
            push!(res, e)
        end
    end
    res
end

event_from_row(r) = Nostr.Event(r[1], r[2], r[3], r[4], [Nostr.TagAny(t) for t in r[5]], ismissing(r[6]) ? "" : r[6], r[7])

function highlights(
        est::DB.CacheStorage;
        event_id=nothing,
        pubkey=nothing, identifier=nothing, kind=nothing,
        user_pubkey=nothing,
    )
    event_id = castmaybe(event_id, Nostr.EventId)
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    evts = if !isnothing(event_id)
        map(event_from_row, Postgres.pex(DAG_OUTPUTS_DB[], pgparams() do P "
                             SELECT
                                 events.*
                             FROM
                                 basic_tags,
                                 events
                             WHERE 
                                 (basic_tags.kind = 1 OR basic_tags.kind = 9802) AND
                                 basic_tags.tag = 'e' AND
                                 basic_tags.arg1 = $(@P event_id) AND
                                 basic_tags.id = events.id
                             ORDER BY
                                 basic_tags.created_at DESC
                         " end...))

    elseif !isnothing(kind) && !isnothing(pubkey) && !isnothing(identifier) 
        map(event_from_row, Postgres.pex(DAG_OUTPUTS_DB[], pgparams() do P "
                             SELECT
                                 events.*
                             FROM
                                 a_tags,
                                 events
                             WHERE 
                                 a_tags.ref_pubkey = $(@P pubkey) AND 
                                 a_tags.ref_identifier = $(@P identifier) AND 
                                 a_tags.ref_kind = $(@P kind) AND 
                                 (a_tags.kind = 1 OR a_tags.kind = 9802) AND 
                                 a_tags.eid = events.id
                             ORDER BY
                                 a_tags.created_at DESC
                         " end...))
    else
        []
    end

    [e for e in evts
     if !(is_hidden(est, user_pubkey, :content, e.id) || 
          ext_is_hidden(est, e.id) || 
          e.id in est.deleted_events)]
end

function get_highlights(
        est::DB.CacheStorage;
        event_id=nothing,
        pubkey=nothing, identifier=nothing, kind=nothing,
        user_pubkey=nothing,
    )
    isnothing(event_id) || error("event_id not supported yet")

    event_id = castmaybe(event_id, Nostr.EventId)
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    evts = highlights(est; event_id, pubkey, identifier, kind, user_pubkey)

    hs = Dict{Nostr.EventId, Nostr.Event}() # highlight eid -> highlight event
    for e in evts
        if e.kind == 9802
            hs[e.id] = e
        end
    end

    highlight_groups = Dict{String, Vector{Nostr.EventId}}()
    for e in evts
        if e.kind == Int(Nostr.TEXT_NOTE)
            for t in e.tags
                if length(t.fields) >= 2 && t.fields[1] == "q" && !isnothing(local qid = try Nostr.EventId(t.fields[2]) catch _ end)
                    if haskey(hs, qid)
                        push!(get!(highlight_groups, hs[qid].content) do; Nostr.EventId[]; end,
                              e.id)
                    end
                end
            end
        end
    end

    res = []
    res_meta_data = Dict()
    for e in values(hs)
        push!(res, e)
        pk = e.pubkey
        if !haskey(res_meta_data, pk) && pk in est.meta_data
            res_meta_data[pk] = est.events[est.meta_data[pk]]
        end
    end

    append!(res, collect(values(res_meta_data)))

    append!(res, [(; kind=Int(HIGHLIGHT_GROUPS), content=JSON.json(highlight_groups))])

    for eid in keys(hs)
        append!(res, [e for e in thread_view_replies(est; event_id=eid, limit=100) if e.kind != RANGE])
    end

    res
end

function long_form_content_feed(
        est::DB.CacheStorage;
        pubkey=nothing, notes::Union{Symbol,String}=:follows,
        topic=nothing,
        curation=nothing,
        minwords=0,
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing,
        time_exceeded=()->false,
        usepgfuncs=false,
        apply_humaness_check=false,
    )
    # error("obsolete implementation")

    limit <= 1000 || error("limit too big")
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    notes = Symbol(notes)

    if usepgfuncs
        q = "select distinct e from long_form_content_feed(\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11) f(e) where e is not null"
        res = [r[1] for r in Postgres.pex(DAG_OUTPUTS_DB[], q, 
                                           [pubkey, notes, topic, curation, minwords, limit, since, until, offset, user_pubkey, apply_humaness_check])]
        return res
    end

    topic_where(P) = isnothing(topic) ? "" : "and topics @@ plainto_tsquery('simple', $(@P replace(topic, ' '=>'-')))"

    posts = [] |> ThreadSafe
    if !isnothing(curation) && !isnothing(pubkey)
        for r in Postgres.pex(DAG_OUTPUTS_DB[], 
                              pgparams() do P "
                                  select 
                                      distinct reads.latest_eid, reads.published_at
                                  from 
                                      parametrized_replaceable_events pre,
                                      a_tags at,
                                      reads
                                  where 
                                      pre.pubkey = $(@P pubkey) and pre.identifier = $(@P curation) and pre.kind = 30004 and
                                      pre.event_id = at.eid and 
                                      at.ref_kind = 30023 and at.ref_pubkey = reads.pubkey and at.ref_identifier = reads.identifier and
                                      reads.published_at >= $(@P since) and reads.published_at <= $(@P until) and
                                      reads.words >= $(@P minwords)
                                  order by reads.published_at desc limit $(@P limit) offset $(@P offset)
                              " end...)
            push!(posts, r)
        end
    elseif pubkey isa Nothing
        for r in Postgres.pex(DAG_OUTPUTS_DB[], 
                              pgparams() do P "
                                  select distinct latest_eid, published_at
                                  from reads
                                  where 
                                      published_at >= $(@P since) and published_at <= $(@P until) and
                                      words >= $(@P minwords)
                                      $(topic_where(P))
                                  order by published_at desc limit $(@P limit) offset $(@P offset)
                              " end...)
            push!(posts, r)
        end
    elseif notes == :zappedbyfollows
        for r in Postgres.execute(DAG_OUTPUTS_DB[],
                                  pgparams() do P "
                                      select distinct rs.latest_eid, rs.published_at
                                      from pubkey_followers pf, reads rs, reads_versions rv, zap_receipts zr
                                      where 
                                          pf.follower_pubkey = $(@P pubkey) and 
                                          pf.pubkey = zr.sender and zr.target_eid = rv.eid and
                                          rv.pubkey = rs.pubkey and rv.identifier = rs.identifier and
                                          rs.published_at >= $(@P since) and rs.published_at <= $(@P until) and
                                          rs.words >= $(@P minwords)
                                      order by rs.published_at desc limit $(@P limit) offset $(@P offset)
                                  " end...)[2]
            push!(posts, r)
        end
    else
        Postgres.transaction(DAG_OUTPUTS_DB[]) do session
            qargs = if notes == :follows && !isempty(Postgres.pex(DAG_OUTPUTS_DB[], "select 1 from pubkey_followers pf where pf.follower_pubkey = ?1 limit 1", (pubkey,)))
                pgparams() do P "
                    select distinct reads.latest_eid, reads.published_at
                    from reads, pubkey_followers pf
                    where 
                        pf.follower_pubkey = $(@P pubkey) and pf.pubkey = reads.pubkey and 
                        reads.published_at >= $(@P since) and reads.published_at <= $(@P until) and
                        reads.words >= $(@P minwords)
                        $(topic_where(P))
                    order by published_at desc limit $(@P limit) offset $(@P offset)
                " end
            elseif notes == :authored
                pgparams() do P "
                    select distinct reads.latest_eid, reads.published_at
                    from reads
                    where 
                        reads.pubkey = $(@P pubkey) and 
                        reads.published_at >= $(@P since) and reads.published_at <= $(@P until) and
                        reads.words >= $(@P minwords)
                        $(topic_where(P))
                    order by published_at desc limit $(@P limit) offset $(@P offset)
                " end
            else
                error("unsupported type of notes")
            end

            for r in Postgres.execute(session, qargs...)[2]
                push!(posts, r)
            end
        end
    end

    posts = first(sort(posts.wrapped, by=p->-p[2]), limit)

    eids = [Nostr.EventId(eid) for (eid, _) in posts]

    res = if Main.CacheServerHandlers.ENABLE_SPI[]
        AppSPI.enrich_feed_events(est; event_ids=eids, user_pubkey)
    else
        response_messages_for_posts(est, eids; user_pubkey, time_exceeded)
    end

    append!(res, parametrized_replaceable_events_extended_response(est, eids))

    vcat(res, range(posts, :created_at))
end

function long_form_content_replies(
        est::DB.CacheStorage;
        pubkey::Nostr.PubKeyId, identifier::String, 
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing,
    )
    limit <= 1000 || error("limit too big")

    posts = Tuple{Nostr.EventId, Int}[]
    for (reid, created_at) in 
        Postgres.pex(DAG_OUTPUTS_DB[], pgparams() do P "
                         WITH a AS (
                             SELECT
                                 event_replies.reply_event_id,
                                 event_replies.reply_created_at AS created_at
                             FROM
                                 reads_versions,
                                 event_replies
                             WHERE 
                                 reads_versions.pubkey = $(@P pubkey) AND 
                                 reads_versions.identifier = $(@P identifier) AND 
                                 reads_versions.eid = event_replies.event_id AND 
                                 event_replies.reply_created_at >= $(@P since) AND 
                                 event_replies.reply_created_at <= $(@P until)
                         ), b AS (
                             SELECT
                                 a_tags.eid,
                                 a_tags.created_at
                             FROM
                                 a_tags
                             WHERE 
                                 a_tags.kind = $(@P Int(Nostr.TEXT_NOTE)) AND 
                                 a_tags.ref_kind = $(@P Int(Nostr.LONG_FORM_CONTENT)) AND 
                                 a_tags.ref_pubkey = $(@P pubkey) AND 
                                 a_tags.ref_identifier = $(@P identifier) AND 
                                 a_tags.created_at >= $(@P since) AND 
                                 a_tags.created_at <= $(@P until)
                         )
                         (SELECT * FROM a) UNION (SELECT * FROM b)
                         ORDER BY
                             created_at DESC
                         LIMIT $(@P limit) OFFSET $(@P offset)
                     " end...)
        reid = Nostr.EventId(reid)
        if reid in est.events
            e = est.events[reid]
            if !any(true for t in e.tags if (t.fields[1] == "e" || t.fields[1] == "a") && (length(t.fields) < 4 || t.fields[4] != "root"))
                push!(posts, (reid, created_at))
            end
        end
    end
    posts
end

function long_form_content_thread_view(
        est::DB.CacheStorage; 
        pubkey, kind::Int, identifier::String, 
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing,
        usepgfuncs=false, apply_humaness_check=false,
    )
    apply_humaness_check = false

    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    rs = parametrized_replaceable_event(est; pubkey, kind, identifier, extended_response=false)
    isempty(rs) && return []
    event_id = rs[1].id

    res = OrderedSet()

    hidden = is_hidden(est, user_pubkey, :content, event_id) || ext_is_hidden(est, event_id) || event_id in est.deleted_events
    hidden && return []

    e = est.events[event_id]
    push!(res, e)

    union!(res, thread_view_parents(est; event_id, user_pubkey))

    posts = long_form_content_replies(est; 
                    pubkey, identifier, 
                    limit, since, until, offset,
                    user_pubkey)
    
    if usepgfuncs
        union!(res, enrich_feed_events_pg(est; posts=[(e.id, e.created_at); posts], user_pubkey, apply_humaness_check))
    else
        reids = [reid for (reid, _) in [(e.id, e.created_at); posts]]
        union!(res, [response_messages_for_posts(est, reids; user_pubkey); range(posts, :created_at)])
    end

    collect(res)
end

RECOMMENDED_READS_FILE = Ref("recommended-reads.json")

import Random
function get_recommended_reads(est::DB.CacheStorage)
    # return [(; kind=Int(RECOMMENDED_READS), 
    #   content=JSON.json(try JSON.parse(read(RECOMMENDED_READS_FILE[], String))
    #                     catch _; (;) end))]
    
    r = (; reads=[])
    for e in first(Random.shuffle([e isa Dict ? Nostr.Event(e) : e
                                   for e in long_form_content_feed(est; curation="Nostr-Gems-0z9m1e", pubkey="532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb", limit=200) 
                                   if (e isa Dict ? e["kind"] : e.kind) == Int(Nostr.LONG_FORM_CONTENT)]), 3)
        identifier = nothing
        title = ""
        for t in e.tags
            if length(t.fields) >= 2 && t.fields[1] == "d"
                identifier = t.fields[2]
            elseif length(t.fields) >= 2 && t.fields[1] == "title"
                title = t.fields[2]
            end
        end
        if !isnothing(identifier)
            push!(r.reads, [Bech32.nip19_encode_naddr(Int(Nostr.LONG_FORM_CONTENT), e.pubkey, identifier), title])
        end
    end

    [(; kind=Int(RECOMMENDED_READS), content=JSON.json(r))]
end

READS_TOPICS_FILE = Ref("reads-topics.json")

function get_reads_topics(est::DB.CacheStorage)
    [(; kind=Int(READS_TOPICS), 
      content=JSON.json(try JSON.parse(read(READS_TOPICS_FILE[], String))
                        catch _; (;) end))]
end

FEATURED_AUTHORS_FILE = Ref("featured-authors.json")

function get_featured_authors(est::DB.CacheStorage)
    [(; kind=Int(FEATURED_AUTHORS), 
      content=JSON.json(try JSON.parse(read(FEATURED_AUTHORS_FILE[], String))
                        catch _; (;) end))]
end

function creator_paid_tiers(est::DB.CacheStorage; pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)

    res = []

    catch_exception(:creator_paid_tiers, (; pubkey)) do
        event_from_row(r) = Nostr.Event(r[1], r[2], r[3], r[4], [Nostr.TagAny(t) for t in r[5]], ismissing(r[6]) ? "" : r[6], r[7])

        for r in Main.Postgres.pex(DAG_OUTPUTS_DB[], "select * from event where kind = 17000 and pubkey = ?1 order by created_at desc limit 1", (pubkey,))
            e = event_from_row(r)
            push!(res, e)
            for t in e.tags
                if length(t.fields) >= 2 && t.fields[1] == "e"
                    eid = Nostr.EventId(t.fields[2])
                    for r2 in Main.Postgres.pex(DAG_OUTPUTS_DB[], "select * from event where id = ?1 limit 1", (eid,))
                        push!(res, event_from_row(r2))
                    end
                end
            end
        end
    end

    res
end

##
funcall_content_moderation_scope = 
(;
 content=Set([
              :feed,
              :feed_2,
              :thread_view,
              :get_directmsg_contacts,
              :get_directmsgs,

              :zaps_feed,
              :user_zaps,
              :user_zaps_by_satszapped,
              :event_zaps_by_satszapped,

              :get_bookmarks,
              :get_highlights,
              :long_form_content_feed,
              :long_form_content_thread_view,

              :mega_feed_directive,
              # :enrich_feed_events,
              
              :search,
              :advanced_feed,
              :user_profile_scored_content,
              :user_search,
              :feed_directive,
              :feed_directive_2,
             ]),

 trending=Set([
               :explore,
               :explore_global_trending_24h,
               :explore_global_mostzapped_4h,
               :scored,
               :scored_users,
               :scored_users_24h,
              ]))
##

function content_moderation_filtering_2(est::DB.CacheStorage, res::Vector, funcall::Symbol, kwargs) 
    kwargs = Dict(kwargs)
    user_pubkey = castmaybe(get(kwargs, :user_pubkey, nothing), Nostr.PubKeyId)

    if funcall == :get_featured_dvm_feeds || funcall == :advanced_search || funcall == :advanced_feed
        return res
    elseif get(kwargs, :usepgfuncs, false) && funcall in Main.CacheServerHandlers.app_funcalls_with_pgfuncs
        return res
    end

    cmr = compile_content_moderation_rules(est, user_pubkey)

    res2 = []
    for e in res
        ok = true

        eid = pubkey = kind = nothing
        content = ""
        tags = []

        if e isa Dict
            haskey(e, "id") && try eid = Nostr.EventId(e["id"]) catch _ end
            haskey(e, "pubkey") && try pubkey = Nostr.PubKeyId(e["pubkey"]) catch _ end
            haskey(e, "kind") && (kind = e["kind"])
            haskey(e, "content") && (content = e["content"])
            haskey(e, "tags") && (tags = e["tags"])
        else
            hasproperty(e, :id) && (eid = e.id)
            hasproperty(e, :pubkey) && (pubkey = e.pubkey)
            hasproperty(e, :kind) && (kind = e.kind)
            hasproperty(e, :content) && (content = e.content)
            hasproperty(e, :tags) && (tags = hasproperty(e.tags, :fields) ? [t.fields for t in e.tags] : e.tags)
        end

        if !isnothing(eid) && (ext_is_hidden(est, eid) || eid in est.deleted_events)
            ok = false
        elseif !isnothing(pubkey)
            if funcall == :thread_view && !DB.is_trusted_user(est, pubkey)
                ok = false
                continue
            end
            scope = 
            if funcall in funcall_content_moderation_scope.content
                :content
            elseif funcall in funcall_content_moderation_scope.trending
                :trending
            else
                nothing
            end
            if !isnothing(scope)
                ok &= !is_hidden_(est, cmr, user_pubkey, scope, pubkey)
                # !ok && @show (funcall, user_pubkey, scope, pubkey)
            end
        elseif !isnothing(kind)
            if kind == USER_SCORES
                d = Dict()
                for (pk, v) in JSON.parse(content)
                    if !is_hidden_(est, cmr, user_pubkey, :trending, Nostr.PubKeyId(pk))
                        d[pk] = v
                    end
                end
                e = (; kind=Int(USER_SCORES), content=JSON.json(d))

            elseif kind == Int(Nostr.REPOST)
                try
                    hide = false
                    for t in tags
                        if t[1] == "p"
                            pk = Nostr.PubKeyId(t[2])
                            hide |= is_hidden_(est, cmr, user_pubkey, :content, pk) || ext_is_hidden(est, pk) 
                        end
                    end
                    ok &= !hide
                catch _ end

            elseif kind == Int(DIRECTMSG_COUNTS)
                d = [peer=>p for (peer, p) in JSON.parse(content)
                     if !is_hidden_(est, cmr, user_pubkey, :content, Nostr.PubKeyId(peer))]
                e = (; kind=Int(DIRECTMSG_COUNTS), content=JSON.json(Dict(d)))

            elseif kind == Int(ZAP_EVENT)
                d = content isa Dict ? content : JSON.parse(content)
                hidden = false
                try
                    sender = Nostr.PubKeyId(d["sender"])
                    receiver = Nostr.PubKeyId(d["receiver"])
                    hidden |= !isnothing(user_pubkey) && is_hidden_(est, cmr, user_pubkey, :content, sender)
                    hidden |= is_hidden_(est, cmr, receiver, :content, sender)
                catch _ end
                ok &= !hidden

            elseif kind == Int(NOTIFICATION)
                d = JSON.parse(content)
                for (k, v) in d
                    if length(v) == 64
                        try
                            if is_hidden_(est, cmr, user_pubkey, :content, Nostr.PubKeyId(v))
                                ok = false
                                break
                            end
                        catch _ end
                        try
                            if is_hidden_(est, cmr, user_pubkey, :content, Nostr.EventId(v))
                                ok = false
                                break
                            end
                        catch _ end
                    end
                end
            end
        end

        ok && push!(res2, e)
    end

    if funcall == :user_profile
        if !isnothing(user_pubkey) && haskey(kwargs, :pubkey)
            pubkey = Nostr.PubKeyId(kwargs[:pubkey])
            is_hidden_(est, cmr, user_pubkey, :content, pubkey) && append!(res2, search_filterlist(est; pubkey, user_pubkey))
        end
    end

    res2
end

include("app_ext.jl")
include("app_media.jl")

# function ext_user_infos(est::DB.CacheStorage, res, res_meta_data) end
# function ext_user_profile(est::DB.CacheStorage, pubkey); (;); end
# function ext_user_profile_media(est::DB.CacheStorage, pubkey); []; end
# function ext_is_hidden(est::DB.CacheStorage, eid::Nostr.EventId); false; end
# function ext_is_hidden_by_group(est::DB.CacheStorage, user_pubkey, scope::Symbol, pubkey::Nostr.PubKeyId); false; end
# function ext_is_hidden_by_group(est::DB.CacheStorage, user_pubkey, scope::Symbol, eid::Nostr.EventId); false; end
# function ext_event_response(est::DB.CacheStorage, e::Nostr.Event); []; end
# function ext_user_get_settings(est::DB.CacheStorage, pubkey); end
# function ext_invalidate_cached_content_moderation(est::DB.CacheStorage, user_pubkey::Union{Nothing,Nostr.PubKeyId}); end
# function ext_import_event(est::DB.CacheStorage, e::Nostr.Event) end
# function ext_long_form_event_stats(est::DB.CacheStorage, eid::Nostr.EventId); []; end

READS_FEEDS_FILE = Ref("reads-feeds.json")

function get_reads_feeds(est::DB.CacheStorage)
    [(; kind=Int(READS_FEEDS), 
      content=JSON.json(try JSON.parse(read(READS_FEEDS_FILE[], String))
                        catch _; (;) end))]
end

reads_feed_directive(est::DB.CacheStorage; kwargs...) = mega_feed_directive(est; kwargs...)

function mega_feed_directive(
        est::DB.CacheStorage;
        spec::String,
        usepgfuncs=false,
        apply_humaness_check=false,
        kwargs...,
    )
    kwa = Dict{Any, Any}(kwargs)
    s = JSON.parse(spec)
    skwa = [Symbol(k)=>v for (k, v) in s if !(k in ["id", "kind"])]

    # @show (s, kwa)
    
    if haskey(kwargs, :user_pubkey) && est.auto_fetch_missing_events 
        user_pubkey = cast(kwargs[:user_pubkey], Nostr.PubKeyId)
        DB.fetch_user_metadata(est, user_pubkey)
    end

    id = get(s, "id", "")

    if haskey(s, "dvm_pubkey") && haskey(s, "dvm_id")   
        return dvm_feed(est; dvm_pubkey=s["dvm_pubkey"], dvm_id=s["dvm_id"], kwargs...)

    elseif id == "nostr-reads-feed"
        return advanced_search(est; query="kind:30023 scope:myfollowsinteractions minwords:100 features:summary", kwargs...)

    elseif id == "advsearch"
        return advanced_search(est; skwa..., kwargs...)

    # elseif id == "notifications"
    #     return get_notifications(est; skwa..., kwargs...)

    elseif id == "reads-feed" || get(s, "kind", "") == "reads"
        minwords = get(s, "minwords", 100)
        if get(s, "scope", "") == "follows"
            # return long_form_content_feed(est; pubkey=kwa[:user_pubkey], notes=:follows, minwords, kwargs..., usepgfuncs, apply_humaness_check)
            return advanced_search(est; query="kind:30023 scope:myfollows minwords:100 features:summary", kwargs...)
        elseif get(s, "scope", "") == "zappedbyfollows"
            return long_form_content_feed(est; pubkey=kwa[:user_pubkey], notes=:zappedbyfollows, minwords, kwargs..., usepgfuncs, apply_humaness_check)
        elseif get(s, "scope", "") == "myfollowsinteractions"
            return advanced_search(est; query="kind:1 scope:myfollowsinteractions", kwargs...)
        elseif haskey(s, "topic")
            return long_form_content_feed(est; topic=s["topic"], minwords, kwargs..., usepgfuncs, apply_humaness_check)
        elseif haskey(s, "pubkey") && haskey(s, "curation")
            return long_form_content_feed(est; pubkey=s["pubkey"], curation=s["curation"], minwords, kwargs..., usepgfuncs, apply_humaness_check)
        else
            return long_form_content_feed(est; skwa..., minwords, kwargs..., usepgfuncs, apply_humaness_check)
        end

    elseif get(s, "kind", "") == "notes"
        if     id == "latest"
            return feed(est; pubkey=kwa[:user_pubkey], kwargs...)
        elseif id == "global-trending"
            # return explore_global_trending(est, s["hours"]; kwargs...)
            return explore(est; timeframe="trending", scope="global", created_after=Utils.current_time()-s["hours"]*3600, kwargs...) 
        elseif id == "video-reels"
            return advanced_search(est; query="kind:1 filter:video orientation:vertical maxduration:90 mininteractions:2", kwargs...)
        elseif id == "all-notes"
            return explore(est; timeframe="latest", scope="global", kwargs...)
        elseif id == "most-zapped"
            return explore_global_mostzapped(est, s["hours"]; kwargs...)
        elseif id == "wide-net-notes"
            return advanced_search(est; query="kind:1 scope:myfollowsinteractions", kwargs...)
        elseif id == "strange-but-popular"
            return advanced_search(est; query="kind:1 scope:notmyfollows minscore:50", kwargs...)
        elseif id == "engaging-discussions"
            return advanced_search(est; query="kind:1 minlongreplies:5", kwargs...)
        elseif id == "only-tweets"
            return advanced_search(est; query="kind:1 maxchars:140", kwargs...)
        elseif id == "bookmarked-by-follows"
            return advanced_search(est; query="kind:1 features:bookmarked-by-follows", kwargs...)
        elseif id == "important-notes-i-might-have-missed"
            return important_notes_i_might_have_missed_feed(est; kwargs...)
        elseif id == "feed"
            return feed(est; skwa..., kwargs..., usepgfuncs, apply_humaness_check)
        elseif id == "search"
            return search(est; skwa..., kwargs...)
        elseif id == "muted-threads"
            return muted_threads_feed(est; skwa..., kwargs...)
        end

    elseif id == "explore-media"
        return advanced_search(est; query="kind:1 filter:image scope:mynetworkinteractions -#nsfw features:cdnmedia", kwargs...)
    elseif id == "explore-zaps"
        return explore_zaps(est; skwa..., kwargs...)
    elseif id == "wide-net-notes"
        return wide_net_notes_feed(est; created_after=Utils.current_time()-24*3600, kwargs..., pubkey=kwa[:user_pubkey])
    elseif id == "hall-of-fame-notes"
        return explore(est; timeframe="trending", scope="global", created_after=0, kwargs...)
    elseif id == "only-tweets"
    elseif id == "bookmarked-notes"
    elseif id == "important-notes-i-might-have-missed"
    elseif Symbol(id) in exposed_functions
        return getproperty(@__MODULE__, Symbol(id))(est; skwa..., kwargs...)
    else
        for f in try JSON.parse(read(ADVANCED_FEEDS_FILE[], String)) catch _; [] end
            f["id"] == id && return mega_feed_directive(est; spec=f["specification"], kwargs...)
        end
    end

    []
end

function enrich_feed_events(est::DB.CacheStorage; event_ids, user_pubkey=nothing)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    eids = [cast(eid, Nostr.EventId) for eid in event_ids]
    response_messages_for_posts(est, eids; user_pubkey)
end

function enrich_feed_events_pg(
        est::DB.CacheStorage; 
        posts::Vector{Tuple{Nostr.EventId, Int}}, 
        user_pubkey=nothing, 
        orderby="created_at",
        apply_humaness_check=false,
    )
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    q = "select distinct e from enrich_feed_events(array (select row(decode(a->>0, 'hex'), a->>1)::post from jsonb_array_elements(\$1) x(a)), \$2, \$3, \$4) f(e) where e is not null"
    res = map(first, Postgres.execute(DAG_OUTPUTS_DB[], q,
                                      [JSON.json([(Nostr.hex(p[1]), p[2]) for p in posts]), user_pubkey, apply_humaness_check, orderby])[2])

    elements = []
    for e in Base.Iterators.reverse(res)
        if e["kind"] == RANGE
            d = JSON.parse(e["content"])
            if haskey(d, "elements")
                elements = d["elements"]
                break
            end
        end
    end

    pes = Dict()
    res2 = []
    for e in res
        if haskey(e, "id") && e["id"] in elements
            pes[e["id"]] = e
        else
            push!(res2, e)
        end
    end

    [[pes[eid] for eid in elements if haskey(pes, eid)]; res2]
end

HOME_FEEDS_FILE = Ref("home-feeds.json")

function get_home_feeds(est::DB.CacheStorage)
    [(; kind=Int(HOME_FEEDS), 
      content=JSON.json(try JSON.parse(read(HOME_FEEDS_FILE[], String))
                        catch _; (;) end))]
end

function response_messages_for_dvm_feeds(est::DB.CacheStorage, eids::Vector{Nostr.EventId}; user_pubkey=nothing, primal_feeds=nothing) 
    primal_dvm_pks = [kp.pubkey for kp in values(Main.DVMServiceProvider.keypairs)]
    res = []
    for eid in eids
        if eid in est.events
            e = est.events[eid]
            for t in e.tags
                if length(t.fields) >= 2 && t.fields[1] == "k" && t.fields[2] == "5300"
                    if !isnothing(local dvm_id = parametrized_replaceable_event_identifier(e))
                        is_primal = e.pubkey in primal_dvm_pks
                        primal_feeds == true  && !is_primal && break
                        primal_feeds == false &&  is_primal && break

                        push!(res, e)

                        append!(res, user_infos(est; pubkeys=[e.pubkey]))
                        append!(res, primal_verified_names(est, [e.pubkey]))

                        likes = Postgres.execute(DAG_OUTPUTS_DB[], 
                                                 "select count(1) from a_tags where kind = 7 and ref_kind = 31990 and ref_pubkey = \$1 and ref_identifier = \$2",
                                                 [e.pubkey, dvm_id])[2][1][1]
                        satszapped = Postgres.execute(DAG_OUTPUTS_DB[], 
                                                      "select sum(satszapped) from zap_receipts where receiver = \$1",
                                                      [e.pubkey])[2][1][1]
                        satszapped = ismissing(satszapped) ? 0 : number(satszapped)
                        push!(res, (; kind=Int(EVENT_STATS), content=JSON.json((; event_id=eid, likes, satszapped))))

                        if !isnothing(user_pubkey)
                            append!(res, get_dvm_feed_follows_actions(est; dvm_pubkey=e.pubkey, dvm_id, dvm_kind=e.kind, user_pubkey))
                            append!(res, get_dvm_feed_user_actions(est; dvm_pubkey=e.pubkey, dvm_id, dvm_kind=e.kind, user_pubkey))
                        end

                        for (kind,) in Postgres.execute(DAG_OUTPUTS_DB[], 
                                                        "select df.kind from dvm_feeds df where df.pubkey = \$1 and df.identifier = \$2",
                                                        [e.pubkey, dvm_id])[2]
                            append!(res, [(; kind=Int(DVM_FEED_METADATA), content=JSON.json((; event_id=eid, kind, is_primal)))])
                        end

                        break
                    end
                end
            end
        end
    end
    res
end

function get_dvm_feeds_all(est::DB.CacheStorage)
    map(Nostr.EventId, map(first, 
                           DB.exec(est.dyn[:parametrized_replaceable_events], 
                                   DB.@sql("select distinct pre.event_id from parametrized_replaceable_events pre, event_tags et 
                                           where et.kind = 31990 and pre.event_id = et.id and et.tag = 'k' and et.arg1 = '5300' and
                                           et.created_at >= ?1"),
                                   (Utils.current_time()-90*24*3600,))))
end

function get_dvm_feeds(est::DB.CacheStorage)
    eids = Nostr.EventId[]
    for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events], 
                          DB.@sql("select distinct pre.event_id from parametrized_replaceable_events pre, event_tags et, dvm_feeds df
                                  where et.kind = 31990 and pre.event_id = et.id and et.tag = 'k' and et.arg1 = '5300' and
                                  df.pubkey = pre.pubkey and df.updated_at >= ?1 and df.ok"),
                          (Dates.now() - Dates.Hour(1),))
        push!(eids, Nostr.EventId(eid))
    end
    response_messages_for_dvm_feeds(est, eids)
end

function dvm_feed_info(est::DB.CacheStorage; pubkey, identifier::String, user_pubkey=nothing)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    isnothing(user_pubkey) && (user_pubkey = Nostr.PubKeyId("532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb")) # primal pubkey as default

    eids = Nostr.EventId[]
    for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events], 
                          DB.@sql("select event_id from parametrized_replaceable_events
                                  where kind = 31990 and pubkey = ?1 and identifier = ?2"),
                          (pubkey, identifier))
        push!(eids, Nostr.EventId(eid))
    end
    response_messages_for_dvm_feeds(est, eids; user_pubkey)
end

FEATURED_DVM_FEEDS_FILE = Ref("featured-dvm-feeds.json")

function get_featured_dvm_feeds(est::DB.CacheStorage; kind::Union{String,Nothing}=nothing, user_pubkey=nothing, primal_feeds=nothing)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    if 1==1
        isnothing(user_pubkey) && (user_pubkey = Nostr.PubKeyId("532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb")) # primal pubkey as default

        eids = Nostr.EventId[]
        for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events], 
                              DB.@sql("
                                      select 
                                        distinct pre.event_id 
                                      from 
                                        parametrized_replaceable_events pre, 
                                        event_tags et, 
                                        dvm_feeds df, 
                                        events es
                                      where 
                                        et.kind = 31990 and pre.event_id = et.id and et.tag = 'k' and et.arg1 = '5300' and
                                        df.pubkey = pre.pubkey and df.updated_at >= ?1 and df.ok and 
                                        (case when ?2::text is null then true else df.kind = ?2 end) and 
                                        es.id = pre.event_id"),
                              (Dates.now() - Dates.Hour(1), kind))
            push!(eids, Nostr.EventId(eid))
        end
        return response_messages_for_dvm_feeds(est, eids; user_pubkey, primal_feeds)
    end

    eids = Nostr.EventId[]
    for f in JSON.parse(read(FEATURED_DVM_FEEDS_FILE[], String))
        f["kind"] == kind || continue
        ps = map(string, split(f["address"], ':'))
        k = parse(Int, ps[1])
        pk = Nostr.PubKeyId(ps[2])
        id = ps[3]
        for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events], 
                              DB.@sql("select event_id from parametrized_replaceable_events where kind = ?1 and pubkey = ?2 and identifier = ?3"), 
                              (k, pk, id))
            push!(eids, Nostr.EventId(eid))
        end
    end
    response_messages_for_dvm_feeds(est, eids; user_pubkey)
end

import UUIDs
import ..NostrClient

DVM_REQUESTER_KEYPAIR = Ref{Any}(nothing)

in_pgspi() = hasproperty(Main, :spi_execute)

function dvm_feed(
        est::DB.CacheStorage;
        dvm_pubkey,
        dvm_id::String,
        dvm_kind::Int=31990,
        user_pubkey=nothing,
        timeout=10,
        since=0, until=Utils.current_time(), limit=20, offset=0,
        usecache=true,
        kwargs...,
    )
    in_pgspi() && return []

    dvm_pubkey = cast(dvm_pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    # @show (dvm_pubkey, dvm_id)

    function response(eids)
        posts = Tuple{Nostr.EventId, Int}[]
        for eid in eids
            if eid in est.events
                push!(posts, (eid, est.events[eid].created_at))
            end
        end
        posts = first(sort(posts; by=p->-p[2])[offset+1:end], limit)
        [response_messages_for_posts(est, map(first, posts); user_pubkey); range(posts, :created_at)]
    end

    einfo = nothing
    einfo_relay_url = nothing
    for (eid,) in DB.exec(est.dyn[:parametrized_replaceable_events], 
                          DB.@sql("select event_id from parametrized_replaceable_events where kind = ?1 and pubkey = ?2 and identifier = ?3"), 
                          (dvm_kind, dvm_pubkey, dvm_id))
        eid = Nostr.EventId(eid)
        if eid in est.events
            einfo = est.events[eid]
            for (relay_url,) in DB.exec(est.dyn[:event_relay], DB.@sql("select relay_url from event_relay where event_id = ?1 limit 1"), (eid,))
                einfo_relay_url = relay_url
                break
            end
            break
        end
    end
    isnothing(einfo) && return []
    dvminfo = JSON.parse(einfo.content)
    personalized = get(dvminfo, "personalized", false)

    if usecache && !personalized
        for (eids,) in DB.exec(est.dyn[:dvm_feeds], 
                          DB.@sql("select results from dvm_feeds 
                                  where pubkey = ?1 and updated_at >= ?2 and ok and results is not null"),
                          (dvm_pubkey, Dates.now() - Dates.Minute(15),))
            return response(map(Nostr.EventId, eids))
        end
    end

    relays = collect(Main.DVMFeedChecker.RELAYS)
    !isnothing(einfo_relay_url) && push!(relays, einfo_relay_url)
    # if !isnothing(user_pubkey)
    #     for t in App.get_user_relays(est; pubkey=user_pubkey)[1].tags
    #         length(t) >= 2 && t[1] == "r" && push!(relays, t[2])
    #     end
    # end
    relays = collect(Set(relays))

    req_id = UUIDs.uuid4()

    jobreq = Nostr.Event(DVM_REQUESTER_KEYPAIR[].seckey, DVM_REQUESTER_KEYPAIR[].pubkey,
                         trunc(Int, time()),
                         5300,
                         [Nostr.TagAny(t)
                          for t in [["p", Nostr.hex(dvm_pubkey)],
                                    ["alt", "NIP90 Content Discovery Request"],
                                    ["relays", relays...],
                                    (personalized ? [
                                        ["param", "max_results", "100"],
                                        ["param", "user", Nostr.hex(user_pubkey)],
                                    ] : [])...,
                                   ]],
                         "")

    function on_connect(client)
        NostrClient.subscription(client, (; 
                                          limit=10,
                                          kinds=[6300, 7000], 
                                          Symbol("#e")=>[Nostr.hex(jobreq.id)],
                                         )) do m
            try
                handle_result(client, m)
            catch _
                PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                @async try close(client) catch ex println(ex) end
            end
        end

        NostrClient.send(client, jobreq; timeout=5.0) do m, done
            m[1] == "OK" || error("dvm: broadcasting to $(client.relay_url) feed $dvm_id job request event failed")
            done(:ok)
        end

    end

    chn = Channel(Inf)

    function handle_result(client, m)
        m[1] == "EVENT" || return
        e = Nostr.Event(m[3])
        @assert Nostr.verify(e)
        if e.kind == 6300
            eids = Nostr.EventId[]
            for t in JSON.parse(e.content)
                t[1] == "e" && push!(eids, Nostr.EventId(t[2]))
            end
            put!(chn, eids)
        elseif e.kind == 7000
            for t in e.tags; t = t.fields
                if t[1] == "status" && t[2] == "error"
                    put!(chn, ErrorException("dvm_feed error: $(t[3])"))
                end
            end
        end
    end

    @async begin
        sleep(timeout)
        put!(chn, NostrClient.Timeout("dvm_feed"))
    end

    clients = []
    for relay_url in relays
        push!(clients, NostrClient.Client(relay_url;
                                          on_connect=(client)->@async try
                                              on_connect(client)
                                          catch _
                                              PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                                          end))
    end

    try
        eids = take!(chn)
        eids isa Exception && throw(eids)
        response(eids)
    finally
        for client in clients
            @async try close(client) catch ex println(ex) end
        end
    end
end

function get_dvm_feed_user_actions(est::DB.CacheStorage; dvm_pubkey, dvm_id::String, dvm_kind=31990, user_pubkey)
    user_pubkey = cast(user_pubkey, Nostr.PubKeyId)

    liked = replied = zapped = reposted = false

    for (k,) in Postgres.execute(DAG_OUTPUTS_DB[],
                                 pgparams() do P "
                                     select 
                                         at.kind
                                     from 
                                         a_tags at,
                                         event es
                                     where 
                                         at.ref_kind = $(@P dvm_kind) and
                                         at.ref_pubkey = $(@P dvm_pubkey) and
                                         at.ref_identifier = $(@P dvm_id) and
                                         at.eid = es.id and
                                         es.pubkey = $(@P user_pubkey)
                                     " end...)[2]
        if     k == Int(Nostr.TEXT_NOTE); replied = true
        elseif k == Int(Nostr.REACTION); liked = true
        elseif k == Int(Nostr.REPOST); reposted = true
        end
    end

    for _ in Postgres.execute(DAG_OUTPUTS_DB[],
                                 pgparams() do P "
                                     select 
                                         1
                                     from 
                                         a_tags at,
                                         zap_receipts zr
                                     where 
                                         at.ref_kind = $(@P dvm_kind) and
                                         at.ref_pubkey = $(@P dvm_pubkey) and
                                         at.ref_identifier = $(@P dvm_id) and
                                         at.kind = $(@P Int(Nostr.ZAP_RECEIPT)) and
                                         at.eid = zr.eid and
                                         zr.sender = $(@P user_pubkey)
                                     limit 1
                                 " end...)[2]
        zapped = true
    end

    event_id = Postgres.execute(DAG_OUTPUTS_DB[],
                                pgparams() do P "
                                    select event_id from parametrized_replaceable_events
                                    where kind = $(@P dvm_kind) and pubkey = $(@P dvm_pubkey) and identifier = $(@P dvm_id)
                                    "
                                end...)[2][1][1] |> Nostr.EventId

    [(; kind=Int(EVENT_ACTIONS_COUNT), content=JSON.json((; event_id, liked, replied, zapped, reposted)))]
end

function get_dvm_feed_follows_actions(
        est::DB.CacheStorage; 
        dvm_pubkey, dvm_id::String, dvm_kind=31990, 
        user_pubkey, 
        limit=5,
    )
    dvm_pubkey = cast(dvm_pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    limit = min(20, limit)

    res = []
    res_mds = []
    for r in Postgres.execute(DAG_OUTPUTS_DB[],
                              pgparams() do P "
                                  select
                                      pks.pubkey
                                  from
                                      (
                                          (
                                              select 
                                                  es.pubkey
                                              from 
                                                  a_tags at,
                                                  event es
                                              where 
                                                  at.ref_kind = $(@P dvm_kind) and
                                                  at.ref_pubkey = $(@P dvm_pubkey) and
                                                  at.ref_identifier = $(@P dvm_id) and
                                                  (at.kind = $(@P Int(Nostr.TEXT_NOTE)) or at.kind = $(@P Int(Nostr.REACTION))) and
                                                  es.id = at.eid
                                          ) union (
                                              select 
                                                  zr.sender as pubkey
                                              from 
                                                  a_tags at,
                                                  zap_receipts zr
                                              where 
                                                  at.ref_kind = $(@P dvm_kind) and
                                                  at.ref_pubkey = $(@P dvm_pubkey) and
                                                  at.ref_identifier = $(@P dvm_id) and
                                                  at.kind = $(@P Int(Nostr.ZAP_RECEIPT)) and
                                                  at.eid = zr.eid
                                          )
                                      ) pks,
                                      pubkey_followers pf, 
                                      pubkey_followers_cnt pfc
                                  where
                                      pf.pubkey = pks.pubkey and
                                      $(@P user_pubkey) = pf.follower_pubkey and 
                                      pks.pubkey = pfc.key
                                  group by pks.pubkey
                                  order by max(pfc.value) desc limit $(@P limit)
                              " end...)[2]
        pk = Nostr.PubKeyId(r[1])
        if pk in est.meta_data
            mdid = est.meta_data[pk]
            if mdid in est.events
                md = est.events[mdid]
                push!(res, md)
                push!(res_mds, md)
                append!(res, ext_event_response(est, md))
            end
        end
    end

    append!(res, user_scores(est, res_mds))

    event_id = Postgres.execute(DAG_OUTPUTS_DB[],
                                pgparams() do P "
                                    select event_id from parametrized_replaceable_events
                                    where kind = $(@P dvm_kind) and pubkey = $(@P dvm_pubkey) and identifier = $(@P dvm_id)
                                    "
                                end...)[2][1][1] |> Nostr.EventId

    # @show (dvm_pubkey, dvm_id, dvm_kind, event_id, length(res_mds))

    r = (; event_id=Nostr.hex(event_id), dvm_pubkey, dvm_id, dvm_kind, users=[Nostr.hex(e.pubkey) for e in res_mds])

    append!(res, [(; kind=Int(DVM_FEED_FOLLOWS_ACTIONS), content=JSON.json(r))])

    res
end

function parametrized_replaceable_event_identifier(e::Nostr.Event)
    for tag in e.tags
        if length(tag.fields) >= 2 && tag.fields[1] == "d"
            return tag.fields[2]
        end
    end
    nothing
end

function explore_zaps(
        est::DB.CacheStorage;
        limit::Int=20, since::Int=0, until=nothing, offset::Int=0,
        created_after=Utils.current_time()-24*3600,
        user_pubkey=nothing,
    )
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    limit = min(50, limit)
    limit <= 1000 || error("limit too big")

    isnothing(until) && (until = 100_000_000_000)
    zaps = map(Tuple, DB.exec(est.zap_receipts, 
                              "select zr.zap_receipt_id, zr.created_at, zr.event_id, zr.sender, zr.receiver, zr.amount_sats 
                                  from og_zap_receipts zr, pubkey_trustrank tr, events es
                              where 
                                  zr.amount_sats >= ?1 and zr.amount_sats <= ?2 and zr.created_at >= ?3 and
                                  zr.sender = tr.pubkey and tr.rank >= ?4 and
                                  zr.event_id = es.id and es.kind = any ('{$(Int(Nostr.TEXT_NOTE)), $(Int(Nostr.LONG_FORM_CONTENT))}'::int8[])
                              order by zr.amount_sats desc, zr.event_id asc limit ?5 offset ?6",
                              (since, until, created_after, Main.TrustRank.humaness_threshold[], limit, offset)))

    zaps = sort(zaps, by=z->-z[6])[1:min(limit, length(zaps))]

    res = OrderedSet()
    union!(res, response_messages_for_zaps(est, zaps; order_by=:amount_sats))
    union!(res, response_messages_for_posts(est, [Nostr.EventId(z[3]) for z in zaps]; user_pubkey))
    collect(res)
end

function explore_people(
        est::DB.CacheStorage;
        since::Int=0, until::Int=1000000000, offset::Int=0, limit::Int=20, 
        user_pubkey=nothing,
    )
    limit = min(50, limit)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    isnothing(user_pubkey) && (user_pubkey = Nostr.PubKeyId("532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb")) # primal pubkey as default

    res = []

    for (pk, cnt, increase, ratio) in Postgres.execute(DAG_OUTPUTS_DB[], 
                                    pgparams() do P "
                                        with scope_pks as (
                                            select pf1.pubkey
                                            from pubkey_followers pf1
                                            where pf1.follower_pubkey = $(@P user_pubkey)
                                        )
                                        select * from daily_followers_cnt_increases dfi
                                        where 
                                            dfi.increase >= $(@P since) and dfi.increase <= $(@P until) and
                                            not exists (select 1 from scope_pks where scope_pks.pubkey = dfi.pubkey) and
                                            user_has_bio(dfi.pubkey)
                                        order by dfi.increase desc, dfi.pubkey asc limit $(@P limit) offset $(@P offset)"
                                    end...)[2]
        push!(res, (Nostr.PubKeyId(pk), increase, ratio, cnt))
    end

    [[(; kind=Int(USER_FOLLOWER_COUNT_INCREASES), 
       content=JSON.json(Dict([Nostr.hex(pk)=>(; increase, ratio, count=cnt) for (pk, increase, ratio, cnt) in res])))];
     user_infos(est; pubkeys=map(first, res)); 
     range(res, :increase)]
end

function explore_media(est::DB.CacheStorage; kwargs...)
    mega_feed_directive(est; spec=raw"""{"id":"explore-media"}""", kwargs...)
end

function explore_topics(est::DB.CacheStorage; user_pubkey=nothing)
    get(est.dyn[:cache], "precalculated_analytics_explore_topics", [])
end

function explore_topics_(est::DB.CacheStorage; created_after::Int=Utils.current_time()-1*24*3600)
    hidden_hashtags = ["nsfw", "sexpervertsyndicate"]
    res = DB.exec(est.event_hashtags, 
                  DB.@sql("select eh.hashtag, count(1) as cnt
                          from event_hashtags eh, events es, pubkey_trustrank tr
                          where 
                              eh.created_at >= ?1 and eh.event_id = es.id and
                              es.pubkey = tr.pubkey and tr.rank > ?2 and
                              not (eh.hashtag = any (?3::varchar[]))
                          group by eh.hashtag
                          order by cnt desc
                          limit 200"), 
                  (created_after, Main.TrustRank.humaness_threshold[], "{$(join(hidden_hashtags, ','))}"))
    [(; kind=Int(HASHTAGS_2), content=JSON.json(Dict(res)))]
end

function set_last_time_user_was_online(est::DB.CacheStorage; event_from_user::Dict)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
        
    e = parse_event_from_user(event_from_user)

    est.dyn[:user_last_online_time][e.pubkey] = parse(Int, e.content)

    []
end

function important_notes_i_might_have_missed_feed(
        est::DB.CacheStorage;
        limit=20, offset=0, since=0, until=Utils.current_time(),
        user_pubkey=nothing,
    )
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    # reposted_after = est.dyn[:user_last_online_time][user_pubkey]
    # reposted_after = DB.exec(est.app_settings, "select accessed_at from app_settings where key = ?1", (user_pubkey,))[1][1]
    reposted_after = Utils.current_time() - 24*3600

    posts = Tuple{Nostr.EventId, Int}[]
    append!(posts, 
            [(Nostr.EventId(eid), created_at)
             for (eid, created_at) in 
             Postgres.execute(DAG_OUTPUTS_DB[],
                              pgparams() do P "
                              select 
                                  es.id, es.created_at
                              from 
                                  events es,
                                  basic_tags bt,
                                  pubkey_followers pf
                              where 
                                  pf.follower_pubkey = $(@P user_pubkey) and
                                  pf.pubkey = bt.pubkey and
                                  bt.kind = $(Int(Nostr.REPOST)) and
                                  bt.created_at >= $(@P reposted_after) and
                                  bt.tag = 'e' and
                                  bt.id = es.id and
                                  es.created_at >= $(@P since) and es.created_at <= $(@P until)
                              order by es.created_at desc
                              limit $(@P limit) offset $(@P offset)
                          " end...)[2]])

    # vcat(response_messages_for_posts(est, collect(map(first, posts)); user_pubkey), range(posts, :created_at))
    enrich_feed_events_pg(est; posts, user_pubkey)
end

function fetch_results(
        session,
        since::Int, until::Int, limit::Int, offset::Int; 
        has_orderby=false, dt=3600, timeout=9.0, explain=nothing,
        sql_generator::Function, 
        accept_result::Function=_->true,
    )
    dt_start = dt

    res = []
    ids = Set()

    tstart = time()
    tend = tstart + timeout

    t = until

    done = Ref(false)
    j = Ref(0)
    while length(res) < limit + offset && since <= t && time() < tend && !done[]
        j[] += 1

        if has_orderby
            s, u = since, t
        else
            s, u = t-dt, t
        end

        sql, params = sql_generator(s, u, res)

        if !isnothing(explain)
            if explain == :basic
                for s in map(first, Postgres.execute(session, "explain declare cur no scroll cursor for $sql", params)[2])
                    println(s)
                end
            else
                for s in map(first, Postgres.execute(session, "explain (analyze,buffers) declare cur no scroll cursor for $sql", params)[2])
                    if explain == :full
                        println(s)
                    elseif explain == :buffers && occursin("Buffers:", s)
                        println(s)
                    end
                end
            end
            println()
        end

        timeout = trunc(Int, 1000.0*(tend - time()))
        timeout < 0 && break
        Postgres.execute(session, "set statement_timeout=$timeout")

        i = Ref(0)
        try
            Postgres.execute(session, "declare cur no scroll cursor for $sql", params)
            while length(res) < limit + offset && time() < tend && !done[]
                r = Postgres.execute(session, "fetch next from cur")[2]
                isempty(r) && break
                (id, posted_at, rest...) = r[1]
                if !(id in ids)
                    i[] += 1
                    push!(ids, id)
                    ar = accept_result(r[1])
                    if ar == :done
                        done[] = true
                    elseif ar == true
                        push!(res, r[1])
                    end
                    # @show (i[], length(res), posted_at |> Dates.unix2datetime)
                end
            end
        catch ex
            println("fetch_results: ", ex isa ErrorException ? ex : typeof(ex))
            if ex isa Postgres.PostgresException && occursin("statement timeout", ex.fields['M'])
                break
            else
                rethrow()
            end
        end

        Postgres.execute(session, "close cur")

        done[] && break

        if i[] > 0
            t = res[end][2]
            dt = dt_start
        else
            t -= dt
            dt *= 4
        end
    end

    res[1+offset:end]
end

function content_moderation_repo_file(filename::String)::String
    abspath(dirname(RECOMMENDED_READS_FILE[])*"/"*filename)
end

function client_config(est::DB.CacheStorage)
    d = try JSON.parse(read(content_moderation_repo_file("client-config.json"), String)) catch _; nothing end
    [(; kind=Int(SHOW_PRIMAL_SUPPORT), content=JSON.json(d))]
end

function membership_event_from_user(event_from_user::Dict)
    if event_from_user["pubkey"] in [
                                    ]
        (; 
         pubkey=Nostr.PubKeyId(event_from_user["pubkey"]),
         content=get(event_from_user, "content", nothing),
        )
    else
        parse_event_from_user(event_from_user)
    end
end

function membership_media_management_stats(est::DB.CacheStorage; event_from_user::Dict)
    e = membership_event_from_user(event_from_user)

    image = 0
    video = 0
    other = 0

    for (upload_type, cnt, size) in Postgres.execute(:membership, "select * from membership_media_management_stats(\$1)", [e.pubkey])[2]
        if     upload_type == "video"; video += size
        elseif upload_type == "image"; image += size
        elseif upload_type == "other"; other += size
        end
    end

    max_storage = Postgres.execute(:membership, "
                                   select mt.max_storage 
                                   from memberships ms, membership_tiers mt
                                   where ms.pubkey = \$1 and ms.tier = mt.tier",
                                   [e.pubkey])[2][1][1]
    free = max_storage - (image + video + other)

    [(; kind=Int(MEMBERSHIP_MEDIA_MANAGEMENT_STATS), content=JSON.json((; video, image, other, free)))]
end

function membership_media_management_uploads(
        est::DB.CacheStorage; 
        event_from_user::Dict,
        since::Int=0, until::Int=1<<62, limit::Int=20, offset::Int=0
    )
    e = membership_event_from_user(event_from_user)

    res = []
    urls = []
    us = []
    for (sha256, path, size, mimetype, created_at) in 
        Postgres.execute(:membership, 
                         "select mu.sha256, mu.path, mu.size, mu.mimetype, mu.created_at
                         from media_uploads mu
                         where 
                            mu.pubkey = \$1 and mu.created_at >= \$2 and mu.created_at <= \$3 and 
                            mu.media_block_id is null
                         order by mu.created_at desc
                         limit \$4 offset \$5", 
                         [e.pubkey, since, until, limit, offset])[2]
        ext = splitext(path)[end]
        url = "https://blossom.primal.net/$(bytes2hex(sha256))$(ext)"
        push!(us, (url, created_at))
        push!(res, (; url, size, mimetype, created_at))
        push!(urls, url)
    end

    [(; kind=Int(MEMBERSHIP_MEDIA_MANAGEMENT_UPLOADS), content=JSON.json(res)); get_media_metadata(est; urls); range(us, :created_at)]
end

MEDIA_SERVER_HOST = Ref("")

function membership_media_management_delete(est::DB.CacheStorage; event_from_user::Dict)
    try
    e = membership_event_from_user(event_from_user)

    surl = JSON.parse(e.content)["url"]

    @show sha256 = hex2bytes(splitext(splitpath(URIs.parse_uri(surl).path)[end])[1])
    isempty(Postgres.execute(:membership, "select 1 from media_uploads where sha256 = \$1 and pubkey = \$2", [sha256, e.pubkey])[2]) && error("invalid url")

    String(HTTP.request("POST", "$(MEDIA_SERVER_HOST[])/purge-media", [], JSON.json((; e.pubkey, url=surl, reason="deleted"))).body) == "ok" || error("deletion failed")

    []
catch _
    Utils.print_exceptions()
    rethrow()
end
end

function membership_recovery_contact_lists(
        est::DB.CacheStorage; 
        event_from_user::Dict,
        kwargs...
    )
    e = membership_event_from_user(event_from_user)
    membership_recovery_contact_lists_(est, e.pubkey)
end

function membership_recovery_contact_lists_(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)
    es = []
    for (_, eid, created_at) in Postgres.execute(:p0timelimit, "
                                                 with cls as (
                                                     select created_at/(24*3600)::int8 as day, id, created_at, jsonb_array_length(tags) as follows
                                                     from events where pubkey = \$1 and kind = 3
                                                 )
                                                 select distinct on (day) day*24*3600, id, created_at
                                                 from cls 
                                                 order by day desc, follows desc, id
                                                 limit 30
                                                 ",
                                                 [pubkey])[2]
        push!(es, (Nostr.EventId(eid), created_at))
    end
    # es = sort(es; by=x->-x[2])

    res = []
    for (eid, _) in es
        eid in est.events && push!(res, est.events[eid])
    end

    [res; range(es, :created_at)]
end

function membership_recover_contact_list(est::DB.CacheStorage; event_from_user::Dict)
    e = membership_event_from_user(event_from_user)

    @show eid = JSON.parse(e.content)["event_id"]

    []
end

function membership_content_stats(est::DB.CacheStorage; event_from_user::Dict)
    e = membership_event_from_user(event_from_user)

    res = []
    for (kind, cnt) in Postgres.execute(:p0timelimit, "
                                              select kind, count(1) as cnt from events where pubkey = \$1
                                              group by kind order by cnt desc",
                                              [e.pubkey])[2]
        push!(res, (; kind, cnt))
    end

    [(; kind=Int(MEMBERSHIP_CONTENT_STATS), content=JSON.json(res))]
end

function membership_content_backup(est::DB.CacheStorage; event_from_user::Dict, kinds=nothing, since=0, limit=100000)
    e = membership_event_from_user(event_from_user)
    limit = min(100000, limit)
    get_user_events(est; e.pubkey, kinds, since, limit)[1]
end

function get_user_events(est::DB.CacheStorage; pubkey::Nostr.PubKeyId, kinds=nothing, since=0, limit=100000, countonly=false)
    contentsel = countonly ? "''" : "content"
    q, qargs = if isnothing(kinds)
        "select id, pubkey, created_at, kind, tags, $contentsel, sig from events where pubkey = \$1 and created_at >= \$2 order by created_at asc limit \$3", [pubkey, since, limit]
    else
        kindsarr = "{$(join(kinds, ','))}"
        "select id, pubkey, created_at, kind, tags, $contentsel, sig from events where pubkey = \$1 and created_at >= \$2 and kind = any (\$3::text::int8[]) order by created_at asc limit \$4", [pubkey, since, kindsarr, limit]
    end
    rs = Postgres.execute(:p0timelimit, q, qargs)[2]

    rescnt = 0
    last_created_at = 0
    res = Nostr.Event[]
    re = Dict()
    for r in rs
        e = event_from_row(r)
        last_created_at = max(last_created_at, e.created_at)
        if e.kind == 0 || e.kind == 3 || (e.kind >= 10000 && e.kind < 20000)
            re[(e.pubkey, e.kind)] = e
        elseif e.kind >= 30000 && e.kind < 40000
            id = parametrized_replaceable_event_identifier(e)
            re[(e.pubkey, e.kind, id)] = e
        else
            rescnt += 1
            countonly || push!(res, e)
        end
    end

    countonly || append!(res, values(re))

    countonly ? (last_created_at, length(re) + rescnt) : (sort(res; by=e->e.created_at), length(res))
end

function membership_content_rebroadcast_start(est::DB.CacheStorage; event_from_user::Dict, kinds=nothing)
    e = membership_event_from_user(event_from_user)

    if !isempty(Postgres.execute(:membership, "
                                 select 1 from event_rebroadcasting 
                                 where pubkey = \$1 and started_at is not null and finished_at is null", 
                                 [e.pubkey])[2])
        error("rebroadcasting already started")
    end

    d = JSON.parse(e.content)
    relays = if haskey(d, "relays")
        d["relays"]
    else
        relays = Set()
        for t in App.get_user_relays(est; e.pubkey)[1].tags
            if     length(t) == 2 && t[1] == "r"
                push!(relays, t[2])
            elseif length(t) == 3 && t[1] == "r" && t[3] == "write"
                push!(relays, t[2])
            end
        end
        collect(relays)
    end

    event_count = 0
    since = 0
    while true
        yield()
        last_created_at, cnt = get_user_events(est; e.pubkey, kinds, since, limit=10000, countonly=true)
        since == last_created_at && break
        since = last_created_at
        event_count += cnt
    end

    Postgres.execute(:membership, "delete from event_rebroadcasting where pubkey = \$1", [e.pubkey])
    Postgres.execute(:membership, "insert into event_rebroadcasting values (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13, \$14)",
                     [e.pubkey, Dates.now(), missing, 0, 0, event_count, JSON.json(relays), "started", JSON.json(kinds), missing, 0, missing, missing, 0])

    membership_content_rebroadcast_status(est; event_from_user)
end

function membership_content_rebroadcast_cancel(est::DB.CacheStorage; event_from_user::Dict)
    e = membership_event_from_user(event_from_user)

    Postgres.execute(:membership, "update event_rebroadcasting set finished_at = now(), status = 'canceled' where pubkey = \$1 and finished_at is null", 
                     [e.pubkey])

    membership_content_rebroadcast_status(est; event_from_user)
end

function membership_content_rebroadcast_status(est::DB.CacheStorage; event_from_user::Dict)
    e = membership_event_from_user(event_from_user)

    r = Postgres.execute(:membership, "
                         select started_at, finished_at, event_idx_intermediate, event_count, status, kinds
                         from event_rebroadcasting where pubkey = \$1", [e.pubkey])[2]
    isempty(r) && return []

    started_at, finished_at, event_idx_intermediate, event_count, status, kinds = r[1]

    running = !ismissing(started_at) && ismissing(finished_at)

    res =
    if running
        (; running, kinds, status, progress=min(1.0, Float64(event_idx_intermediate) / event_count))
    else
        (; running, kinds, status, progress=0.0)
    end

    [(; kind=Int(MEMBERSHIP_CONTENT_REBROADCAST_STATUS), content=JSON.json(res))]
end

function membership_legends_leaderboard(est::DB.CacheStorage; order_by="donated_btc", limit=100, since=0, until=typemax(Int), offset=0)
    order_by in ["donated_btc", "last_donation", "index"] || error("invalid order_by")
    limit = min(limit, 300)
    dir = order_by in ["donated_btc", "last_donation"] ? "desc" : "asc"
    res = []
    rs = []
    ks = []
    for (k, index, pubkey, last_donation, donated_btc) in 
        Postgres.execute(:membership, "
                         with a as (
                             select row_number() over () as index, * from (
                                 select 
                                     ls.pubkey, 
                                     extract(epoch from ls.last_donation)::int8 as last_donation,
                                     (ls.donated_btc*100000000)::int8 as donated_btc
                                 from legend_users ls, memberships ms, membership_legend_customization mlc
                                 where ms.pubkey = ls.pubkey and ms.pubkey = mlc.pubkey and mlc.in_leaderboard and ls.donated_btc > 0
                                 order by ls.donated_btc desc
                            ) b
                         )
                         select $order_by, * from a
                         where $order_by >= \$1 and $order_by <= \$2
                         order by $order_by $dir limit \$3 offset \$4
                         ", [since, until, limit, offset])[2]
        pubkey = Nostr.PubKeyId(pubkey)
        push!(ks, (pubkey, k))
        push!(rs, (; index, pubkey, donated_btc=string(donated_btc), last_donation))
        append!(res, user_infos(est; pubkeys=[pubkey]))
        append!(res, primal_verified_names(est, [pubkey]))
    end
    push!(res, (; kind=Int(MEMBERSHIP_LEGEND_LEADERBOARD), content=JSON.json(rs)))
    append!(res, range(ks, order_by))
    res
end

function membership_premium_leaderboard(est::DB.CacheStorage; order_by="premium_since", limit=100, since=0, until=typemax(Int), offset=0)
    order_by in ["index", "premium_since"] || error("invalid order_by")
    limit = min(limit, 300)
    dir = order_by in ["premium_since"] ? "desc" : "asc"
    res = []
    rs = []
    ks = []
    for (k, index, pubkey, premium_since) in 
        Postgres.execute(:membership, "
                         with a as (
                             select row_number() over () as index, * from (
                                 select 
                                     pu.pubkey,
                                     extract(epoch from ms.premium_since)::int8 as premium_since
                                 from premium_users pu, memberships ms
                                 where ms.pubkey = pu.pubkey
                                 order by ms.premium_since
                            ) b
                         )
                         select $order_by, * from a
                         where $order_by >= \$1 and $order_by <= \$2
                         order by $order_by $dir limit \$3 offset \$4
                         ", [since, until, limit, offset])[2]
        pubkey = Nostr.PubKeyId(pubkey)
        push!(ks, (pubkey, k))
        push!(rs, (; index, pubkey, premium_since))
        append!(res, user_infos(est; pubkeys=[pubkey]))
        append!(res, primal_verified_names(est, [pubkey]))
    end
    push!(res, (; kind=Int(MEMBERSHIP_PREMIUM_LEADERBOARD), content=JSON.json(rs)))
    append!(res, range(ks, order_by))
    res
end

function fetch_content(est::DB.CacheStorage, pubkey::Nostr.PubKeyId; withfollows=true, days=7)
    DB.fetch_user_metadata(est, pubkey)
    pks = [pubkey]
    withfollows && append!(pks, follows(est, pubkey))
    DB.fetch((; kinds=[0], authors=pks))
    DB.fetch((; since=Utils.current_time()-days*24*3600, kinds=DB.kindints, authors=pks))
end

function nip19_decode(est::DB.CacheStorage; ids::Vector)
    function ser(r)
        if     r isa Nostr.EventId
            [("EventId", r)]
        elseif r isa Nostr.PubKeyId
            [("PubKeyId", r)]
        elseif r isa Vector
            res = []
            for e in r
                append!(res, ser(e))
            end
            res
        elseif r isa Tuple
            res = []
            for e in r
                append!(res, ser(e))
            end
            res
        else
            [r]
        end
    end
    res = Dict([id=>ser(Bech32.nip19_decode(id)) for id in ids])
    [(; kind=Int(NIP19_DECODE_RESULT), content=JSON.json(res))]
end

# function mute_thread(est::DB.CacheStorage; event_from_user)
#     e = membership_event_from_user(event_from_user)
#     root_eid = cast(JSON.parse(e.content)["root_event_id"], Nostr.EventId)
#     Postgres.execute(:membership, "
#                      insert into muted_threads values (\$1, \$2, now())
#                      on conflict do nothing
#                      ", [e.pubkey, root_eid])
#     []
# end

# function unmute_thread(est::DB.CacheStorage; event_from_user)
#     e = membership_event_from_user(event_from_user)
#     root_eid = cast(JSON.parse(e.content)["root_event_id"], Nostr.EventId)
#     Postgres.execute(:membership, "
#                      delete from muted_threads where pubkey = \$1 and root_eid = \$2
#                      ", [e.pubkey, root_eid])
#     []
# end

function parse_event_from_user_for_push_notification_token(event_from_user::Dict)
    e = Nostr.Event(event_from_user)
    e.created_at < time() + 300 || error("event from the future")
    Nostr.verify(e) || error("event_from_user verification failed")
    d = JSON.parse(e.content)
    (; e, token=d["token"])
end

function update_push_notification_token(est::DB.CacheStorage; events_from_users::Vector, platform::String, token::String, environment=nothing)
    # push!(Main.stuff, (:update_push_notification_token, (; events_from_users, platform, token, environment)))
    platform = lowercase(platform)
    tokens = [parse_event_from_user_for_push_notification_token(e) for e in events_from_users]
    Postgres.transaction(:membership) do sess
        Postgres.execute(sess, "delete from notification_tokens where platform = \$1 and token = \$2", [platform, token])
        for t in tokens
            @assert t.token == token
            Postgres.execute(sess, "insert into notification_tokens values (\$1, \$2, \$3, now(), \$4, \$5)", 
                             [platform, token, t.e.pubkey, environment, JSON.json(t.e)])
        end
    end
    []
end

function articles_stats(est::DB.CacheStorage; pubkey, kind=30023)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    res = (; 
           articles=Postgres.execute(:p0, "select count(1) from reads where pubkey = \$1", [pubkey])[2][1][1],
           drafts=Postgres.execute(:p0, "
                                   with ts as (select id, jsonb_array_elements(tags) ->> 0 as tag, jsonb_array_elements(tags) ->> 1 as arg
                                               from events where pubkey = \$1 and kind = 31234)
                                   select count(distinct id) from ts where ts.tag = 'k' and ts.arg = \$2::varchar",
                                   [pubkey, kind])[2][1][1],
           satszapped=Postgres.execute(:p0, "select coalesce(sum(satszapped), 0) from reads where pubkey = \$1", [pubkey])[2][1][1],
          )
    [(; kind=Int(ARTICLES_STATS), content=JSON.json(res))]
end

function drafts(est::DB.CacheStorage; pubkey, kind, since=0, until=Utils.current_time(), limit=20, offset=0)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    limit = min(100, limit)
    res = []
    for r in Postgres.execute(:p0, "
                              with ts as (select id, jsonb_array_elements(tags) ->> 0 as tag, jsonb_array_elements(tags) ->> 1 as arg
                                          from events where pubkey = \$1 and kind = 31234)
                              select es.* from ts, events es
                              where ts.arg = \$2::varchar and ts.id = es.id and es.created_at >= \$3 and es.created_at <= \$4
                              order by es.created_at desc 
                              limit \$5 offset \$6", [pubkey, kind, since, until, limit, offset])[2]
        push!(res, event_from_row(r))
    end
    res
end

function top_article(est::DB.CacheStorage; pubkey, by)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    by = cast(by, Symbol)
    eid = nothing
    if     by == :satszapped
        for r in Postgres.execute(:p0, "
                                  select latest_eid from reads where pubkey = \$1
                                  order by satszapped desc limit 1", 
                                  [pubkey])[2]
            eid = Nostr.EventId(r[1])
        end
    elseif by == :interactions
        for r in Postgres.execute(:p0, "
                                  select latest_eid from reads where pubkey = \$1
                                  order by (likes + zaps + replies + reposts) desc limit 1", 
                                  [pubkey])[2]
            eid = Nostr.EventId(r[1])
        end
    end
    res = []
    if eid in est.events
        push!(res, est.events[eid])
        for r in Postgres.pexnt(:p0, "
                             select latest_eid as event_id, likes, replies, 0 AS mentions, reposts, zaps, satszapped, 0 AS score, 0 AS score24h, 0 as bookmarks 
                             from reads where latest_eid = \$1
                             ", [eid])
            push!(res, (; kind=Int(EVENT_STATS), content=JSON.json(r)))
        end
    end
    res
end

function get_recommended_blossom_servers(est::DB.CacheStorage)
    d = try JSON.parse(read(content_moderation_repo_file("recommended-blossom-servers.json"), String)) catch _; nothing end
    [(; kind=Int(RECOMMENDED_BLOSSOM_SERVERS), content=JSON.json(d))]
end

function muted_threads_feed(
        est::DB.CacheStorage;
        limit::Int=20, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing
    )
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    posts = Tuple{Nostr.EventId, Int}[]
    for r in p0"
        select es.id, es.created_at from replaceable_events re, basic_tags bt, events es
        where re.pubkey = $user_pubkey and re.kind = $(Int(Nostr.MUTE_LIST)) 
          and re.event_id = bt.id and bt.tag = 'e' and bt.arg1 = es.id 
          and es.created_at >= $since and es.created_at <= $until 
        order by es.created_at desc limit $limit offset $offset"
        push!(posts, (Nostr.EventId(r.id), r.created_at))
    end
    enrich_feed_events_pg(est; posts, user_pubkey)
end

function parse_follow_list(e::Nostr.Event)
    pks = Set{Nostr.PubKeyId}()
    for t in e.tags
        if length(t.fields) >= 2 && t.fields[1] == "p" && !isnothing(local pk = try Nostr.PubKeyId(t.fields[2]) catch _ end)
            push!(pks, pk)
        end
    end
    pks
end

function follow_lists(
        est::DB.CacheStorage;
        since=0, until=Utils.current_time(), 
        limit=5, offset=0,
    )
    limit = min(20, limit)

    es = []
    res = []

    pks = Set{Nostr.PubKeyId}()
    for r in p0"
        select es.* from parametrized_replaceable_events pre, events es 
        where pre.kind = 39089 and pre.created_at >= $since and pre.created_at <= $until and pre.event_id = es.id
          and not exists (select 1 from filterlist fl where fl.target = pre.pubkey and fl.target_type = 'pubkey' and fl.grp = 'spam' and fl.blocked)
        order by pre.created_at desc limit $limit offset $offset"
        e = event_from_row(collect(r))

        has_image = false
        for t in e.tags
            if length(t.fields) >= 2 && t.fields[1] == "image"
                has_image = true
                break
            end
        end
        has_image || continue

        push!(res, e)

        append!(res, map(castnamedtuple, p0"select * from event_media_response($(e.id))"))

        push!(es, (e.id, e.created_at))

        push!(pks, e.pubkey)

        pks_param = "{$(join(["\\\\x$(Nostr.hex(pk))" for pk in parse_follow_list(e)], ','))}"
        rs = p0"select key as pubkey, value as cnt from pubkey_followers_cnt where key = any ($(pks_param)::bytea[]) order by cnt desc limit 5"
        union!(pks, [r.pubkey for r in rs])
    end

    [res..., user_infos(est; pubkeys=collect(pks), usepgfuncs=true)..., range(es, :created_at)...]
end

function follow_list(
        est::DB.CacheStorage;
        pubkey, identifier::String,
    )
    pubkey = cast(pubkey, Nostr.PubKeyId)
    rs = p0"
    select es.* from parametrized_replaceable_events pre, events es 
    where pre.kind = 39089 and pre.pubkey = $pubkey and pre.identifier = $identifier and pre.event_id = es.id
    "
    isempty(rs) && error("no such follow list")
    e = event_from_row(collect(rs[1]))
    pks = parse_follow_list(e)
    [e, user_infos(est; pubkeys=collect(pks), usepgfuncs=true)...]
end

end
