module CacheServerHandlers

import HTTP
using HTTP.WebSockets
import JSON
using DataStructures: CircularBuffer

import ..Utils
using ..Utils: ThreadSafe, Throttle
import ..Nostr
import ..MetricsLogger
import ..PerfTestRedirection
import ..PerfStats

PRINT_EXCEPTIONS = Ref(false)

MAX_SUBSCRIPTIONS = Ref(200)

ENABLE_SPI = Ref(false)
ENABLE_DIST = Ref(false)
ENABLE_PGFUNCS = Ref(false)

Tsubid = String
Tfilters = Vector{Any}
struct Conn
    ws::ThreadSafe{WebSocket}
    subs::ThreadSafe{Dict{Tsubid, Tfilters}}
    user::ThreadSafe{Base.RefValue{Any}}
end
conns = Dict{WebSocket, Conn}() |> ThreadSafe

exceptions = CircularBuffer(200) |> ThreadSafe

sendcnt = Ref(0) |> ThreadSafe

max_request_duration = Ref(0.0) |> ThreadSafe
requests_per_period = Ref(0) |> ThreadSafe

include("cache_server_handlers_ext.jl")

# function ext_on_connect(ws) end
# function ext_on_disconnect(ws) end
# function ext_periodic() end
# function ext_funcall(funcall, kwargs, kwargs_extra, ws_id) end

function on_connect(ws)
    conns[ws] = Conn(ThreadSafe(ws), ThreadSafe(Dict{Tsubid, Tfilters}()), ThreadSafe(Ref{Any}(nothing)))
    PerfTestRedirection.enabled() && PerfTestRedirection.start_redirection(ws.id)
    # ext_on_connect(ws)
end

function on_disconnect(ws)
    delete!(conns, ws)
    PerfTestRedirection.enabled() && PerfTestRedirection.stop_redirection(ws.id)
    # ext_on_disconnect(ws)
end

function on_client_message(ws, msg)
    conn = conns[ws]
    d = JSON.parse(msg)
    try
        if d[1] == "REQ"
            subid = d[2]
            filters = d[3:end]
            conn.subs[subid] = filters

            if length(conn.subs) > MAX_SUBSCRIPTIONS[]
                send(ws, JSON.json(["NOTICE", subid, "too many subscriptions"]))
                close(ws)
                return
            end
            if any([haskey(f, "kinds") || haskey(f, "authors") for f in filters])
                send(ws, JSON.json(["NOTICE", subid, "kinds or authors filter is not supported"]))
                close(ws)
                return
            end

            PerfTestRedirection.enabled() && for filt in filters
                if haskey(filt, "cache")
                    local filt = filt["cache"]
                    funcall = Symbol(filt[1])
                    if funcall in PerfTestRedirection.FUNCS
                        PerfTestRedirection.send_msg(ws.id, msg)
                    end
                end
            end

            initial_filter_handler(conn, subid, filters)

        elseif d[1] == "CLOSE"
            subid = d[2]
            delete!(conn.subs, subid)
            PerfTestRedirection.enabled() && PerfTestRedirection.send_msg(ws.id, msg)

        end
    catch _
        PRINT_EXCEPTIONS[] && Utils.print_exceptions()
        rethrow()
    end
end

MAX_TIME_PER_REQUEST = Ref(10.0)
function with_time_limit(body::Function)
    tstart = time()
    body(() -> (time() - tstart) >= MAX_TIME_PER_REQUEST[])
end

SEND_ABORT = Ref(false)

function send(ws::WebSocket, s::String)
    WebSockets.send(ws, s)
end
function send(conn::Conn, s::String)
    SEND_ABORT[] && return
    lock(conn.ws) do ws
        lock(sendcnt) do sendcnt; sendcnt[] += 1; end
        try
            WebSockets.send(ws, s)
        finally
            lock(sendcnt) do sendcnt; sendcnt[] -= 1; end
        end
    end
end

est() = Main.eval(:(cache_storage))
App() = Main.eval(:(App))

