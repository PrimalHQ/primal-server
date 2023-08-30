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

union!(exposed_functions, Set([
                     :explore_legend_counts,
                     :explore,
                         :explore_global_trending_24h,
                         :explore_global_mostzapped_4h,
                     :scored_users,
                         :scored_users_24h,
                     :set_app_settings,
                     :get_app_settings,
                     :get_app_settings_2,
                     :get_default_app_settings,
                     :get_default_relays,
                     :get_recommended_users,
                     :user_profile_scored_content,
                     :search,
                     :relays,
                     :get_notifications,
                     :set_notifications_seen,
                     :get_notifications_seen,
                     :user_search,
                     :feed_directive,
                     :trending_hashtags,
                         :trending_hashtags_4h,
                         :trending_hashtags_7d,
                     :trending_images,
                         :trending_images_4h,
                     :upload,
                     :report_user,
                     :report_note,
                     :get_filterlist,
                     :check_filterlist,
                     :zaps_feed,
                     :user_zaps,
                    ]))

union!(exposed_async_functions, Set([
                                     :notifications, 
                                     :notification_counts, 
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
    for (k, cf) in collect(cached_functions)
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
                         DB.@sql("select follower_pubkey from kv where pubkey = ?"),
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
    push!(where_exprs, "$created_after <= created_at")
    # push!(where_exprs, "created_at <= $(trunc(Int, time()))") # future events are ignore during import

    isnothing(since) || push!(where_exprs, "$since <= $field")
    isnothing(until) || push!(where_exprs, "$until >= $field")

    timeframe == :mostzapped && push!(where_exprs, "$field > 0")

    posts = [] |> ThreadSafe
    posts_filtered = Tuple{Nostr.EventId, Float64}[]

    n = limit
    while true
        time_exceeded() && break
        n > MAX_LIMIT && break

        empty!(posts)
        if isempty(pubkeys)
            q_wheres = wheres()
            if group_by_pubkey
                q_groups = "group by author_pubkey"
                q_indexs = "indexed by kv_created_at"
                field_ = "max($field)"
            else
                q_groups = q_indexs = ""
                field_ = field
            end
            @threads for dbconn in est.event_stats.dbconns
                r = DB.exe(dbconn, "select event_id, $field_ from kv $q_indexs $q_wheres $q_groups order by $field_ desc limit ? offset ?", (n, offset))
                append!(posts, map(Tuple, r))
            end
        else
            field_ = field
            push!(where_exprs, "author_pubkey = ?")
            q_wheres = wheres()
            @threads for pk in pubkeys
                time_exceeded() && break
                append!(posts, map(Tuple, DB.exe(est.event_stats_by_pubkey, "select event_id, $field_ from kv $q_wheres order by $field_ desc limit ? offset ?", pk, n, offset)))
            end
        end

        empty!(posts_filtered)
        for (eid, v) in posts.wrapped
            local eid = Nostr.EventId(eid)
            local pk = DB.exe(est.event_stats, DB.@sql("select event_id, author_pubkey from kv where event_id = ?"), 
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

explore_global_trending_24h(est::DB.CacheStorage; user_pubkey=nothing) = explore(est; timeframe="trending", scope="global", limit=12, created_after=trunc(Int, time()-24*3600), group_by_pubkey=true, user_pubkey)

explore_global_mostzapped_4h(est::DB.CacheStorage; user_pubkey=nothing) = explore(est; timeframe="mostzapped", scope="global", limit=12, created_after=trunc(Int, time()-4*3600), group_by_pubkey=true, user_pubkey)

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
        scored_content(est; timeframe, user_pubkey, kwargs...)
        # scored_content(est; timeframe, pubkeys=outer_network(est, user_pubkey), user_pubkey, kwargs...)
    elseif scope == :tribe
        scored_content(est; timeframe, pubkeys=inner_network(est, user_pubkey), user_pubkey, kwargs...)
    elseif scope == :follows
        scored_content(est; timeframe, pubkeys=follows(est, user_pubkey), user_pubkey, kwargs...)
    else
        []
    end
end

scored_users_24h(est::DB.CacheStorage; user_pubkey=nothing) = scored_users(est; limit=6*4, since=trunc(Int, time()-24*3600), user_pubkey)

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
    @threads for dbconn in est.event_stats_by_pubkey.dbconns
        for r in DB.exe(dbconn, "select author_pubkey, max($field) as maxscore
                                 from kv indexed by kv_created_at
                                 $q_wheres
                                 group by author_pubkey
                                 order by maxscore desc limit ?", (limit,))
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
        DB.exe(est.ext[].app_settings, DB.@sql("update app_settings set accessed_at = ?2 where key = ?1"),
               e.pubkey, trunc(Int, time()))
        DB.exe(est.ext[].app_settings_log, DB.@sql("insert into app_settings_log values (?1, ?2, ?3)"), 
               e.pubkey, e, trunc(Int, time()))
    end
end
    
function set_app_settings(est::DB.CacheStorage; settings_event::Dict)
    app_settings(est, settings_event) do e
        est.ext[].app_settings[e.pubkey] = e
        DB.exe(est.ext[].app_settings, 
               DB.@sql("update app_settings set created_at = ?2, event_id = ?3 where key = ?1"),
               e.pubkey, e.created_at, e.id)
        parse_notification_settings(est, e)
        [e]
    end
end
    
function get_app_settings(est::DB.CacheStorage; event_from_user::Dict)
    app_settings(est, event_from_user) do e
        if e.pubkey in est.ext[].app_settings
            [est.ext[].app_settings[e.pubkey]]
        else
            ee = get_default_app_settings(est; client=event_from_user["tags"][1][2])[1]
            ee = (; ee..., id=join(["00" for _ in 1:32]), pubkey=join(["00" for _ in 1:32]), sig=join(["00" for _ in 1:64]), created_at=trunc(Int, time()))
            ee = Nostr.Event(JSON.parse(JSON.json(ee)))
            est.ext[].app_settings[e.pubkey] = ee
            [ee]
        end
    end
end

function get_app_settings_2(est::DB.CacheStorage; event_from_user::Dict)
    app_settings(est, event_from_user) do e
        if e.pubkey in est.ext[].app_settings
            [est.ext[].app_settings[e.pubkey]]
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
    [(; kind=Int(DEFAULT_RELAYS), 
      content=JSON.json(try JSON.parse(read(DEFAULT_RELAYS_FILE[], String))
                        catch _; (;) end))]
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

function parse_notification_settings(est::DB.CacheStorage, e::Nostr.Event)
    d = JSON.parse(e.content)
    if haskey(d, "notifications")
        DB.exe(est.ext[].notification_settings, DB.@sql("delete from notification_settings where pubkey = ?1"),
               e.pubkey)
        for (k, v) in d["notifications"]
            DB.exe(est.ext[].notification_settings, DB.@sql("insert into notification_settings values (?1, ?2, ?3)"),
                   e.pubkey, k, v)
        end
    end
end

function user_profile_scored_content(est::DB.CacheStorage; pubkey, limit::Int=5, user_pubkey=nothing)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    eids = [Nostr.EventId(eid) 
            for (eid,) in DB.exe(est.event_stats_by_pubkey,
                                 DB.@sql("select event_id from kv
                                          where author_pubkey = ? and score > 0
                                          order by score desc limit ?"), pubkey, limit)]
    res = Set() |> ThreadSafe

    for eid in eids
        (eid in Filterlist.access_event_blocked || eid in est.deleted_events || is_hidden(est, user_pubkey, :trending, eid)) && continue
        e = est.events[eid]
        push!(res, e)
        union!(res, event_stats(est, eid))
    end

    pubkey in est.meta_data && push!(res, est.events[est.meta_data[pubkey]])

    collect(res)
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

function search(
        est::DB.CacheStorage; 
        query::String, 
        limit::Int=20, since::Union{Nothing,Int}=0, until::Union{Nothing,Int}=nothing, 
        user_pubkey=nothing,
    )
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)
    isempty(query) && error("query is empty")
    query[1] != '!' && (query = transform_search_query(query))
    if isnothing(until)
        until = DB.exec(est.ext[].event_contents, DB.@sql("select rowid from kv_fts order by rowid desc limit 1"))[1][1]
    end
    res = DB.exec(est.ext[].event_contents, DB.@sql("select event_id, rowid from kv_fts where rowid >= ?1 and rowid <= ?2 and content match ?3 order by rowid desc limit ?4"),
                  (since, until, query, limit))
    res = sort(res; by=r->-r[2])
    eids = [Nostr.EventId(eid) for (eid, _) in res]
    vcat(response_messages_for_posts(est, eids; user_pubkey), range(res, :created_at))
end

function relays(est::DB.CacheStorage; limit::Int=20)
    res = DB.exec(est.relays, DB.@sql("select url, times_referenced from kv order by times_referenced desc limit ?"), (limit,))
    res = res[1:min(limit, length(res))]
    [(; kind=Int(RELAYS), content=JSON.json(Dict(res)))]
end

function get_notifications(
        est::DB.CacheStorage;
        pubkey,
        limit::Int=1000, since::Int=0, until::Int=trunc(Int, time()), offset::Int=0,
        user_pubkey=nothing,
    )
    # limit <= 1000 || error("limit too big")
    limit = min(limit, 1000) # iOS app was requesting limit=~13000

    pubkey = cast(pubkey, Nostr.PubKeyId)
    user_pubkey = castmaybe(user_pubkey, Nostr.PubKeyId)

    res = []
    res_meta_data = Dict()

    pks = Set{Nostr.PubKeyId}()
    eids = Set{Nostr.EventId}()

    for r in
        DB.exe(est.ext[].notifications.pubkey_notifications, 
               DB.@sql("select * from kv 
                       where pubkey = ? and created_at >= ? and created_at <= ?
                       order by created_at desc limit ? offset ?"),
               pubkey, since, until, limit, offset)

        (_, created_at, type, arg1, arg2, arg3, arg4) = r

        notif_d = DB.notif2namedtuple((pubkey, created_at, DB.NotificationType(type),
                                       arg1, arg2, arg3, arg4))

        # if notif_d.type == DB.USER_UNFOLLOWED_YOU
        #     if !isempty(DB.exe(est.pubkey_followers, DB.@sql("select 1 from kv where pubkey = ? and follower_pubkey = ? limit 1"),
        #                        pubkey, notif_d.follower))
        #         continue
        #     end
        # end

        is_blocked = false

        for arg in collect(values(notif_d))
            if arg isa Nostr.PubKeyId
                pk = arg
                if is_hidden(est, user_pubkey, :content, pk) || ext_is_hidden(est, pk)
                    is_blocked = true
                else
                    push!(pks, pk)
                    if !haskey(res_meta_data, pk) && pk in est.meta_data
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
        #     DB.exe(est.ext[].notifications.pubkey_notifications, 
        #            "delete from kv where pubkey = ? and created_at = ? and type = ? $wheres",
        #            pubkey, created_at, type, args...)
        #     DB.exe(est.ext[].notifications.pubkey_notification_cnts,
        #            "update kv set type$(type) = type$(type) - 1 where pubkey = ?1",
        #            pubkey)
        end
    end

    res = collect(Set(res)) # remove duplicates ??

    for pk in pks
        push!(res, (;
                    kind=Int(USER_PROFILE),
                    pubkey=pk,
                    content=JSON.json((;
                                       followers_count=get(est.pubkey_followers_cnt, pk, 0),
                                      ))))
    end

    append!(res, response_messages_for_posts(est, collect(eids); res_meta_data, user_pubkey))

    res
end

function set_notifications_seen(
        est::DB.CacheStorage;
        event_from_user::Dict,
        replicated=false
    )
    replicated || replicate_request(:set_notifications_seen; event_from_user)

    e = parse_event_from_user(event_from_user)

    est.ext[].notifications.pubkey_notifications_seen[e.pubkey] = e.created_at

    DB.exe(est.ext[].notifications.pubkey_notification_cnts,
           "update kv set $(join(["type$(i|>Int) = 0" for i in instances(DB.NotificationType)], ", ")) where pubkey = ?1",
           e.pubkey)

    []
end

function get_notifications_seen(est::DB.CacheStorage; pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    if pubkey in est.ext[].notifications.pubkey_notifications_seen
        [(; kind=Int(NOTIFICATIONS_SEEN_UNTIL),
          content=JSON.json(est.ext[].notifications.pubkey_notifications_seen[pubkey]))] 
    else
        []
    end
end

function get_notification_counts(est::DB.CacheStorage; pubkey)
    pubkey = cast(pubkey, Nostr.PubKeyId)
    [(; kind=Int(NOTIFICATIONS_SUMMARY), pubkey=Nostr.PubKeyId(pk),
      [Symbol(string(Int(i)))=>cnt
       for (i, cnt) in zip(instances(DB.NotificationType), cnts)]...)
     for (pk, cnts...) in DB.exe(est.ext[].notifications.pubkey_notification_cnts,
                                 "select * from kv where pubkey = ?1", pubkey)]
end

function user_search(est::DB.CacheStorage; query::String, limit::Int=10, pubkey::Any=nothing)
    limit <= 1000 || error("limit too big")
    
    q = "^" * repr(query) * "*"

    res = Dict()

    if isnothing(pubkey)
        for (pk,) in DB.exec(est.pubkey_followers,
                             DB.@sql("select pubkey from user_search where
                                     name match ? or username match ? or display_name match ? or displayName match ? or nip05 match ?
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
            for (pk,) in DB.exec(est.pubkey_followers,
                                 DB.@sql("select pubkey from user_search where
                                         pubkey in (select pubkey from kv where follower_pubkey = ?1)
                                         and (name match ?2 or display_name match ?3 or nip05 match ?4)
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

function feed_directive(est::DB.CacheStorage; directive::String, kwargs...)
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
            if haskey(cmr.groups, :primal_spam)
                scopes = cmr.groups[:primal_spam].scopes
                return (isempty(scopes) ? true : scope in scopes)
            else
                return false
            end
        end
    end
    false
end

function ext_is_hidden_by_group(est::DB.CacheStorage, user_pubkey, scope::Symbol, pubkey::Nostr.PubKeyId)
    isnothing(user_pubkey) && return false
    cmr = compile_content_moderation_rules(est, user_pubkey)
    if haskey(cmr.groups, :primal_spam) && pubkey in Filterlist.access_pubkey_blocked_spam
        scopes = cmr.groups[:primal_spam].scopes
        return (isempty(scopes) ? true : scope in scopes)
    end
    haskey(cmr.groups, :primal_nsfw) && is_hidden_on_primal_nsfw(est, user_pubkey, scope, pubkey)
    false
end

function ext_is_hidden_by_group(est::DB.CacheStorage, user_pubkey, scope::Symbol, eid::Nostr.EventId)
    eid in est.events && ext_is_hidden_by_group(est, user_pubkey, scope, est.events[eid].pubkey) && return true
    isnothing(user_pubkey) && return false
    cmr = compile_content_moderation_rules(est, user_pubkey)
    # if haskey(cmr.groups, :primal_nsfw)
    #     scopes = cmr.groups[:primal_nsfw].scopes
    #     for (url,) in DB.exe(est.ext[].event_media, DB.@sql("select url from event_media where event_id = ?1"), eid)
    #         for (category, category_confidence) in DB.exec(est.ext[].media, DB.@sql("select category, category_confidence from media where url = ?1 limit 1"), (url,))
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
    for (url,) in DB.exe(est.ext[].event_media, DB.@sql("select url from event_media where event_id = ?1"), eid)
        variants = []
        for (s, a, w, h, mt) in DB.exec(est.ext[].media, DB.@sql("select size, animated, width, height, mimetype from media where url = ?1"), (url,))
            push!(variants, (; s=s[1], a, w, h, mt, media_url=Media.cdn_url(url, s, a)))
            root_mt = mt
        end
        push!(resources, (; url, variants, (isnothing(root_mt) ? [] : [:mt=>root_mt])...))
    end
    isempty(resources) ? [] : [(; kind=Int(MEDIA_METADATA), content=JSON.json((; event_id=eid, resources)))]
end

function event_preview_response(est::DB.CacheStorage, eid::Nostr.EventId)
    resources = []
    for (url,) in DB.exe(est.ext[].event_preview, DB.@sql("select url from event_preview where event_id = ?1"), eid)
        for (mimetype, md_title, md_description, md_image, icon_url) in 
            DB.exec(est.ext[].preview, DB.@sql("select mimetype, md_title, md_description, md_image, icon_url from preview where url = ?1"), (url,))
            push!(resources, (; url, mimetype, md_title, md_description, md_image, icon_url))
        end
    end
    isempty(resources) ? [] : [(; kind=Int(LINK_METADATA), content=JSON.json((; event_id=eid, resources)))]
end

periodic_hashtag_whitelist = Utils.Throttle(; period=5.0, t=0.0)
hashtag_whitelist = Set{String}()

HASHTAG_WHITELIST = Ref("hashtag-whitelist.txt")

function update_hashtag_whitelist()
    periodic_hashtag_whitelist() do
        empty!(hashtag_whitelist)
        isfile(HASHTAG_WHITELIST[]) && for s in readlines(HASHTAG_WHITELIST[])
            startswith(s, "-----") && break
            ht = split(s)[1][30:end]
            push!(hashtag_whitelist, ht)
        end
    end
end

function trending_hashtags(est::DB.CacheStorage; created_after::Int=trunc(Int, time()-7*24*3600))
    # res = []
    # for (ht, cnt) in DB.exec(est.ext[].event_hashtags, DB.@sql("select lower(hashtag), count(1) as cnt from event_hashtags where created_at >= ?1 group by lower(hashtag) order by cnt desc"), (created_after,))
    #     ht in hashtag_whitelist && push!(res, (ht, cnt))
    # end
    update_hashtag_whitelist()
    hts = Accumulator{String, Float32}()
    eid2pk = Dict{Nostr.EventId, Nostr.PubKeyId}()
    eid2followers = Dict{Nostr.PubKeyId, Int}()
    for (i, (eid, ht)) in enumerate(DB.exec(est.ext[].event_hashtags, DB.@sql("select event_id, hashtag from event_hashtags where created_at >= ?1 order by created_at asc"), (created_after,)))
        yield()
        ht in hashtag_whitelist || continue
        eid = Nostr.EventId(eid)
        pk = get!(eid2pk, eid) do; est.events[eid].pubkey end
        nposts = get!(eid2followers, pk) do; DB.exe(est.pubkey_events, DB.@sql("select count(1) from kv where pubkey = ?1"), pk)[1][1] end
        user_score = est.pubkey_followers_cnt[pk] / nposts
        hts[ht] += user_score
    end
    res = sort(collect(hts); by=r->-r[2])
    [(; kind=Int(HASHTAGS), content=JSON.json(res))]
end

@cached 600  trending_hashtags_4h(est::DB.CacheStorage) = trending_hashtags(est; created_after=trunc(Int, time()-4*3600))
@cached 3600 trending_hashtags_7d(est::DB.CacheStorage) = trending_hashtags(est; created_after=trunc(Int, time()-7*24*3600))

function trending_images(est::DB.CacheStorage; created_after::Int=trunc(Int, time()-4*3600), limit=20)
    update_hashtag_whitelist()
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
                nposts = DB.exe(est.pubkey_events, DB.@sql("select count(1) from kv where pubkey = ?1"), pk)[1][1]
                user_score = est.pubkey_followers_cnt[pk] / nposts
                score = DB.exe(est.event_stats, DB.@sql("select score24h from kv where event_id = ?1"), eid)[1][1]
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

@cached 600 trending_images_4h(est::DB.CacheStorage) = trending_images(est; created_after=trunc(Int, time()-4*3600), limit=500)

UPLOADS_DIR = Ref("uploads")
MEDIA_URL_ROOT = Ref("https://media.primal.net/uploads")
URL_SHORTENING_SERVICE = Ref("http://127.0.0.1:14001/url-shortening?u=")

function upload(est::DB.CacheStorage; event_from_user::Dict)
    DB.PG_DISABLE[] && return []

    e = parse_event_from_user(event_from_user)
    e.kind == Int(UPLOAD) || error("invalid event kind")

    contents = e.content
    data = Base64.base64decode(contents[findfirst(',', contents)+1:end])
    key = (; type="member_upload", pubkey=e.pubkey, sha256=bytes2hex(SHA.sha256(data)))
    (mi, lnk) = Media.media_import((_)->data, key; media_path=UPLOADS_DIR[])
    _, ext = splitext(lnk)
    url = "$(MEDIA_URL_ROOT[])/$(mi.subdir)/$(mi.h)$(ext)"

    wh = Media.parse_image_dimensions(data)
    width, height = isnothing(wh) ? (0, 0) : wh
    mimetype = Media.parse_image_mimetype(data)

    if isempty(DB.exe(est.ext[].media_uploads, DB.@sql("select 1 from media_uploads where pubkey = ?1 and key = ?2 limit 1"), e.pubkey, JSON.json(key)))
        DB.exe(est.ext[].media_uploads, DB.@sql("insert into media_uploads values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)"), 
               e.pubkey,
               key.type, JSON.json(key),
               trunc(Int, time()),
               string(URIs.parse_uri(url).path),
               stat(lnk).size, 
               mimetype,
               "", 1.0, 
               width, height, 0.0)
    end

    surl = String(HTTP.get("$(URL_SHORTENING_SERVICE[])$(URIs.escapeuri(url))").body)

    if splitext(surl)[2] in [".jpg", ".png", ".gif"]
        r = Media.media_variants(est, surl, Media.all_variants; sync=true, proxy=nothing)
        @sync for ((size, anim), media_url) in r
            @async begin HTTP.get(Media.cdn_url(surl, size, anim); readtimeout=15, connect_timeout=5).body; nothing; end
        end
    end

    [(; kind=Int(UPLOADED), content=surl)]
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

function response_messages_for_zaps(est, zaps; kinds=nothing)
    res_meta_data = Dict()
    res = []
    for (zap_receipt_id, created_at, event_id, sender, receiver, amount_sats) in zaps
        for pk in [sender, receiver]
            (isnothing(pk) || ismissing(pk)) && continue
            pk = Nostr.PubKeyId(pk)
            if !haskey(res_meta_data, pk) && pk in est.meta_data
                res_meta_data[pk] = est.events[est.meta_data[pk]]
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
    ext_user_infos(est, res, res_meta_data)

    res_ = []
    for e in [collect(OrderedSet(res)); range(zaps, :created_at)]
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
    limit <= 1000 || error("limit too big")
    pubkeys = [cast(pubkey, Nostr.PubKeyId) for pubkey in pubkeys]

    # pks = collect(union(pubkeys, [follows(est, pubkey) for pubkey in pubkeys]...))
    pks = pubkeys

    zaps = [] |> ThreadSafe
    @threads for p in pks
        time_exceeded() && break
        append!(zaps, map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from zap_receipts 
                                                                   where (sender = ? or receiver = ?) and created_at >= ? and created_at <= ?
                                                                   order by created_at desc limit ? offset ?"),
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
    limit <= 1000 || error("limit too big")
    sender = castmaybe(sender, Nostr.PubKeyId)
    receiver = castmaybe(receiver, Nostr.PubKeyId)

    zaps = if !isnothing(sender)
        map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from zap_receipts 
                                                     where sender = ? and created_at >= ? and created_at <= ?
                                                     order by created_at desc limit ? offset ?"),
                           (sender, since, until, limit, offset)))
    elseif !isnothing(receiver)
        map(Tuple, DB.exec(est.zap_receipts, DB.@sql("select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from zap_receipts 
                                                     where receiver = ? and created_at >= ? and created_at <= ?
                                                     order by created_at desc limit ? offset ?"),
                           (receiver, since, until, limit, offset)))
    else
        error("either sender or receiver argument has to be specified")
    end

    zaps = sort(zaps, by=z->-z[2])[1:min(limit, length(zaps))]

    response_messages_for_zaps(est, zaps; kinds)
end

parsed_settings = Dict{Nostr.PubKeyId, Tuple{Nostr.EventId, Any}}() |> ThreadSafe

function ext_user_get_settings(est::DB.CacheStorage, pubkey::Nostr.PubKeyId)
    if pubkey in est.ext[].app_settings 
        r = DB.exec(est.ext[].app_settings, DB.@sql("select event_id from app_settings 
                                                    where key = ?1 limit 1"), (pubkey,))[1][1]
        ismissing(r) && return
        seid = Nostr.EventId(r)

        eml = get(parsed_settings, pubkey, nothing)
        !isnothing(eml) && eml[1] == seid && return eml[2]

        e = est.ext[].app_settings[pubkey]
        d = JSON.parse(e.content)

        res = (;
               id=e.id,
               apply_content_moderation=get(d, "applyContentModeration", true),
               content_moderation=get(d, "contentModeration", []),
              )
        parsed_settings[pubkey] = (seid, res)
    else
        res = (; apply_content_moderation=false)
    end
    res
end

function broadcast_event_to_relays(e::Nostr.Event; relays=sort(JSON.parse(read(DEFAULT_RELAYS_FILE[], String))))
    res = []
    for url in relays
        # print("sending to $url: ")
        try
            r = Ref("")
            HTTP.WebSockets.open(url; suppress_close_error=true, retry=false, connect_timeout=15, timeout=15, proxy=Media.MEDIA_PROXY[]) do ws
                HTTP.WebSockets.send(ws, JSON.json(["EVENT", e]))
                r[] = HTTP.WebSockets.receive(ws)
            end
            # println(r[])
            push!(res, r[])
        catch ex
            # println(typeof(ex))
        end
    end
end

function broadcast_spam_list_to_relays()
    e = Nostr.Event(ALGOS_USER[].sk, ALGOS_USER[].pk, trunc(Int, time()), 30000, 
                    [Nostr.TagAny(["d", "spam_list"]); 
                     [Nostr.TagAny(["p", Nostr.hex(dpk)])
                      for dpk in collect(Filterlist.access_pubkey_blocked_spam)]],
                    "")
    broadcast_event_to_relays(e)
    e
end
##
register_cache_function(:broadcast_spam_list,
                        function(est)
                            broadcast_spam_list_to_relays()
                        end, 600)
##
