#module App

using DataStructures: Accumulator, CircularBuffer
using Printf: @printf
import Base64
import SHA
import URIs
import HTTP

import ..Utils
using ..Utils: Throttle
import ..MetricsLogger
import ..Filterlist
import ..Media
import ..PushGatewayExporter
import ..Postgres

union!(exposed_functions, Set([
                     :explore_legend_counts,
                     :explore,
                         :explore_global_trending_24h,
                         :explore_global_mostzapped_4h,
                     :scored,
                     :scored_users,
                         :scored_users_24h,
                     :set_app_settings,
                     :get_app_settings,
                     :get_app_settings_2,
                     :get_default_app_settings,
                     :get_default_relays,
                     :get_recommended_users,
                     :get_suggested_users,
                     :get_app_releases,
                     :user_profile_scored_content,
                     :user_profile_scored_media_thumbnails,
                     :search,
                     :advanced_feed,
                     :relays,
                     :get_notifications,
                     :set_notifications_seen,
                     :get_notifications_seen,
                     :user_search,
                     :feed_directive,
                     :feed_directive_2,
                     :get_advanced_feeds,
                     :trending_hashtags,
                         :trending_hashtags_4h,
                         :trending_hashtags_7d,
                     :trending_images,
                         :trending_images_4h,
                     :upload,
                     :upload_chunk,
                     :upload_complete,
                     :upload_cancel,
                     :report_user,
                     :report_note,
                     :get_filterlist,
                     :check_filterlist,
                     :broadcast_reply,
                     :broadcast_events,
                     :trusted_users,
                     :note_mentions,
                     :note_mentions_count,
                    ]))

union!(exposed_async_functions, Set([
                                     :notifications, 
                                     :notification_counts, 
                                     :notification_counts_2, 
                                    ]))

EXPLORE_LEGEND_COUNTS=10_000_102
PRIMAL_SETTINGS=10_000_103
APP_SETTINGS=30_078
USER_SCORES=10_000_108
RELAYS=10_000_109
NOTIFICATION=10_000_110
NOTIFICATIONS_SEEN_UNTIL=10_000_111
NOTIFICATIONS_SUMMARY=10_000_112
MEDIA_MAPPING=10_000_114
HASHTAGS=10_000_116
MEDIA_METADATA=10_000_119
UPLOAD=10_000_120
UPLOADED=10_000_121
DEFAULT_RELAYS=10_000_124
FILTERLIST=10_000_126
LINK_METADATA=10_000_128
FILTERLISTED=10_000_130
RECOMMENDED_USERS=10_000_200
NOTIFICATIONS_SUMMARY_2=10_000_132
SUGGESTED_USERS=10_000_134
UPLOAD_CHUNK=10_000_135
APP_RELEASES=10_000_138
TRUSTED_USERS=10_000_140
NOTE_MENTIONS_COUNT=10_000_143
UPLOADED_2=10_000_142
EVENT_BROADCAST_RESPONSES=10_000_149
ADVANCED_FEEDS=10_000_150

# ------------------------------------------------------ #

periodics = [ ]

periodics_task = Ref{Any}(nothing)
periodics_exceptions = CircularBuffer(200) |> ThreadSafe

function run_periodics(est::DB.CacheStorage; use_threads=true)
    for (desc, f, throttle) in periodics
        try
            throttle() do
                MetricsLogger.log(r->(; desc, periodic=nameof(f))) do
                    if use_threads
                        fetch(Threads.@spawn Base.invokelatest(f, est))
                    else
                        Base.invokelatest(f, est)
                    end
                end
            end
        catch ex
            push!(periodics_exceptions, (time(), ex))
        end
    end
end

function start_periodics(est::DB.CacheStorage)
    periodics_task[] = errormonitor(@async while !isnothing(periodics_task[])
                                        Base.invokelatest(run_periodics, est)
                                        sleep(1)
                                    end)
    nothing
end

function stop_periodics(est::DB.CacheStorage)
    tsk = periodics_task[]
    periodics_task[] = nothing
    wait(tsk)
    nothing
end

# ------------------------------------------------------ #

struct CachedFunction
    f::Function
    period::Int
    result::Ref{Any}
    updated_at::Ref{Int}
    execution_time::Ref{Float64}
end
cached_functions = Dict{Symbol, CachedFunction}() |> ThreadSafe

function register_cache_function(funcname, f, period)
    cached_functions[funcname] = CachedFunction(f, period, nothing, 0, 0)

    filter!(p->p[1]!=funcname, periodics)

    push!(periodics, (funcname,
                      function (est)
                          lock(cached_functions) do cached_functions
                              cf = cached_functions[funcname]
                              cf.execution_time[] = @elapsed cf.result[] = f(est)
                              cf.updated_at[] = trunc(Int, time())
                          end
                      end,
                      Throttle(; period, t=0)))
end

function cached_functions_report()
    # for (k, cf) in collect(cached_functions)
    for (k, cf) in cached_functions.wrapped
        @printf "%30s  period: %7.3f(s)  age: %7.3f(s)  exetime: %7.3f(s)\n" k cf.period time()-cf.updated_at[] cf.execution_time[]
    end
end

macro cached(period, func)
    @assert func.head == :(=)

    funcname = func.args[1].args[1]
    funcargs = func.args[1].args[2:end]
    funcbody = func.args[2]
    expr = :(function ($(funcargs...),); $(funcbody); end)
    f = eval(expr)

    register_cache_function(funcname, f, period)

    Expr(func.head, func.args[1],
         :(lock(cached_functions) do cached_functions
               cf = cached_functions[$(QuoteNode(funcname))]
               isnothing(cf.result[]) && (cf.result[] = cf.f($(func.args[1].args[2])))
               cf.result[]
           end))
end

# ------------------------------------------------------ #

function followers(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)
    [Nostr.PubKeyId(pk)
     for (pk,) in DB.exe(est.pubkey_followers,
                         DB.@sql("select follower_pubkey from pubkey_followers where pubkey = ?1 limit 10000"),
                         pubkey)]
end

function inner_network(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)
    pks = Set(follows(est, pubkey))
    union!(pks, followers(est, pubkey))
    pks
end

function outer_network(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)
    pks = Set(follows(est, pubkey))
    for pk in copy(pks)
        union!(pks, follows(est, pk))
    end
    pks
end

function explore_legend_counts(est::DB.CacheStorage; pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)

    [(;
      kind=Int(EXPLORE_LEGEND_COUNTS),
      pubkey,
      content=JSON.json((;
                         your_follows=length(follows(est, pubkey)),
                         your_inner_network=length(inner_network(est, pubkey)),
                         your_outer_network=length(outer_network(est, pubkey)),
                         all_users=est.commons.stats[:users],
                        )))]
end

function scored_content(
        est::DB.CacheStorage;
        timeframe, pubkeys=[],
        limit::Int=20,
        created_after::Int=0,
        since::Union{Real, Nothing}=nothing,
        until::Union{Real, Nothing}=nothing,
        offset::Int=0,
        group_by_pubkey::Bool=false,
        user_pubkey=nothing,
        time_exceeded=()->false,
    )
    limit = min(50, limit)
    if timeframe != :popular
        created_after = max(trunc(Int, time()-24*3600), created_after)
    end
    if !isnothing(since); since = max(max(1, since), created_after); end
    # desc = timeframe == :latest ? string((; timeframe, lenpks=length(pubkeys), created_after, limit, since, until, user_pubkey)) : nothing

    MAX_LIMIT = 1000
    limit <= MAX_LIMIT || error("limit too big")
    timeframe = Symbol(timeframe)
    pubkeys = map(pk->pk isa Nostr.PubKeyId ? pk : Nostr.PubKeyId(pk), collect(pubkeys))

    # TODO probably `limit/256` (~1) sql query limit is enough to find `limit` posts in total

    field = 
    if     timeframe == :latest; :created_at
    elseif timeframe == :popular; :score
    elseif timeframe == :trending; :score24h
    elseif timeframe == :mostzapped; :satszapped
    else   error("unknown timeframe: $(timeframe)")
    end

    where_exprs = []
    wheres() = isempty(where_exprs) ? "" : "where " * join(where_exprs, " and ")

    # TODO optimization, to only use $field index, create new collection, if since is fixed to 24h delete rows older than 24h periodically
    created_after > 0 && push!(where_exprs, "$created_after <= created_at")
    # push!(where_exprs, "created_at <= $(trunc(Int, time()))") # future events are ignore during import

    (isnothing(since) || since == 0) || push!(where_exprs, "$since <= $field")
    isnothing(until) || push!(where_exprs, "$until >= $field")

    timeframe == :mostzapped && push!(where_exprs, "$field > 0")

    posts = [] |> ThreadSafe
    posts_filtered = Tuple{Nostr.EventId, Int}[]

    n = limit
    while true
        time_exceeded() && break
        n > MAX_LIMIT && break

        empty!(posts)
        if isempty(pubkeys)
            q_wheres = wheres()
            if group_by_pubkey
                q = "
                with a as (
                    select author_pubkey, max($field) as maxfield 
                    from event_stats 
                    where $field > 0 and $created_after <= created_at 
                    group by author_pubkey 
                    order by maxfield desc 
                    limit ?1 offset ?2
                ) 
                select a.author_pubkey, es.event_id, es.$field
                from a, event_stats es 
                where a.author_pubkey = es.author_pubkey and a.maxfield = es.$field
                "
            else
                # q = "with a as materialized (select author_pubkey, event_id, $field from event_stats $q_wheres) select * from a order by $field desc limit ?1 offset ?2"
                q = "select author_pubkey, event_id, $field from event_stats $q_wheres order by $field desc limit ?1 offset ?2"
            end
            # @show (q, (n, offset))
            pkseen = Set{Nostr.PubKeyId}()
            for (pk, eid, v) in DB.exec(est.event_stats, q, (n, offset))
                pk = Nostr.PubKeyId(pk)
                pk in pkseen && continue
                push!(pkseen, pk)
                push!(posts, (eid, v))
            end
        else # TODO optimize db query
            field_ = field
            push!(where_exprs, "author_pubkey = ?1")
            q_wheres = wheres()
            @threads for pk in pubkeys
                time_exceeded() && break
                append!(posts, map(Tuple, DB.exec(est.event_stats, "select event_id, $field_ from event_stats $q_wheres order by $field_ desc limit ?2 offset ?3", (pk, n, offset))))
            end
        end

        empty!(posts_filtered)
        for (eid, v) in posts.wrapped
            local eid = Nostr.EventId(eid)
            local pk = DB.exe(est.event_stats, DB.@sql("select event_id, author_pubkey from event_stats where event_id = ?1"), 
                              eid)[1][2] |> Nostr.PubKeyId
            if  pk in Filterlist.access_pubkey_unblocked ||
                !(pk in Filterlist.import_pubkey_blocked) && 
                !(pk in Filterlist.analytics_pubkey_blocked) && 
                !(eid in Filterlist.analytics_event_blocked) && 
                !(eid in est.deleted_events) &&
                !is_hidden(est, user_pubkey, :trending, pk) &&
                get(est.pubkey_followers_cnt, pk, 0) >= 5
                push!(posts_filtered, (eid, v))
            end
        end

        (length(posts) < n || length(posts_filtered) >= limit) && break
        n += n
    end

    posts = sort(posts_filtered; by=r->-r[2])[1:min(limit, length(posts_filtered))]

    eids = [eid for (eid, _) in posts]

    res = response_messages_for_posts(est, eids; user_pubkey)

    vcat(res, range(posts, field))