function app_funcall(funcall::Symbol, kwargs, sendres; kwargs_extra=Pair{Symbol, Any}[], subid=nothing, ws_id=nothing, est_=nothing)
    # @show funcall
    isnothing(est_) && (est_ = est())
    # ext_funcall(funcall, kwargs, kwargs_extra, ws_id)
    MetricsLogger.log(r->begin
                          lock(max_request_duration) do max_request_duration
                              max_request_duration[] = max(max_request_duration[], r.time)
                          end
                          lock(requests_per_period) do requests_per_period
                              requests_per_period[] += 1
                          end
                          (; funcall, kwargs, ws=string(ws_id), subid)
                      end) do
    fetch(Threads.@spawn with_time_limit() do time_exceeded
              # Base.current_task().sticky = true

              funcall in [:feed, :get_notifications] && push!(kwargs, :time_exceeded=>time_exceeded)
              res = []

              PerfStats.record!(:funcalls, funcall) do
                  # PerfStats.record!(:funcalls2, (funcall, kwargs)) do
                      append!(res, Base.invokelatest(getproperty(App(), funcall), est_; kwargs..., kwargs_extra...))
                      if time_exceeded()
                          # @show (:time_exceeded, Dates.now(), funcall)
                          push!(res, (; kind=App().PARTIAL_RESPONSE))
                      end
                  # end
              end

              res
          end)
    end |> sendres
end

import ..Postgres
##
CacheServerHandlers.eval(quote
app_funcalls_external = Set([
                            :feed,
                            :thread_view,
                            :contact_list,
                            :is_user_following,
                            :user_infos,
                            :user_followers,
                            :mutual_follows,
                            :events,
                            :event_actions,
                            :user_profile,
                            :get_directmsg_contacts,
                            :get_directmsgs,
                            :mutelist,
                            :mutelists,
                            :allowlist,
                            :parameterized_replaceable_list,
                            :parametrized_replaceable_event,
                            :parametrized_replaceable_events,
                            :zaps_feed,
                            :user_zaps,
                            :user_zaps_by_satszapped,
                            :event_zaps_by_satszapped,
                            :user_of_ln_address,
                            :get_user_relays,

                            :explore_legend_counts,
                            :explore,
                                :explore_global_trending_24h,
                                :explore_global_mostzapped_4h,
                            :scored,
                            :scored_users,
                                :scored_users_24h,
                            :user_profile_scored_content,
                            :user_profile_scored_media_thumbnails,
                            :relays,
                            :get_notifications,

                            :feed_directive,
                            :feed_directive_2,
                            
                            # :trending_hashtags,
                            #     :trending_hashtags_4h,
                            #     :trending_hashtags_7d,

                            # :mega_feed_directive, # FIXME (create temps -> pubkey_followers)
                            :enrich_feed_events,
                           ])
end)
##
function app_funcall_external(app)
    function (funcall::Symbol, kwargs, sendres; kwargs_extra=Pair{Symbol, Any}[], subid=nothing, ws_id=nothing)
        # @show funcall
        function call()
            MetricsLogger.log(r->begin
                                  lock(max_request_duration) do max_request_duration
                                      max_request_duration[] = max(max_request_duration[], r.time)
                                  end
                                  lock(requests_per_period) do requests_per_period
                                      requests_per_period[] += 1
                                  end
                                  (; funcall, kwargs, ws=string(ws_id), subid)
                              end) do
                res = fetch(@async Base.invokelatest(getproperty(app, funcall), nothing; kwargs...)) 
                # @show (funcall, length(res))
                res |> sendres
            end
        end

        # call() = Base.invokelatest(getproperty(app, funcall), nothing; kwargs...) |> sendres

        try
            call()
        catch ex
            Utils.print_exceptions()
            if ex isa EOFError
                println(@__MODULE__, ": retrying $funcall")
                call()
                println(@__MODULE__, ": retrying $funcall successful")
            else
                rethrow()
            end
        end
    end
end

UNKNOWN_ERROR_MESSAGE = Ref("error")

function initial_filter_handler(conn::Conn, subid, filters)
    ws_id = lock(conn.ws) do ws; ws.id; end

    function sendres(res::Vector)
        lock(conn.ws) do ws
            for d in res
                send(ws, JSON.json(["EVENT", subid, d]))
            end
            send(ws, JSON.json(["EOSE", subid]))
        end
    end
    function send_error(s::String)
        lock(conn.ws) do ws
            send(ws, JSON.json(["NOTICE", subid, s]))
            send(ws, JSON.json(["EOSE", subid]))
        end
    end

    try
        for filt in filters
            if haskey(filt, "cache")
                local filt = filt["cache"]
                funcall = Symbol(filt[1])
                if funcall in App().exposed_functions
                    # println(Main.App.Dates.now(), "  ", funcall)
                    
                    kwargs = Pair{Symbol, Any}[Symbol(k)=>v for (k, v) in get(filt, 2, Dict())]

                    if ENABLE_PGFUNCS[]
                        if funcall == :feed || funcall == :feed_2 || funcall == :long_form_content_feed || funcall == :mega_feed_directive
                            push!(kwargs, :usepgfuncs=>true)
                        end
                    end

                    isnothing(conn.user[]) && for (k, v) in kwargs
                        if k == :user_pubkey 
                            try conn.user[] = Nostr.PubKeyId(v) catch _ end
                            break
                        end
                    end
                    user = conn.user[]

                    afc = app_funcall
                    if ENABLE_SPI[]
                        if (funcall == :feed_directive || funcall == :feed_directive_2) && startswith(Dict(kwargs)[:directive], "search;")
                            afc = app_funcall
                        elseif funcall in app_funcalls_external
                            afc = app_funcall_external(App().AppSPI)
                        end
                    elseif ENABLE_DIST[]
                        if funcall == :trending_hashtags_4h || funcall == :trending_hashtags_7d
                            afc = app_funcall
                        else
                            afc = app_funcall_external(App().AppDist)
                        end
                    end

                    tdur = @elapsed afc(funcall, kwargs, 
                        res->(App().content_moderation_filtering_2(est(), res, funcall, kwargs)) |> sendres; 
                        subid, ws_id)
                elseif funcall in App().exposed_async_functions
                    sendres([])
                else
                    send_error("unknown api request")
                end

            elseif haskey(filt, "ids")
                eids = []
                for s in filt["ids"]
                    try push!(eids, Nostr.EventId(s)) catch _ end
                end
                app_funcall(:events, [:event_ids=>eids], sendres; subid, ws_id=ws_id)

            elseif haskey(filt, "search")
                kinds = get(filt, "kinds", [1])
                if kinds == [0] && !haskey(filt, "since") && !haskey(filt, "until")
                    kwargs = [
                        :query=>filt["search"],
                        :limit=>get(filt, "limit", 10)
                    ]
                    app_funcall(:user_search, kwargs, sendres; subid, ws_id=ws_id)
                elseif kinds == [1]
                    kwargs = [
                        :query=>filt["search"],
                        :limit=>get(filt, "limit", 20),
                        :since=>get(filt, "since", 0),
                        :until=>get(filt, "until", nothing)
                    ]
                    app_funcall(:search, kwargs, sendres; subid, ws_id=ws_id)
                else
                    send_error("unsupported search filter")
                end

            elseif haskey(filt, "since") || haskey(filt, "until")
                kwargs = []
                for a in ["since", "until", "limit", "idsonly"]
                    haskey(filt, a) && push!(kwargs, Symbol(a)=>filt[a])
                end
                sendres(App().events(est(); kwargs...))
            end
        end
    catch ex
        PRINT_EXCEPTIONS[] && !(ex isa Base.IOError) && 
        ex isa TaskFailedException && (ex = ex.task.result)
        try send_error(ex isa ErrorException ? ex.msg : UNKNOWN_ERROR_MESSAGE[]) catch _ end
        if 1==0 && !(ex isa Base.IOError)
            PRINT_EXCEPTIONS[] && Utils.print_exceptions()
            println("initial_filter_handler: ", typeof(ex))
            @show err = (; t=Main.App.Dates.now(), extype=typeof(ex), ex=string(ex), filters)
            push!(Main.stuff, (:cache_server_handler_exception, err))
        end
    end