end

analytics_cache = Dict() |> ThreadSafe

function with_analytics_cache(body::Function, est::DB.CacheStorage, user_pubkey, scope, key)
    res = lock(analytics_cache) do analytics_cache
        haskey(analytics_cache, key) ? analytics_cache[key] : nothing
    end
    if isnothing(res)
        res = analytics_cache[key] = body()
    end
    [e for e in res if !((e.kind == Int(Nostr.TEXT_NOTE) || e.kind == Int(Nostr.SET_METADATA)) && is_hidden(est, user_pubkey, scope, e.pubkey))]
end

function explore_global_trending(est::DB.CacheStorage, hours::Int; user_pubkey=nothing)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    # with_analytics_cache(est, user_pubkey, :trending, (:explore_global_trending, (; hours))) do # FIXME
        explore(est; timeframe="trending", scope="global", limit=100, created_after=trunc(Int, time()-hours*3600), group_by_pubkey=true, user_pubkey)
    # end
end
function explore_global_trending_24h(est::DB.CacheStorage; user_pubkey=nothing)
    explore_global_trending(est, 24; user_pubkey)
end

function explore_global_mostzapped(est::DB.CacheStorage, hours::Int; user_pubkey=nothing)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    # with_analytics_cache(est, user_pubkey, :trending, (:explore_global_mostzapped, (; hours))) do # FIXME
        explore(est; timeframe="mostzapped", scope="global", limit=100, created_after=trunc(Int, time()-hours*3600), group_by_pubkey=true)
    # end
end
function explore_global_mostzapped_4h(est::DB.CacheStorage; user_pubkey=nothing)
    explore_global_mostzapped(est, 4; user_pubkey)
end

function explore(
        est::DB.CacheStorage;
        timeframe, scope,
        user_pubkey::Any=nothing,
        kwargs...)
    timeframe = Symbol(timeframe)
    scope = Symbol(scope)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    if     scope == :global
        scored_content(est; timeframe, user_pubkey, kwargs...)
    elseif scope == :network
        isnothing(user_pubkey) && return []
        scored_content(est; timeframe, user_pubkey, kwargs...)
        # scored_content(est; timeframe, pubkeys=outer_network(est, user_pubkey), user_pubkey, kwargs...)
    elseif scope == :tribe
        isnothing(user_pubkey) && return []
        scored_content(est; timeframe, pubkeys=inner_network(est, user_pubkey), user_pubkey, kwargs...)
    elseif scope == :follows
        isnothing(user_pubkey) && return []
        scored_content(est; timeframe, pubkeys=follows(est, user_pubkey), user_pubkey, kwargs...)
    else
        []
    end
end

function scored_users(est::DB.CacheStorage, hours::Int; user_pubkey=nothing)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    # with_analytics_cache(est, user_pubkey, :trending, (:scored_users, (; hours))) do # FIXME
        scored_users(est; limit=6*4, since=trunc(Int, time()-hours*3600), user_pubkey)
    # end
end
function scored_users_24h(est::DB.CacheStorage; user_pubkey=nothing)
    scored_users(est, 24; user_pubkey)
end

function scored(est::DB.CacheStorage; selector, user_pubkey=nothing)
    if     selector == "trending_24h"; explore_global_trending(est, 24; user_pubkey)
    elseif selector == "trending_12h"; explore_global_trending(est, 12; user_pubkey)
    elseif selector == "trending_4h";  explore_global_trending(est, 4; user_pubkey)
    elseif selector == "trending_1h";  explore_global_trending(est, 1; user_pubkey)
    elseif selector == "mostzapped_24h"; explore_global_mostzapped(est, 24; user_pubkey)
    elseif selector == "mostzapped_12h"; explore_global_mostzapped(est, 12; user_pubkey)
    elseif selector == "mostzapped_4h";  explore_global_mostzapped(est, 4; user_pubkey)
    elseif selector == "mostzapped_1h";  explore_global_mostzapped(est, 1; user_pubkey)
    else; []
    end
end

function scored_users(est::DB.CacheStorage; limit::Int=20, since::Int=0, user_pubkey=nothing)
    limit <= 1000 || error("limit too big")
    since >= time()-7*24*3600 || error("since too old")

    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    field = :score24h

    where_exprs = []
    wheres() = isempty(where_exprs) ? "" : "where " * join(where_exprs, " and ")

    push!(where_exprs, "$since <= created_at")
    # push!(where_exprs, "created_at <= $(trunc(Int, time()))") # future events are ignored during import

    pubkeys = [] |> ThreadSafe
    q_wheres = wheres()
    @threads for dbconn in est.event_stats.dbconns
        for r in DB.exe(dbconn, "select author_pubkey, max($field) as maxscore
                                 from event_stats
                                 $q_wheres
                                 group by author_pubkey
                                 order by maxscore desc limit ?1", (limit,))
            push!(pubkeys, (Nostr.PubKeyId(r[1]), r[2]))
        end
    end

    pubkeys_filtered = []
    for (pk, v) in pubkeys.wrapped
        if  pk in Filterlist.access_pubkey_unblocked || 
            !(pk in Filterlist.analytics_pubkey_blocked) && 
            !is_hidden(est, user_pubkey, :trending, pk) &&
            get(est.pubkey_followers_cnt, pk, 0) >= 5
            push!(pubkeys_filtered, (pk, v))
        end
    end

    pubkeys = sort(pubkeys_filtered; by=r->-r[2])[1:min(limit, length(pubkeys_filtered))]

    res = []
    for (pk, _) in pubkeys 
        if pk in est.meta_data && est.meta_data[pk] in est.events
            md = est.events[est.meta_data[pk]]
            push!(res, md)
            union!(res, ext_event_response(est, md))
        end
    end
    push!(res, (; kind=Int(USER_SCORES), content=JSON.json(Dict([(Nostr.hex(pk), v) for (pk, v) in pubkeys]))))

    res
end

function app_settings(body::Function, est::DB.CacheStorage, event_from_user::Dict)
    DB.PG_DISABLE[] && return []
    e = parse_event_from_user(event_from_user)
    e.kind == Int(APP_SETTINGS) || error("invalid event kind")
    est.auto_fetch_missing_events && DB.fetch_user_metadata(est, e.pubkey)
    try
        body(e)
    finally
        DB.exe(est.app_settings, DB.@sql("update app_settings set accessed_at = ?2 where key = ?1"),
               e.pubkey, trunc(Int, time()))
        DB.exe(est.app_settings_log, DB.@sql("insert into app_settings_log values (?1, ?2, ?3)"), 
               e.pubkey, e, trunc(Int, time()))
    end
end
    
function set_app_settings(est::DB.CacheStorage; settings_event::Dict)
    app_settings(est, settings_event) do e
        if e.pubkey in est.app_settings
            ee = est.app_settings[e.pubkey]
            d1 = JSON.parse(ee.content)
            d2 = JSON.parse(e.content)
            d3 = copy(d2)
            for (k, v) in d1
                haskey(d2, k) || (d2[k] = v)
            end
            if d2 != d3
                e = Nostr.Event(e.id, e.pubkey, e.created_at, e.kind, e.tags, JSON.json(d2), e.sig)
            end
        end
        est.app_settings[e.pubkey] = e
        DB.exe(est.app_settings, 
               DB.@sql("update app_settings set created_at = ?2, event_id = ?3 where key = ?1"),
               e.pubkey, e.created_at, e.id)
        parse_notification_settings(est, e)
        [e]
    end
end
    
function get_app_settings(est::DB.CacheStorage; event_from_user::Dict)
    app_settings(est, event_from_user) do e
        if e.pubkey in est.app_settings
            [est.app_settings[e.pubkey]]
        else
            ee = get_default_app_settings(est; client=event_from_user["tags"][1][2])[1]
            ee = (; ee..., id=join(["00" for _ in 1:32]), pubkey=join(["00" for _ in 1:32]), sig=join(["00" for _ in 1:64]), created_at=trunc(Int, time()))
            ee = Nostr.Event(JSON.parse(JSON.json(ee)))
            est.app_settings[e.pubkey] = ee
            [ee]
        end
    end
end

function get_app_settings_2(est::DB.CacheStorage; event_from_user::Dict)
    app_settings(est, event_from_user) do e
        if e.pubkey in est.app_settings
            [est.app_settings[e.pubkey]]
        else
            []
        end
    end
end

DEFAULT_SETTINGS_FILE = Ref("default-settings.json")

function get_default_app_settings(est::DB.CacheStorage; client::String="Primal-Web App")
    [(; kind=Int(PRIMAL_SETTINGS), 
      tags=[["d", client]],
      content=JSON.json(try JSON.parse(read(DEFAULT_SETTINGS_FILE[], String))
                        catch _; (;) end))]
end

DEFAULT_RELAYS_FILE = Ref("default-relays.json")

function get_default_relays(est::DB.CacheStorage)
    mined = [s for s in readlines("primal-server/relays-mined-from-contact-lists.txt") if !isempty(s)]
    mined_idxs = Set()
    while length(mined_idxs) < 4
        push!(mined_idxs, rand(1:length(mined)))
    end
    relays = [
              "wss://relay.primal.net",
              "wss://purplepag.es",
              rand([
                    "wss://relay.damus.io", 
                    "wss://nos.lol", 
                    "wss://relay.nostr.band", 
                    "wss://relayable.org",
                   ]),
              mined[collect(mined_idxs)]...
             ]
    [(; kind=Int(DEFAULT_RELAYS), content=JSON.json(relays))]
end

RECOMMENDED_USERS_FILE = Ref("recommended-users.json")

function get_recommended_users(est::DB.CacheStorage)
    isfile(RECOMMENDED_USERS_FILE[]) || return []

    res_meta_data = Set()
    for (pk, _) in JSON.parse(read(RECOMMENDED_USERS_FILE[], String))
        pk = Nostr.PubKeyId(pk)
        if pk in est.meta_data
            eid = est.meta_data[pk]
            if eid in est.events
                push!(res_meta_data, est.events[eid])
            end
        end
    end

    res = []
    res_meta_data = collect(values(res_meta_data))
    append!(res, res_meta_data)
    append!(res, user_scores(est, res_meta_data))
    res
end

SUGGESTED_USERS_FILE = Ref("suggested-accounts.json")

function get_suggested_users(est::DB.CacheStorage)
    isfile(SUGGESTED_USERS_FILE[]) || return []

    res_meta_data = Set()
    r = []
    for (group, users) in JSON.parse(read(SUGGESTED_USERS_FILE[], String))
        g = (; group, members=[])
        push!(r, g)
        for (pubkey, name) in users
            push!(g.members, ((; pubkey, name)))
            pk = Nostr.PubKeyId(pubkey)
            if pk in est.meta_data
                eid = est.meta_data[pk]
                if eid in est.events
                    push!(res_meta_data, est.events[eid])
                end
            end
        end
    end

    res = Any[(; kind=SUGGESTED_USERS, content=JSON.json(r))]
    res_meta_data = collect(values(res_meta_data))
    append!(res, res_meta_data)
    append!(res, user_scores(est, res_meta_data))
    res
end

APP_RELEASES_FILE = Ref("app-releases.json")

function get_app_releases(est::DB.CacheStorage)
    [(; kind=Int(APP_RELEASES), 
      content=JSON.json(try JSON.parse(read(APP_RELEASES_FILE[], String))
                        catch _; (;) end))]
end

ADVANCED_FEEDS_FILE = Ref("advanced-feeds.json")

function get_advanced_feeds(est::DB.CacheStorage)
    [(; kind=Int(ADVANCED_FEEDS), 
      content=JSON.json(try JSON.parse(read(ADVANCED_FEEDS_FILE[], String))
                        catch _; (;) end))]
end

function parse_notification_settings(est::DB.CacheStorage, e::Nostr.Event)
    d = JSON.parse(e.content)
    if haskey(d, "notifications")
        DB.exe(est.notification_settings, DB.@sql("delete from notification_settings where pubkey = ?1"),
               e.pubkey)
        for (k, v) in d["notifications"]
            DB.exe(est.notification_settings, DB.@sql("insert into notification_settings values (?1, ?2, ?3)"),
                   e.pubkey, k, v)
        end
    end
end

function user_profile_scored_content(est::DB.CacheStorage; pubkey, limit::Int=5, user_pubkey=nothing)
    limit = min(100, limit)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    eids = [Nostr.EventId(eid) 
            for (eid,) in DB.exec(est.event_stats,
                                  DB.@sql("select event_id from event_stats
                                          where author_pubkey = ?1 and score > 0
                                          order by score desc limit ?2"), (pubkey, limit))]
    res = Set() |> ThreadSafe

    for e in response_messages_for_posts(est, eids; user_pubkey)
        e.kind != 1 || e.pubkey == pubkey && push!(res, e)
    end

    pubkey in est.meta_data && push!(res, est.events[est.meta_data[pubkey]])

    collect(res)
end

function user_profile_scored_media_thumbnails(est::DB.CacheStorage; pubkey, limit::Int=5, user_pubkey=nothing)
    limit = min(100, limit)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    eids = Nostr.EventId[]

    if !isnothing(DAG_OUTPUTS_DB[])
        for (eid,) in Postgres.pex(:p1timelimit, "
            SELECT
                event_stats.event_id
            FROM
                prod.event_stats,
                prod.event_media
            WHERE 
                event_stats.author_pubkey = \$1 AND event_stats.event_id = event_media.event_id
            ORDER BY
                event_stats.score24h DESC
            LIMIT \$2
            ", [pubkey, limit])
            push!(eids, Nostr.EventId(eid))
        end
    end

    response_messages_for_posts(est, eids; user_pubkey)
end

function transform_search_query(query::String)
    inquotes = false
    inhashtag = false
    sout = ""
    for c in query
        if c == '"'
            if !inquotes
                inquotes = true
            else
                inquotes = false
            end
        end
        if c == '#' && !inquotes
            if !inhashtag
                inhashtag = true
                sout *= "\""
            end
        end
        if inhashtag && !(c in "#-" || 'a' <= c <= 'z' || 'A' <= c <= 'Z' || '0' <= c <= '9')
            inhashtag = false
            sout *= "\""
        end
        sout *= c
    end
    inhashtag && (sout *= "\"")
    sout
end

DAG_OUTPUTS = Ref{Any}(nothing) |> ThreadSafe

function search(est::DB.CacheStorage; kwargs...)
    JSON.parse(String(HTTP.request("GET", "http://192.168.12.7:14017/api", [], JSON.json(["search", kwargs])).body))
end
function search_(
        est::DB.CacheStorage; 
        query::String, 
        kind=nothing,
        limit::Int=20, since::Union{Nothing,Int}=0, until::Union{Nothing,Int}=nothing, offset::Int=0,
        user_pubkey=nothing,
    )
    limit = min(100, limit)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    isempty(query) && error("query is empty")
    if startswith(query, "feed: ")
        feed_id = split(query, ' ')[2]
        with_analytics_cache((Symbol("search_feed_$(feed_id)"), user_pubkey)) do
            if     feed_id == "trending_24h"; explore(est; timeframe=:popular, scope=:global, created_after=trunc(Int, time()-24*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "trending_12h"; explore(est; timeframe=:popular, scope=:global, created_after=trunc(Int, time()-12*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "trending_4h";  explore(est; timeframe=:popular, scope=:global, created_after=trunc(Int, time()-4*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "trending_1h";  explore(est; timeframe=:popular, scope=:global, created_after=trunc(Int, time()-1*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "mostzapped_24h"; explore(est; timeframe=:mostzapped, scope=:global, created_after=trunc(Int, time()-24*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "mostzapped_12h"; explore(est; timeframe=:mostzapped, scope=:global, created_after=trunc(Int, time()-12*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "mostzapped_4h";  explore(est; timeframe=:mostzapped, scope=:global, created_after=trunc(Int, time()-4*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "mostzapped_1h";  explore(est; timeframe=:mostzapped, scope=:global, created_after=trunc(Int, time()-1*3600), group_by_pubkey=true, user_pubkey)
            elseif feed_id == "media_sfw";  media_feed(est; category="sfw",  limit, since, until, offset, user_pubkey)
            elseif feed_id == "media_nsfw"; media_feed(est; category="nsfw", limit, since, until, offset, user_pubkey)
            else; error("unknown feed id")
            end
        end
    else
        occursin("lolicon", query) && return []
        eids = 
        # if 1==0
        #     query = query[1] == '!' ? query[2:end] : transform_search_query(query)
        #     if isnothing(until)
        #         until = DB.exec(Main.cache_storage_sqlite.event_contents, DB.@sql("select rowid from event_contents order by rowid desc limit 1"))[1][1]
        #     end
        #     res = DB.exec(Main.cache_storage_sqlite.event_contents, DB.@sql("select event_id, rowid from event_contents where rowid >= ?1 and rowid <= ?2 and content match ?3 order by rowid desc limit ?4 offset ?5"),
        #                   (since, until, query, limit, offset))
        #     res = sort(res; by=r->-r[2])
        #     [Nostr.EventId(eid) for (eid, _) in res]
        # else
        begin
            since = !isnothing(since) ? since : 0
            since = max(since, Utils.current_time() - 300*24*3600)
            until = !isnothing(until) ? until : Utils.current_time()
            res = Main.DAG.search(est, user_pubkey, query; outputs=DAG_OUTPUTS[], since, until, limit, offset, kind)[1]
            Nostr.EventId[eid for (eid, _) in res]
        end
        res = vcat(response_messages_for_posts(est, eids; user_pubkey), range(res, :created_at))
        display(Utils.counts([e.kind for e in res]))
        res
    end
end

ADVANCED_FEED_PROVIDER_HOST = Ref{Any}(nothing)

function advanced_feed(
        est::DB.CacheStorage;
        specification,
        kwargs...,
        # since=0, until=Utils.current_time(), limit::Int=20, offset::Int=0,
        # user_pubkey=nothing, kwargs...,
    )
    isnothing(ADVANCED_FEED_PROVIDER_HOST[]) || return JSON.parse(String(HTTP.request("GET", ADVANCED_FEED_PROVIDER_HOST[], [], JSON.json(["advanced_feed", (; specification, kwargs...)])).body))

    specargs() = NamedTuple([Symbol(k)=>v for (k, v) in (length(specification) >= 2 ? specification[2] : [])])

    upk() = :pubkey in keys(kwargs) ? NamedTuple(kwargs).pubkey : NamedTuple(kwargs).user_pubkey
    
    if isnothing(specification)
        []
    elseif specification[1] == "advanced_search"
        kwargs = NamedTuple(kwargs)
        limit = min(100, get(kwargs, :limit, 20))
        user_pubkey = castmaybe(get(kwargs, :user_pubkey, nothing), Nostr.PubKeyId)
        kwargs = NamedTuple([k=>v for (k, v) in pairs(kwargs) if k != :user_pubkey])
        res = []
        eids = Nostr.EventId[]
        query = specification[2]["query"]
        isempty(query) && error("query is empty")
        if !isnothing(DAG_OUTPUTS[])
            mod, outputs = DAG_OUTPUTS[]
            res, stats = Base.invokelatest(mod.search, est, user_pubkey, query; outputs, logextra=(; user_pubkey), kwargs...)
            eids = [eid for (eid, created_at) in res]
        end
        vcat(response_messages_for_posts(est, eids; user_pubkey), range(res, :created_at))
    elseif specification[1] == "feed"
        feed(est; specargs()..., kwargs..., pubkey=upk())
    elseif specification[1] == "global-trending"
        explore(est; timeframe="trending", scope="global", created_after=trunc(Int, time()-specargs().timeperiod_h*3600), kwargs...)
    elseif specification[1] == "trending-in-my-network"
        explore(est; timeframe="trending", scope="follows", created_after=trunc(Int, time()-specargs().timeperiod_h*3600), kwargs...)
    elseif specification[1] == "most-zapped"
        explore(est; timeframe="mostzapped", scope="global", created_after=trunc(Int, time()-specargs().timeperiod_h*3600), kwargs...)
    elseif specification == "hall-of-fame-notes"
        explore(est; timeframe="trending", scope="global", created_after=0, kwargs...)
    elseif specification == "wide-net-notes"
        wide_net_notes_feed(est; created_after=Utils.current_time()-24*3600, kwargs..., pubkey=upk())
    elseif specification == "wide-net-notes-by-interactions"
        wide_net_notes_scored_feed(est; created_after=Utils.current_time()-24*3600, kwargs..., pubkey=upk())
    else
        []
    end
end

postgres_query_log = CircularBuffer(100000) |> ThreadSafe
function pex(s, query, params=[]; noresults=false)
    tdur = @elapsed explained = Postgres.execute(s, "explain (analyze,buffers) "*query, params)
    push!(postgres_query_log, (; t=time(), query, params, tdur, explained))
    noresults ? nothing : Postgres.execute(s, query, params)[2]
end

function wide_net_notes_feed(
        est::DB.CacheStorage;
        created_after::Int,
        pubkey,
        limit=20, offset=0, since=0, until=Utils.current_time(),
        user_pubkey=nothing,
    )
    limit=500
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    posts = []

    Postgres.transaction(:p1) do session
        Postgres.execute(session, "create temp table pks (pubkey bytea primary key not null) on commit drop")
        for pk in follows(est, pubkey)
            Postgres.execute(session, "insert into pks values (\$1)", [pk])
        end
        for (eid, created_at) in pex(session, "
                select 
                    es.id, es.created_at
                from 
                    pks,
                    basic_tags bt1, 
                    basic_tags bt2, 
                    events es 
                where 
                  (bt1.kind = $(Int(Nostr.TEXT_NOTE)) or bt1.kind = $(Int(Nostr.REPOST)) or bt1.kind = $(Int(Nostr.REACTION)) or bt1.kind = $(Int(Nostr.ZAP_RECEIPT))) and 
                  bt1.pubkey = pks.pubkey and
                  bt1.id = bt2.id and bt2.tag = 'e' and
                  bt2.arg1 = es.id and es.created_at >= \$1 and es.created_at <= \$2
                order by es.created_at desc
                limit \$3 offset \$4
                ", [since, until, limit, offset])
            push!(posts, (Nostr.EventId(eid), created_at))
        end
    end

    eids = collect(map(first, posts))

    vcat(response_messages_for_posts(est, eids; user_pubkey), range(posts, :created_at))
end

function wide_net_notes_scored_feed(
        est::DB.CacheStorage;
        created_after::Int,
        pubkey,
        user_pubkey=nothing,
        limit=200,
    )
    limit = 200
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    notes = Dict()

    function interaction(body::Function, eid::Nostr.EventId)
        if eid in est.events
            e = est.events[eid]
            body(get!(notes, e.id) do
                     (; e.created_at, interactions=Ref(0))
                 end)
        end
    end

    Postgres.transaction(:p1) do session
        Postgres.execute(session, "create temp table pks (pubkey bytea primary key not null) on commit drop")
        for pk in follows(est, pubkey)
            Postgres.execute(session, "insert into pks values (\$1)", [pk])
        end
        # @show Postgres.execute(session, "select count(1) from pks")[2]
        pex(session, "
                create temp table eids on commit drop as (
                select id
                from basic_tags, pks
                where 
                  created_at >= \$1 and 
                  (kind = $(Int(Nostr.TEXT_NOTE)) or kind = $(Int(Nostr.REPOST)) or kind = $(Int(Nostr.REACTION)) or kind = $(Int(Nostr.ZAP_RECEIPT))) and 
                  tag = 'p' and arg1 = pks.pubkey
                order by created_at asc
                )", [created_after]; noresults=true)
        # @show Postgres.execute(session, "select count(1) from eids")[2]
        for r in pex(session, "
                select events.*
                from events, eids
                where eids.id  = events.id
                ")
            e = event_from_row(r)
            for t in e.tags
                if length(t.fields) >= 2 && t.fields[1] == "e" && !isnothing(local eid = try Nostr.EventId(t.fields[2]) catch _ end)
                    interaction(eid) do n
                        n.interactions[] += 1
                    end
                end
            end
        end
    end

    eids = [eid for (eid, _) in first(sort(collect(notes); by=x->-x[2].interactions[]), limit)]

    response_messages_for_posts(est, eids; user_pubkey)
end

function relays(est::DB.CacheStorage; limit::Int=20)
    res = DB.exec(est.relays, DB.@sql("select url, times_referenced from relays order by times_referenced desc limit ?1"), (limit,))
    res = res[1:min(limit, length(res))]
    [(; kind=Int(RELAYS), content=JSON.json(Dict(res)))]
end

function get_notifications(
        est::DB.CacheStorage;
        pubkey,
        limit::Int=1000, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing,
        type=nothing, type_group=nothing,
        time_exceeded=()->false,
    )
    # limit <= 1000 || error("limit too big")
    limit = min(limit, 1000) # iOS app was requesting limit=~13000
    limit = min(limit, 100)

    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    type_group = castmaybe(type_group, Symbol)

    if     type_group == :all; nothing
    elseif type_group == :zaps; type = [
                                        DB.YOUR_POST_WAS_ZAPPED,
                                       ]
    elseif type_group == :replies; type = [
                                           DB.YOUR_POST_WAS_REPLIED_TO,
                                          ]
    elseif type_group == :mentions; type = [
                                            DB.YOU_WERE_MENTIONED_IN_POST,
                                            DB.YOUR_POST_WAS_MENTIONED_IN_POST,
                                           ]
    elseif type_group == :reposts; type = [
                                           DB.YOUR_POST_WAS_REPOSTED,
                                          ]
    end

    res = []
    res_meta_data = Dict()

    pks = Set{Nostr.PubKeyId}()
    eids = Set{Nostr.EventId}()

    rs = if isnothing(type)
        DB.exe(est.pubkey_notifications, 
               DB.@sql("select pubkey, created_at, type, arg1, arg2, arg3, arg4
                       from pubkey_notifications 
                       where pubkey = ?1 and created_at >= ?2 and created_at <= ?3
                       order by created_at desc limit ?4 offset ?5"),
               pubkey, since, until, limit, offset)
    else
        if !(type isa Vector)
            type = [type]
        end
        type = join([Int(t) for t in type], ",")
        DB.exe(est.pubkey_notifications, 
               "select pubkey, created_at, type, arg1, arg2, arg3, arg4
               from pubkey_notifications 
               where pubkey = ?1 and created_at >= ?2 and created_at <= ?3
               and type in ($type)
               order by created_at desc limit ?4 offset ?5",
               pubkey, since, until, limit, offset)
    end
    for r in rs
        (_, created_at, type, arg1, arg2, arg3, arg4) = r

        notif_d = DB.notif2namedtuple((pubkey, created_at, DB.NotificationType(type),
                                       arg1, arg2, arg3, arg4))

        if notif_d.type == DB.USER_UNFOLLOWED_YOU
            if !isempty(DB.exe(est.pubkey_followers, DB.@sql("select 1 from pubkey_followers where pubkey = ?1 and follower_pubkey = ?2 limit 1"),
                               pubkey, notif_d.follower))
                continue
            end
        end

        is_blocked = false

        for arg in collect(values(notif_d))
            if arg isa Nostr.PubKeyId
                pk = arg
                if is_hidden(est, user_pubkey, :content, pk) || ext_is_hidden(est, pk)
                    is_blocked = true
                else
                    push!(pks, pk)
                    if !haskey(res_meta_data, pk) && pk in est.meta_data && est.meta_data[pk] in est.events
                        res_meta_data[pk] = est.events[est.meta_data[pk]]
                    end
                end
            elseif arg isa Nostr.EventId
                eid = arg
                if is_hidden(est, user_pubkey, :content, eid) || ext_is_hidden(est, eid)
                    is_blocked = true
                else
                    push!(eids, eid)
                end
            end
        end

        if !is_blocked
            push!(res, (; kind=Int(NOTIFICATION), content=JSON.json(notif_d)))
        # else
        #     args = [a for a in r[4:end] if !ismissing(a)]
        #     wheres = join(["arg$i = ?" for (i, a) in enumerate(args)], " and ")
        #     wheres = isempty(wheres) ? "" : ("and " * wheres)
        #     DB.exe(est.pubkey_notifications, 
        #            "delete from pubkey_notifications where pubkey = ? and created_at = ? and type = ? $wheres",
        #            pubkey, created_at, type, args...)
        #     DB.exe(est.pubkey_notification_cnts,
        #            "update pubkey_notification_cnts set type$(type) = type$(type) - 1 where pubkey = ?1",
        #            pubkey)
        end
    end

    res = collect(Set(res)) # remove duplicates ??

    for pk in pks
        push!(res, (;
                    kind=Int(USER_PROFILE),
                    content=JSON.json((;
                                       pubkey=pk,
                                       followers_count=get(est.pubkey_followers_cnt, pk, 0),
                                      ))))
    end

    append!(res, response_messages_for_posts(est, collect(eids); res_meta_data, user_pubkey, time_exceeded))

    res
end

function set_notifications_seen(
        est::DB.CacheStorage;
        event_from_user::Dict,
        replicated=false
    )
    replicated || replicate_request(:set_notifications_seen; event_from_user)

    e = parse_event_from_user(event_from_user)

    est.pubkey_notifications_seen[e.pubkey] = e.created_at

    DB.exe(est.pubkey_notification_cnts,
           "update pubkey_notification_cnts set $(join(["type$(i|>Int) = 0" for i in instances(DB.NotificationType)], ", ")) where pubkey = ?1",
           e.pubkey)

    []
end

function get_notifications_seen(est::DB.CacheStorage; pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    if pubkey in est.pubkey_notifications_seen
        [(; kind=Int(NOTIFICATIONS_SEEN_UNTIL),
          content=JSON.json(est.pubkey_notifications_seen[pubkey]))] 
    else
        []
    end
end

function get_notification_counts(est::DB.CacheStorage; pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    [(; kind=Int(NOTIFICATIONS_SUMMARY), pubkey=Nostr.PubKeyId(pk),
      [Symbol(string(Int(i)))=>cnt
       for (i, cnt) in zip(instances(DB.NotificationType), cnts)]...)
     for (pk, cnts...) in DB.exe(est.pubkey_notification_cnts,
                                 "select * from pubkey_notification_cnts where pubkey = ?1", pubkey)]
end

function get_notification_counts_2(est::DB.CacheStorage; pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    [(; kind=Int(NOTIFICATIONS_SUMMARY_2), pubkey=Nostr.PubKeyId(pk),
      content=JSON.json(Dict([Symbol(string(Int(i)))=>cnt
                              for (i, cnt) in zip(instances(DB.NotificationType), cnts)])))
     for (pk, cnts...) in DB.exe(est.pubkey_notification_cnts,
                                 "select * from pubkey_notification_cnts where pubkey = ?1", pubkey)]
end

# function user_search(est::DB.CacheStorage; kwargs...)
#     JSON.parse(String(HTTP.request("GET", "http://192.168.17.7:14017/api", [], JSON.json(["user_search", kwargs])).body))
# end
function user_search(est::DB.CacheStorage; query::String, limit::Int=10, pubkey::Any=nothing)
    # @show (query, limit, pubkey)
    limit = min(100, limit)
    limit <= 1000 || error("limit too big")
    
    occursin("lolicon", query) && return []

    q = "^" * repr(query) * "*"

    res = Dict()

    if !isnothing(local pk = try Nostr.bech32_decode(query) catch _ nothing end)
        res[pk] = est.pubkey_followers_cnt[pk]
    elseif isnothing(pubkey)
        for (pk,) in DB.exec(est.dyn[:user_search],
                             DB.@sql("select pubkey from user_search where
                                     name @@ plainto_tsquery('simple', ?1) or
                                     username @@ plainto_tsquery('simple', ?2) or
                                     display_name @@ plainto_tsquery('simple', ?3) or
                                     displayName @@ plainto_tsquery('simple', ?4) or
                                     nip05 @@ plainto_tsquery('simple', ?5)
                                     "),
                             (q, q, q, q, q))
            pk = Nostr.PubKeyId(pk)
            res[pk] = est.pubkey_followers_cnt[pk]
        end
    else
        pubkey = cast(pubkey, Nostr.PubKeyId)
        if isempty(query)
            for pk in follows(est, pubkey)
                res[pk] = est.pubkey_followers_cnt[pk]
            end
        else
            for (pk,) in DB.exec(est.dyn[:user_search],
                                 DB.@sql("select us.pubkey 
                                         from user_search us, pubkey_followers pf
                                         where
                                             pf.follower_pubkey = ?1 and pf.pubkey = us.pubkey and
                                             (
                                                us.name @@ plainto_tsquery('simple', ?2) or
                                                us.display_name @@ plainto_tsquery('simple', ?3) or
                                                us.nip05 @@ plainto_tsquery('simple', ?4)
                                             )
                                         "),
                                 (pubkey, q, q, q))
                pk = Nostr.PubKeyId(pk)
                res[pk] = est.pubkey_followers_cnt[pk]
            end
        end
    end
    
    res_meta_data = OrderedSet()

    for (pk, _) in sort(collect(res); by=r->-r[2])[1:min(limit, length(res))]
        if pk in est.meta_data
            eid = est.meta_data[pk]
            if eid in est.events
                push!(res_meta_data, est.events[eid])
            end
        end
    end

    res = []
    res_meta_data = collect(values(res_meta_data))
    append!(res, res_meta_data)
    append!(res, user_scores(est, res_meta_data))
    res
end

function ext_user_infos(est::DB.CacheStorage, res, res_meta_data)
    for md in res_meta_data
        push!(res, md)
        union!(res, ext_event_response(est, md))
    end
end

feed_directive(est::DB.CacheStorage; kwargs...) = feed_directive_(est, feed; kwargs...)
feed_directive_2(est::DB.CacheStorage; kwargs...) = feed_directive_(est, feed_2; kwargs...)

function feed_directive_(est::DB.CacheStorage, feed; directive::String, kwargs...)
    if !isnothing(local pk = try Nostr.PubKeyId(directive) catch _ end)
        return feed(est; pubkey=pk, kwargs...)

    elseif !isnothing(match(r"^search;", directive))
        parts = split(directive, ';')
        if length(parts) == 2
            return search(est; query=string(parts[2]), kwargs...)
        end

    elseif directive == "global;trending"
        return explore(est; scope="global", timeframe="trending", created_after=trunc(Int, time()-24*3600), kwargs...)

    elseif directive == "global;mostzapped4h"
        return explore(est; scope="global", timeframe="mostzapped", created_after=trunc(Int, time()-4*3600), kwargs...)

    elseif !isnothing(match(r"^[a-zA-Z]+;[a-zA-Z0-9]+$", directive))
        parts = split(directive, ';')
        if length(parts) == 2
            if parts[1] == "authored"
                pk = Nostr.PubKeyId(string(parts[2]))
                return feed(est; pubkey=pk, notes=:authored, kwargs...)
            elseif parts[1] == "authoredreplies"
                pk = Nostr.PubKeyId(string(parts[2]))
                return feed(est; pubkey=pk, notes=:replies, kwargs...)
            elseif parts[1] == "withreplies"
                pk = Nostr.PubKeyId(string(parts[2]))
                return feed(est; pubkey=pk, include_replies=true, kwargs...)
            elseif parts[1] == "bookmarks"
                pk = Nostr.PubKeyId(string(parts[2]))
                return feed(est; pubkey=pk, notes=:bookmarks, kwargs...)
            else
                for ps in [(parts[1], parts[2]),
                           (parts[2], parts[1])]
                    res = try explore(est; timeframe=string(ps[1]), scope=string(ps[2]), created_after=trunc(Int, time()-24*3600), kwargs...) catch _; []; end
                    isempty(res) || return res
                end
            end
        end

    end

    d = JSON.parse(directive)
    funcall = Symbol(d[1])
    args = Dict{Symbol,Any}([Symbol(k)=>v for (k,v) in d[2]])
    merge!(args, kwargs)
    funcall in exposed_functions || error("unsupported request $(funcall)")
    eval(funcall)(est; args...)
end

ext_is_hidden(est::DB.CacheStorage, eid::Nostr.EventId) = Filterlist.is_hidden(eid)
ext_is_hidden(est::DB.CacheStorage, pubkey::Nostr.PubKeyId) = Filterlist.is_hidden(pubkey)

parsed_nsfw_mutelist = Dict{Nostr.EventId, Set{Nostr.PubKeyId}}()

ALGOS_USER = Ref{Any}(nothing)

function is_hidden_on_primal_nsfw(est::DB.CacheStorage, user_pubkey, scope::Symbol, pubkey::Nostr.PubKeyId)
    isnothing(ALGOS_USER[]) && return false
    cmr = compile_content_moderation_rules(est, user_pubkey)
    if ALGOS_USER[].pk in est.mute_list
        eid = est.mute_list[ALGOS_USER[].pk]
        if pubkey in get!(parsed_nsfw_mutelist, eid) do
                pks = Set{Nostr.PubKeyId}()
                for tag in est.events[eid].tags
                    if length(tag.fields) >= 2 && tag.fields[1] == "p" && !isnothing(local pk = try Nostr.PubKeyId(tag.fields[2]) catch _ end)
                        push!(pks, pk)
                    end
                end
                pks
            end
            if haskey(cmr.groups, :primal_nsfw)
                scopes = cmr.groups[:primal_nsfw].scopes
                return (isempty(scopes) ? true : scope in scopes)
            else
                return false
            end
        end
    end
    false
end

function ext_is_hidden_by_group(est::DB.CacheStorage, cmr::NamedTuple, user_pubkey, scope::Symbol, pubkey::Nostr.PubKeyId)
    if haskey(cmr.groups, :primal_spam) && pubkey in Filterlist.access_pubkey_blocked_spam && !(pubkey in Filterlist.access_pubkey_unblocked_spam)
        scopes = cmr.groups[:primal_spam].scopes
        return (isempty(scopes) ? true : scope in scopes)
    end
    # if haskey(cmr.groups, :primal_nsfw) && is_hidden_on_primal_nsfw(est, user_pubkey, scope, pubkey)
    if haskey(cmr.groups, :primal_nsfw) && pubkey in Filterlist.access_pubkey_blocked_nsfw && !(pubkey in Filterlist.access_pubkey_unblocked_nsfw)
        scopes = cmr.groups[:primal_nsfw].scopes
        return (isempty(scopes) ? true : scope in scopes)
    end
    false
end

function ext_is_hidden_by_group(est::DB.CacheStorage, cmr::NamedTuple, user_pubkey, scope::Symbol, eid::Nostr.EventId)
    eid in est.events && ext_is_hidden_by_group(est, cmr, user_pubkey, scope, est.events[eid].pubkey) && return true
    # cmr = compile_content_moderation_rules(est, user_pubkey)
    # if haskey(cmr.groups, :primal_nsfw)
    #     scopes = cmr.groups[:primal_nsfw].scopes
    #     for (url,) in DB.exe(est.event_media, DB.@sql("select url from event_media where event_id = ?1"), eid)
    #         for (category, category_confidence) in DB.exec(est.media, DB.@sql("select category, category_confidence from media where url = ?1 limit 1"), (url,))
    #             category == "nsfw" && category_confidence >= 0.8 && return (isempty(scopes) ? true : scope in scopes)
    #         end
    #     end
    # end
    false
end

function ext_event_response(est::DB.CacheStorage, e::Nostr.Event)
    [event_media_response(est, e.id); event_preview_response(est, e.id)]
end

function event_media_response(est::DB.CacheStorage, eid::Nostr.EventId)
    resources = []
    root_mt = nothing
    thumbnails = Dict()
    for (url,) in DB.exe(est.event_media, DB.@sql("select url from event_media where event_id = ?1"), eid)
        variants = []
        for (s, a, w, h, mt, dur) in DB.exec(est.media, DB.@sql("select size, animated, width, height, mimetype, duration from media where url = ?1"), (url,))
            push!(variants, (; s=s[1], a, w, h, mt, dur, media_url=Media.cdn_url(url, s, a)))
            root_mt = mt
        end
        push!(resources, (; url, variants, (isnothing(root_mt) ? [] : [:mt=>root_mt])...))
        for (thumbnail_url,) in DB.exec(est.dyn[:video_thumbnails], DB.@sql("select thumbnail_url from video_thumbnails where video_url = ?1"), (url,))
            thumbnails[url] = thumbnail_url
        end
    end

    res = Dict()
    if !isempty(resources); res[:resources] = resources; end
    if !isempty(thumbnails); res[:thumbnails] = thumbnails; end
    if !isempty(res); res[:event_id] = eid; end
    isempty(res) ? [] : [(; kind=Int(MEDIA_METADATA), content=JSON.json(res))]
end

function event_preview_response(est::DB.CacheStorage, eid::Nostr.EventId)
    resources = []
    for (url,) in DB.exe(est.event_preview, DB.@sql("select url from event_preview where event_id = ?1"), eid)
        for (mimetype, md_title, md_description, md_image, icon_url) in 
            DB.exec(est.preview, DB.@sql("select mimetype, md_title, md_description, md_image, icon_url from preview where url = ?1"), (url,))
            push!(resources, (; url, mimetype, md_title, md_description, md_image, icon_url))
        end
    end
    isempty(resources) ? [] : [(; kind=Int(LINK_METADATA), content=JSON.json((; event_id=eid, resources)))]
end

periodic_hashtag_lists = Utils.Throttle(; period=5.0, t=0.0)
hashtag_whitelist = Set{String}()
hashtag_filterlist = Set{String}()

HASHTAG_WHITELIST = Ref("hashtag-whitelist.txt")
HASHTAG_FILTERLIST = Ref("hashtag-filterlist.txt")

function update_hashtag_lists()
    periodic_hashtag_lists() do
        empty!(hashtag_whitelist)
        isfile(HASHTAG_WHITELIST[]) && for s in readlines(HASHTAG_WHITELIST[])
            startswith(s, "-----") && break
            ht = split(s)[1][30:end]
            push!(hashtag_whitelist, ht)
        end

        empty!(hashtag_filterlist)
        isfile(HASHTAG_FILTERLIST[]) && for s in readlines(HASHTAG_FILTERLIST[])
            isempty(s) || push!(hashtag_filterlist, s)
        end
    end
end

function trending_hashtags(est::DB.CacheStorage; created_after::Int=trunc(Int, time()-7*24*3600), curated=true)
    # limit = min(500, limit)
    # res = []
    # for (ht, cnt) in DB.exec(est.event_hashtags, DB.@sql("select lower(hashtag), count(1) as cnt from event_hashtags where created_at >= ?1 group by lower(hashtag) order by cnt desc"), (created_after,))
    #     ht in hashtag_whitelist && push!(res, (ht, cnt))
    # end
    update_hashtag_lists()
    hts = Accumulator{String, Float32}()
    eid2pk = Dict{Nostr.EventId, Nostr.PubKeyId}()
    eid2followers = Dict{Nostr.PubKeyId, Int}()
    for (i, (eid, ht)) in enumerate(DB.exec(est.event_hashtags, DB.@sql("select event_id, hashtag from event_hashtags where created_at >= ?1 order by created_at asc"), (created_after,)))
        yield()
        curated && (ht in hashtag_whitelist || continue)
        # curated && (ht in hashtag_filterlist && continue)
        eid = Nostr.EventId(eid)
        if eid in est.events
            pk = get!(eid2pk, eid) do; est.events[eid].pubkey end
            nposts = get!(eid2followers, pk) do; DB.exe(est.pubkey_events, DB.@sql("select count(1) from pubkey_events where pubkey = ?1"), pk)[1][1] end
            user_score = est.pubkey_followers_cnt[pk] / nposts
            hts[ht] += user_score
        end
    end
    res = sort(collect(hts); by=r->-r[2])
    [(; kind=Int(HASHTAGS), content=JSON.json(res))]
end

@cached 600 trending_hashtags_4h(est::DB.CacheStorage) = trending_hashtags(est; created_after=trunc(Int, time()-4*3600))
@cached 600 trending_hashtags_7d(est::DB.CacheStorage) = trending_hashtags(est; created_after=trunc(Int, time()-2*24*3600)) # !! 7d->2d

# trending_hashtags_4h(est::DB.CacheStorage) = trending_hashtags(est; created_after=trunc(Int, time()-4*3600))
# trending_hashtags_7d(est::DB.CacheStorage) = trending_hashtags(est; created_after=trunc(Int, time()-2*24*3600)) # !! 7d->2d

function trending_images(est::DB.CacheStorage; created_after::Int=trunc(Int, time()-4*3600), limit=20)
    update_hashtag_lists()
    res = []
    stats = Dict()
    eids = Set()
    for r in explore(est; timeframe=:trending, scope=:global, created_after, limit)
        yield()
        if r.kind == Int(Nostr.TEXT_NOTE)
            eid = cast(r.id, Nostr.EventId)
            e = est.events[eid]
            ok = Ref(true)
            DB.for_hashtags(est, e) do hashtag
                hashtag in hashtag_whitelist || (ok[] = false)
            end
            ok[] || continue
            mr = event_media_response(est, eid)
            if !isempty(mr)
                pk = cast(r.pubkey, Nostr.PubKeyId)
                nposts = DB.exe(est.pubkey_events, DB.@sql("select count(1) from pubkey_events where pubkey = ?1"), pk)[1][1]
                user_score = est.pubkey_followers_cnt[pk] / nposts
                score = DB.exe(est.event_stats, DB.@sql("select score24h from event_stats where event_id = ?1"), eid)[1][1]
                for mr1 in mr
                    push!(res, (mr1, score*user_score))
                end
                push!(eids, eid)
            end
        elseif r.kind == Int(EVENT_STATS)
            stats[Nostr.EventId(JSON.parse(r.content)["event_id"])] = r
        end
    end
    res = sort(res; by=r->-r[2])
    [[e for (e, _) in res]..., [stats[eid] for eid in eids if haskey(stats, eid)]...]
end

function media_feed(est::DB.CacheStorage; category="", since=0, until=nothing, limit=20, offset=0, user_pubkey=nothing)
    limit <= 1000 || error("limit too big")
    isnothing(until) && (until = 1<<60)
    posts = []
    for (eid, url, rowid) in DB.exec(est.event_media, DB.@sql("select event_id, url, rowid from event_media
                                                              where rowid >= ?1 and rowid <= ?2
                                                              order by rowid desc limit ?3 offset ?4"),
                                     (since, until, limit, offset))
        eid = Nostr.EventId(eid)
        for (cat, cat_prob) in DB.exec(est.media, DB.@sql("select category, category_confidence from media where url = ?1 limit 1"), (url,))
            cat == category && push!(posts, (eid, rowid))
            break
        end
    end
    posts = first(sort(posts, by=p->-p[2]), limit)

    eids = [eid for (eid, _) in posts]
    res = response_messages_for_posts(est, eids; user_pubkey)

    vcat(res, range(posts, :rowid))
end

@cached 600 trending_images_4h(est::DB.CacheStorage) = trending_images(est; created_after=trunc(Int, time()-4*3600), limit=500)

UPLOADS_DIR = Ref(:uploads)
MEDIA_URL_ROOT = Ref("https://media.primal.net/uploads")
URL_SHORTENING_SERVICE = Ref("http://127.0.0.1:14001/url-shortening?u=")
MEDIA_UPLOAD_PATH = Ref("incoming")

categorized_uploads = Ref{Any}(nothing)

function import_upload_2(est::DB.CacheStorage, pubkey::Nostr.PubKeyId, data::Vector{UInt8})
    if !isempty(DB.exec(categorized_uploads[], "select 1 from categorized_uploads where sha256 = ?1 and type = 'blocked' limit 1", (SHA.sha256(data),)))
        error("blocked content")
    end

    data = Media.strip_metadata(data)

    sha256 = SHA.sha256(data)
    key = (; type="member_upload", pubkey, sha256=bytes2hex(sha256))

    new_import = Ref(false)
    (mi, lnk) = Media.media_import(function (_)
                                       new_import[] = true
                                       data
                                   end, key; media_path=UPLOADS_DIR[])

    if new_import[]
        if isempty(DB.exec(Main.InternalServices.memberships[], "select 1 from memberships where pubkey = ?1 limit 1", (pubkey,)))
            tier = isempty(DB.exec(Main.InternalServices.verified_users[], "select 1 from verified_users where pubkey = ?1 limit 1", (pubkey,))) ? "free" : "premium"
            DB.exec(Main.InternalServices.memberships[], "insert into memberships values (?1, ?2, ?3, ?4, ?5)", (pubkey, tier, missing, missing, 0))
        end
        tier, used_storage = DB.exec(Main.InternalServices.memberships[], "select tier, used_storage from memberships where pubkey = ?1", (pubkey,))[1]
        max_storage, = DB.exec(Main.InternalServices.membership_tiers[], "select max_storage from membership_tiers where tier = ?1", (tier,))[1]

        used_storage += length(data)
        if used_storage > max_storage
            @show (:insufficient_storage, pubkey)
            error("insufficient storage available")
            rm(mi.path)
        end

        DB.exec(Main.InternalServices.memberships[], "update memberships set used_storage = ?2 where pubkey = ?1",
                (pubkey, used_storage))

        try
            _, ext = splitext(lnk)
            path = "/uploads/$(mi.subdir)/$(mi.h)$(ext)"
            DB.ext_media_import(est, nothing, nothing, path, data)
        catch ex
            #println(ex)
            Utils.print_exceptions()
        end
    end

    _, ext = splitext(lnk)
    url = "$(MEDIA_URL_ROOT[])/$(mi.subdir)/$(mi.h)$(ext)"

    wh = Media.parse_image_dimensions(data)
    width, height = isnothing(wh) ? (0, 0) : wh
    mimetype = Media.parse_mimetype(data)

    if isempty(DB.exe(est.media_uploads, DB.@sql("select 1 from media_uploads where pubkey = ?1 and key = ?2 limit 1"), pubkey, JSON.json(key)))
        DB.exe(est.media_uploads, DB.@sql("insert into media_uploads values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)"), 
               pubkey,
               key.type, JSON.json(key),
               trunc(Int, time()),
               string(URIs.parse_uri(url).path),
               stat(mi.path).size, 
               mimetype,
               "", 1.0, 
               width, height,
               0.0,
               sha256)
    end

    # surl = String(HTTP.get("$(URL_SHORTENING_SERVICE[])$(URIs.escapeuri(url))").body)
    surl = Main.InternalServices.url_shortening(url)

    if splitext(surl)[2] in [".jpg", ".png", ".gif"]
        r = Media.media_variants(est, surl, Media.all_variants; sync=true, proxy=nothing)
        # @sync for ((size, anim), media_url) in r
        #     @async @show begin HTTP.get(Media.cdn_url(surl, size, anim); readtimeout=15, connect_timeout=5).body; nothing; end
        # end
    end

    [
     (; kind=Int(UPLOADED_2), content=JSON.json((; sha256=bytes2hex(sha256)))),
     (; kind=Int(UPLOADED), content=surl),
    ]
end

function import_upload(est::DB.CacheStorage, pubkey::Nostr.PubKeyId, data::Vector{UInt8})
    [e for e in import_upload_2(est, pubkey, data) if e.kind == UPLOADED]
end

UPLOAD_MAX_SIZE = Ref(1024^4)

function is_upload_blocked(pubkey::Nostr.PubKeyId)
    !isempty(DB.exec(lists[], "select 1 from lists where list = ?1 and pubkey = ?2 limit 1", ("upload_block", pubkey)))
end

function upload(est::DB.CacheStorage; event_from_user::Dict)
    DB.PG_DISABLE[] && return []

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    contents = e.content
    data = Base64.base64decode(contents[findfirst(',', contents)+1:end])

    length(data) > UPLOAD_MAX_SIZE[] && error("upload is too large")

    import_upload(est, e.pubkey, data)
end

active_uploads = Dict() |> ThreadSafe
upload_stats = (; started=Ref(0), completed=Ref(0), canceled=Ref(0))

function check_upload_id(ulid)
    @assert !isnothing(match(r"^[-a-zA-Z0-9_]+$", ulid)) ulid
    ulid
end

function upload_chunk(est::DB.CacheStorage; event_from_user::Dict)
    DB.PG_DISABLE[] && return []

    # push!(Main.stuff, (:upload_chunk, event_from_user))

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    c = JSON.parse(e.content)
    ulid = check_upload_id(c["upload_id"])

    lock(active_uploads) do active_uploads
        if !haskey(active_uploads, ulid)
            active_uploads[ulid] = trunc(Int, time())
            upload_stats.started[] += 1
            PushGatewayExporter.set!("cache_upload_stats_started", upload_stats.started[])
        end
    end

    c["file_length"] > UPLOAD_MAX_SIZE[] && error("upload size too large")

    fn = "$(MEDIA_UPLOAD_PATH[])/$(Nostr.hex(e.pubkey))_$(ulid)"
    # @show (; t=Dates.now(), fn, offset=c["offset"], file_length=c["file_length"])
    
    data = Base64.base64decode(c["data"][findfirst(',', c["data"])+1:end])
    c["offset"] + length(data) > UPLOAD_MAX_SIZE[] && error("upload size too large")

    open(fn, "a+") do f
        seek(f, c["offset"])
        write(f, data)
    end

    []
end

function upload_complete(est::DB.CacheStorage; event_from_user::Dict)
    DB.PG_DISABLE[] && return []

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    c = JSON.parse(e.content)
    ulid = check_upload_id(c["upload_id"])

    fn = "$(MEDIA_UPLOAD_PATH[])/$(Nostr.hex(e.pubkey))_$(ulid)"
    c["file_length"] == stat(fn).size || error("incorrect upload size")

    data = read(fn)
    c["sha256"] == bytes2hex(SHA.sha256(data)) || error("incorrect sha256")

    res = import_upload(est, e.pubkey, data)
    rm(fn)

    lock(active_uploads) do active_uploads
        delete!(active_uploads, ulid)
        upload_stats.completed[] += 1
        PushGatewayExporter.set!("cache_upload_stats_completed", upload_stats.completed[])
    end

    res
end

function upload_cancel(est::DB.CacheStorage; event_from_user::Dict)
    DB.PG_DISABLE[] && return []

    # push!(Main.stuff, (:upload_cancel, (; event_from_user)))

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD_CHUNK) || error("invalid event kind")
    is_upload_blocked(e.pubkey) && error("upload blocked")

    c = JSON.parse(e.content)
    ulid = check_upload_id(c["upload_id"])

    fn = "$(MEDIA_UPLOAD_PATH[])/$(Nostr.hex(e.pubkey))_$(ulid)"
    rm(fn)

    lock(active_uploads) do active_uploads
        delete!(active_uploads, ulid)
        upload_stats.canceled[] += 1
        PushGatewayExporter.set!("cache_upload_stats_canceled", upload_stats.canceled[])
    end

    []
end

REPORTED_PUBKEY = 1
REPORTED_EVENT  = 2

function report_id(est::DB.CacheStorage; event_from_user::Dict, id::Union{Nostr.PubKeyId, Nostr.EventId})
    DB.PG_DISABLE[] && return []
    e = parse_event_from_user(event_from_user)
    type = id isa Nostr.PubKeyId ? REPORTED_PUBKEY : REPORTED_EVENT
    DB.exec(est.dyn[:reported], 
            DB.@sql("insert into reported values (?1, ?2, ?3, ?4) on conflict do nothing"),
            (e.pubkey, type, id, trunc(Int, time())))
    []
end

function report_user(est::DB.CacheStorage; event_from_user::Dict, pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    report_id(est; event_from_user, id=pubkey)
end

function report_note(est::DB.CacheStorage; event_from_user::Dict, event_id)
    event_id = cast(event_id, Nostr.EventId)
    report_id(est; event_from_user, id=event_id)
end

function get_filterlist(est::DB.CacheStorage)
    [(; 
      kind=Int(FILTERLIST), 
      content=JSON.json(Filterlist.get_dict()))]
end

function check_filterlist(est::DB.CacheStorage; pubkeys)
    pubkeys = Set([cast(pk, Nostr.PubKeyId) for pk in pubkeys])
    res = (; pubkeys=[pk for pk in pubkeys if ext_is_hidden(est, pk)])
    [(; 
      kind=Int(FILTERLISTED), 
      content=JSON.json(res))]
end

parsed_settings = Dict{Nostr.PubKeyId, Tuple{Nostr.EventId, Any}}() |> ThreadSafe
parsed_default_settings = Ref{Any}(nothing)
periodic_parsed_default_settings = Utils.Throttle(; period=15.0, t=0.0)

user_has_app_settings = Dict() |> ThreadSafe

function ext_user_get_settings(est::DB.CacheStorage, pubkey)
    periodic_parsed_default_settings() do
        s = read(DEFAULT_SETTINGS_FILE[], String)
        d = JSON.parse(s)
        d["id"] = Nostr.EventId(SHA.sha256(s))
        parsed_default_settings[] = d
        empty!(user_has_app_settings)
    end
    res = parsed_default_settings[]

    if !isnothing(pubkey) && lock(user_has_app_settings) do user_has_app_settings; get!(user_has_app_settings, pubkey) do; pubkey in est.app_settings; end; end
        r = DB.exec(est.app_settings, DB.@sql("select event_id from app_settings 
                                                    where key = ?1 limit 1"), (pubkey,))[1][1]
        if !ismissing(r)
            seid = Nostr.EventId(r)

            eml = get(parsed_settings, pubkey, nothing)
            !isnothing(eml) && eml[1] == seid && return eml[2]

            e = est.app_settings[pubkey]
            d = JSON.parse(e.content)
            d["id"] = e.id

            for (k, v) in d
                res[k] = v
            end

            parsed_settings[pubkey] = (seid, res)
        end
    end
    res
end

function ext_invalidate_cached_content_moderation(est::DB.CacheStorage, user_pubkey::Union{Nothing,Nostr.PubKeyId})
    lock(analytics_cache) do analytics_cache
        for (k, pk) in collect(keys(analytics_cache))
            if pk == user_pubkey
                delete!(analytics_cache, (k, pk))
            end
        end
    end
end

function broadcast_event_to_relays(e::Nostr.Event; relays=sort(JSON.parse(read(DEFAULT_RELAYS_FILE[], String))), verbose=false)
    res = []
    for url in relays
        verbose && print("sending to $url: ")
        try
            r = Ref("")
            HTTP.WebSockets.open(url; suppress_close_error=true, retry=false, connect_timeout=15, timeout=15, readtimeout=15, proxy=Media.MEDIA_PROXY[]) do ws
                verbose && print("[connected] ")
                HTTP.WebSockets.send(ws, JSON.json(["EVENT", e]))
                verbose && print("[sent] ")
                r[] = HTTP.WebSockets.receive(ws)
            end
            verbose && println(r[])
            push!(res, (url, r[]))
        catch ex
            verbose && println(typeof(ex))
        end
    end
    res
end

function broadcast_event_to_relays_async(e::Nostr.Event; relays, proxy=Main.PROXY, timeout=15)
    res = []
    cond = Condition()
    function sendto(url)
        try
            r = Ref("")
            HTTP.WebSockets.open(url; suppress_close_error=true, retry=false, connect_timeout=timeout, timeout, readtimeout=timeout, proxy) do ws
                HTTP.WebSockets.send(ws, JSON.json(["EVENT", e]))
                r[] = HTTP.WebSockets.receive(ws)
            end
            push!(res, (url, r[]))
            rr = JSON.parse(r[])
            rr[1] == "OK" && rr[3] && notify(cond)
        catch ex
            # println("broadcast_event_to_relays_async: $(typeof(ex))")
        end
    end
    @async begin
        sleep(timeout)
        notify(cond)
    end
    for url in relays
        @async sendto(url)
    end
    wait(cond)
    res
end

function broadcast_spam_list_to_relays(; verbose=false)
    e = Nostr.Event(ALGOS_USER[].sk, ALGOS_USER[].pk, trunc(Int, time()), 30000, 
                    [Nostr.TagAny(["d", "spam_list"]); 
                     [Nostr.TagAny(["p", Nostr.hex(dpk)])
                      for dpk in collect(Filterlist.access_pubkey_blocked_spam)]],
                    "")
    broadcast_event_to_relays(e; verbose)
    e
end
##
BROADCAST_SPAM_LIST = Ref(false)
register_cache_function(:broadcast_spam_list,
                        function(est)
                            BROADCAST_SPAM_LIST[] && @async broadcast_spam_list_to_relays()
                        end, 600)
register_cache_function(:empty_analytics_cache,
                        function(est)
                            empty!(analytics_cache)
                            # ext_invalidate_cached_content_moderation(est, nothing)
                        end, 600)
##

function ext_user_profile(est::DB.CacheStorage, pubkey)
    if !isempty(local r = DB.exe(est.pubkey_zapped, DB.@sql("select zaps, satszapped from pubkey_zapped where pubkey = ?1"), pubkey))
        total_zap_count, total_satszapped = r[1]
    else
        total_zap_count = total_satszapped = 0
    end
    (;
     total_zap_count,
     total_satszapped,
    )
end

function start(est::DB.CacheStorage)
    lists[] = est.params.MembershipDBDict(String, Int, "lists"; connsel=est.pqconnstr,
                                     init_queries=["create table if not exists lists (list varchar(200) not null, pubkey bytea not null, added_at int not null)",
                                                   "create index if not exists lists_list on lists (list asc)",
                                                   "create index if not exists lists_pubkey on lists (pubkey asc)",
                                                   "create index if not exists lists_added_at on lists (added_at desc)",
                                                  ])
    categorized_uploads[] = est.params.MembershipDBDict(String, Int, "categorized_uploads"; connsel=est.pqconnstr,
                                     init_queries=["create table if not exists categorized_uploads (
                                                   type varchar not null,
                                                   added_at int not null,
                                                   sha256 bytea,
                                                   url varchar,
                                                   pubkey bytea,
                                                   event_id bytea,
                                                   extra json
                                                   )",
                                                   "create index if not exists categorized_uploads_added_at on categorized_uploads (added_at desc)",
                                                   "create index if not exists categorized_uploads_sha256 on categorized_uploads (sha256 asc)",
                                                  ])
end

lists = Ref{Any}(nothing)
function get_list(list)
    [Nostr.PubKeyId(pk) for (pk,) in DB.exec(lists[], "select pubkey from lists where list = ?1", (list,))]
end
function load_lists()
    for (list, coll) in [
                         ("spam_allow", Filterlist.access_pubkey_unblocked_spam),
                         ("spam_block", Filterlist.access_pubkey_blocked_spam),
                         ("nsfw_allow", Filterlist.access_pubkey_unblocked_nsfw),
                         ("nsfw_block", Filterlist.access_pubkey_blocked_nsfw),
                        ]
        union!(coll, get_list(list))
    end
end
function remove_from_list(list::String, pk::Nostr.PubKeyId)
    DB.exec(lists[], "delete from lists where list = ?1 and pubkey = ?2", (list, pk))
end

function broadcast_reply(est::DB.CacheStorage; event)
    e = cast(event, Nostr.Event)
    Nostr.verify(e) || error("verification failed")
    relays = collect(Set([t[2] for t in get_user_relays(est; e.pubkey)[end].tags]))
    events = []
    for t in e.tags
        if length(t.fields) >= 4 && t.fields[1] == "e" && !isnothing(local eid = try Nostr.EventId(t.fields[2]) catch _ nothing end) && t.fields[4] in ["root", "reply"]
            eid in est.events && push!(events, est.events[eid])
        end
    end
    broadcast_events(est; events, relays)
end

function broadcast_events(est::DB.CacheStorage; events::Vector, relays::Vector)
    events = [castmaybe(e, Nostr.Event) for e in events]
    res = asyncmap(events) do e
        (; event_id=e.id, responses=broadcast_event_to_relays_async(e; relays))
    end
    [(; kind=Int(EVENT_BROADCAST_RESPONSES), content=JSON.json(res))]
end

function ext_import_event(est::DB.CacheStorage, e::Nostr.Event) 
    e.kind == Int(Nostr.TEXT_NOTE) && @async broadcast_reply(est; event=e)
end

function trusted_users(est::DB.CacheStorage; limit::Int=500, extended_response=true)
    limit = min(10000, limit)
    res = []
    pktrs = Main.TrustRank.pubkey_rank_sorted[1:limit]
    push!(res, (; kind=Int(TRUSTED_USERS), content=JSON.json([(; pk, tr) for (pk, tr) in pktrs])))
    for (pk, tr) in pktrs
        haskey(est.meta_data, pk) && haskey(est.events, est.meta_data[pk]) && push!(res, est.events[est.meta_data[pk]])
    end
    res
end

function ext_user_profile_media(est::DB.CacheStorage, pubkey)
    haskey(est.meta_data, pubkey) ? event_media_response(est, est.meta_data[pubkey]) : []
end

function note_mentions(
        est::DB.CacheStorage; 
        event_id=nothing,
        pubkey=nothing, identifier=nothing,
        limit=100, offset=0, 
        user_pubkey=nothing,
    )
    event_id = castmaybe(event_id, Nostr.EventId)
    pubkey = castmaybe(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    limit <= 1000 || error("limit too big")

    type = Int(DB.YOUR_POST_WAS_MENTIONED_IN_POST)

    r = if !isnothing(event_id)
        DB.exec(est.pubkey_notifications, 
                "select arg1, arg2 from pubkey_notifications 
                where arg1 = ?1 and type = ?2
                order by created_at desc limit ?3 offset ?4",
                (event_id, type, limit, offset))

    elseif !isnothing(pubkey) && !isnothing(identifier) 
        Postgres.pex(DAG_OUTPUTS_DB[], pgparams() do P "
                      SELECT
                          pubkey_notifications.arg1, 
                          pubkey_notifications.arg2
                      FROM
                          prod.reads_versions,
                          prod.pubkey_notifications
                      WHERE 
                          reads_versions.pubkey = $(@P pubkey) AND 
                          reads_versions.identifier = $(@P identifier) AND 
                          reads_versions.eid = pubkey_notifications.arg1 AND 
                          pubkey_notifications.type = $(@P type)
                      ORDER BY
                          pubkey_notifications.created_at DESC
                      LIMIT $(@P limit) OFFSET $(@P offset)
                  " end...)
    else
        []
    end

    eids = Set{Nostr.EventId}()

    for (arg1, arg2) in r
        your_post_were_mentioned_in = Nostr.EventId(arg2)
        push!(eids, your_post_were_mentioned_in)
    end

    response_messages_for_posts(est, collect(eids); user_pubkey)
end

function note_mentions_count(est::DB.CacheStorage; event_id)
    event_id = cast(event_id, Nostr.EventId)
    (count,) = DB.exec(est.pubkey_notifications, 
                       "select count(1) from pubkey_notifications where arg1 = ?1 and type = ?2",
                       (event_id, Int(DB.YOUR_POST_WAS_MENTIONED_IN_POST)))[1]
    [(;
      kind=Int(NOTE_MENTIONS_COUNT),
      content=JSON.json((; event_id, count)))]
end

function ext_long_form_event_stats(est::DB.CacheStorage, eid::Nostr.EventId)
    isnothing(DAG_OUTPUTS_DB[]) && return []

    cols, rows = Postgres.execute(DAG_OUTPUTS_DB[], "
                                  select likes, zaps, satszapped, replies, 0 as mentions, reposts, 0 as score, 0 as score24h 
                                  from prod.reads where latest_eid = \$1 limit 1", [eid])
    isempty(rows) && return []

    es = [Symbol(k)=>v for (k, v) in zip(cols, rows[1])]
    [(; 
      kind=Int(EVENT_STATS),
      content=JSON.json((; event_id=eid, es...)))]
end

struct AppSPI_ end
AppSPI = AppSPI_()

struct AppSPIFuncall; funcall::Symbol; end

Base.getproperty(appspi::AppSPI_, prop::Symbol) = AppSPIFuncall(prop)

import ..PerfStats

spi_session_funcalls = Dict{Int, Any}() |> ThreadSafe

function (fc::AppSPIFuncall)(est; kwargs...)
    res = []
    tdur = @elapsed Postgres.handle_errors(:p0ext) do session
        pid = session.extra[:backendpid]
        spi_session_funcalls[pid] = (Utils.current_time(), fc.funcall, kwargs)
        try
            PerfStats.recordspi!(:spifuncalls, session.extra[:backendpid], fc.funcall) do
                for (_, s) in Postgres.execute(session, "select * from p_julia_api_call(\$1) a", [JSON.json([fc.funcall, Dict(kwargs)])])[2]
                    r = JSON.parse(s)
                    if r[1] == "EVENT"
                        push!(res, r[2])
                    elseif r[1] == "NOTICE"
                        error(r[2])
                    end
                end
            end
        finally
            spi_session_funcalls[pid] = nothing
        end
    end
    tdur > 2 && @show (:slow_AppSPIFuncall, tdur, fc.funcall, kwargs)
    res
end