end

function close_connections()
    println("closing all websocket connections")
    @sync for conn in collect(values(conns))
        @async try lock(conn.ws) do ws; close(ws); end catch _ end
    end
end

function with_broadcast(body::Function, scope::Symbol)
    for conn in collect(values(conns))
        lock(conn.subs) do subs
            for (subid, filters) in subs
                for filt in filters
                    try
                        if body(conn, subid, filt) == true
                            @goto next
                        end
                    catch ex
                        push!(exceptions, (scope, filt, ex))
                    end
                end
                @label next
            end
        end
    end
end

function broadcast_network_stats(d)
    with_broadcast(:broadcast_network_stats) do conn, subid, filt
        if haskey(filt, "cache")
            if "net_stats" in filt["cache"]
                @async send(conn, JSON.json(["EVENT", subid, d]))
                return true
            end
        end
    end
end

netstats_task = Ref{Any}(nothing)
netstats_running = Ref(true)
NETSTATS_RATE = Ref(5.0)

periodic_log_stats = Throttle(; period=60.0)
periodic_directmsg_counts = Throttle(; period=1.0)

function netstats_start()
    @assert netstats_task[] |> isnothing
    netstats_running[] = true

    netstats_task[] = 
    errormonitor(@async while netstats_running[]
                     try
                         Base.invokelatest(netstats_handler)
                     catch ex
                         push!(exceptions, (:netstats, ex))
                     end
                     sleep(1/NETSTATS_RATE[])
                 end)
end

function netstats_stop()
    @assert !(netstats_task[] |> isnothing)
    netstats_running[] = false
    wait(netstats_task[])
    netstats_task[] = nothing
end

function netstats_handler()
    d = App().network_stats(est())
    broadcast_network_stats(d)

    periodic_log_stats() do
        lock(est().commons.stats) do cache_storage_stats
            MetricsLogger.log((; t=time(), cache_storage_stats))
        end
    end

    periodic_directmsg_counts() do
        MetricsLogger.log(r->(; funcall=:broadcast_directmsg_count)) do
            broadcast_directmsg_count()
        end
    end

    ext_periodic()
end

function broadcast_directmsg_count()
    with_broadcast(:broadcast_directmsg_count) do conn, subid, filt
        if haskey(filt, "cache")
            filt = filt["cache"]
            if length(filt) >= 2 
                if filt[1] == "directmsg_count"
                    pubkey = Nostr.PubKeyId(filt[2]["pubkey"])
                    for d in Base.invokelatest(App().get_directmsg_count, est(); receiver=pubkey)
                        @async send(conn, JSON.json(["EVENT", subid, d]))
                    end
                    return true
                elseif filt[1] == "directmsg_count_2"
                    pubkey = Nostr.PubKeyId(filt[2]["pubkey"])
                    for d in Base.invokelatest(App().get_directmsg_count_2, est(); receiver=pubkey)
                        @async send(conn, JSON.json(["EVENT", subid, d]))
                    end
                    return true
                end
            end
        end
    end
end

function broadcast(e::Nostr.Event)
    EVENT_IDS = App().EVENT_IDS
    with_broadcast(:broadcast) do conn, subid, filt
        if length(filt) == 1
            if haskey(filt, "since")
                @async send(conn, JSON.json(["EVENT", subid, e]))
            elseif get(filt, "idsonly", nothing) == true
                @async send(conn, JSON.json(["EVENT", subid, (; kind=Int(EVENT_IDS), ids=[e.id])]))
            end
        end
    end
end

end
