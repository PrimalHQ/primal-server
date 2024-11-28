module NostrClient

import JSON
import HTTP
import UUIDs
import Dates

import ..Utils
import ..Nostr

CONNECT_TIMEOUT = Ref(10)
READ_TIMEOUT = Ref(120)
PROXY = Ref{Any}(nothing)

mutable struct Client
    relay_url
    subid_prefix
    lock
    on_connect
    on_disconnect
    ws
    listener_running
    listener_task
    subscriptions
    events
    on_notice
    log_exceptions
    exceptions
    function Client(
            relay_url; 
            subid_prefix="", 
            on_connect=(_)->nothing, on_disconnect=(_)->nothing,
            on_notice=()->nothing,
        )
        client = new(relay_url, subid_prefix, 
                     ReentrantLock(),
                     on_connect, on_disconnect,
                     nothing, true, nothing, 
                     Dict{String, Any}(), Dict{Nostr.EventId, Any}(),
                     on_notice,
                     true, [])
        client.listener_task = @async listener(client)
        client
    end
end

function send(client::Client, vec::Vector)
    lock(client.lock) do
        HTTP.WebSockets.send(client.ws, JSON.json(vec))
    end
end

function closed(client::Client, subid::String)
    send(client, ["CLOSE", subid])
end

function subscription(
        client::Client, filters...; 
        on_response=(_)->nothing,
    )
    subid = "$(client.subid_prefix)$(UUIDs.uuid4())"
    client.subscriptions[subid] = (; filters, on_response)
    HTTP.WebSockets.send(client.ws, JSON.json(["REQ", subid, filters...]))
    subid
end

function subscription(body::Function, client::Client, filters...) 
    subscription(client, filters...; on_response=body)
end

function send(
        client::Client, e::Nostr.Event; 
        on_response=(_)->nothing,
    )
    client.events[e.id] = (; on_response)
    send(client, ["EVENT", e])
    nothing
end

function send(
        client::Client, filter::Union{NamedTuple,Dict};
        on_response=(_)->nothing,
    )
    subscription(client, filter; on_response)
end

# send(body::Function, client::Client, args...; kwargs...) = send(client, args...; on_response=body, kwargs...) # FIXME
# (client::Client)(body::Function, args...; kwargs...) = send(body, client, args...; kwargs...)
# (client::Client)(args...; kwargs...) = send(client, args...; kwargs...)

struct Timeout <: Exception
    description::String
end

function send(body::Function, client::Client, args...; timeout::Union{Real,Tuple{Real,String}}, kwargs...)
    period, desc = timeout isa Real ? (timeout, "timeout") : timeout
    r = Condition()
    @async begin
        sleep(period)
        notify(r, Timeout(desc); error=true)
    end
    send(client, args...; 
         on_response=function(msg)
             try
                 body(msg, v->notify(r, v))
             catch ex
                 notify(r, ex; error=true)
             end
         end, kwargs...)
    wait(r)
end

struct Notice <: Exception
    description::String
end

function req(client::Client, args...; timeout=5.0, kwargs...)
    r = []
    send(client, args...; timeout, kwargs...) do msg, done
        if msg[1] == "EOSE"
            done(msg)
        elseif msg[1] == "EVENT"
            push!(r, msg)
        end
    end
    r
end

function handle_message(client::Client, msg)
    msg_type = msg[1]
    if     msg_type in ["EVENT", "EOSE", "CLOSED"]
        client.subscriptions[msg[2]].on_response(msg)
        msg_type == "CLOSED" && delete!(client.subscriptions, msg[2])
    elseif msg_type == "OK"
        client.events[Nostr.EventId(msg[2])].on_response(msg)
        delete!(client.events, msg[2])
    elseif msg_type == "NOTICE"
        client.on_notice(msg)
    end
end

function listener(client::Client)
    while client.listener_running[]
        try
            HTTP.WebSockets.open(client.relay_url; retry=false, connect_timeout=CONNECT_TIMEOUT[], readtimeout=READ_TIMEOUT[], proxy=PROXY[]) do ws
                try
                    client.ws = ws
                    client.on_connect(client) # don't block!
                    for s in ws
                        client.listener_running[] || break
                        msg = JSON.parse(s)
                        try
                            Base.invokelatest(handle_message, client, msg)
                        catch _
                            client.log_exceptions && push!(client.exceptions, (; t=Dates.now(), exception=Utils.get_exceptions()))
                        end
                    end
                catch ex
                    # println("listener inner: ", typeof(ex))
                    ex isa EOFError || ex isa HTTP.WebSockets.WebSocketError || rethrow(ex)
                finally
                    try client.on_disconnect(client) catch _ end
                    try close(ws) catch _ end
                end
            end
        catch ex
            # println("listener outter: ", typeof(ex))
            break
        end
        sleep(0.2)
    end
    try close(client) catch _ end
end

function Base.close(client::Client, subid::String)
    HTTP.WebSockets.send(client.ws, JSON.json(["CLOSE", subid]))
    nothing
end

function Base.close(client::Client)
    client.listener_running = false
    try close(client.ws) catch _ end
    wait(client.listener_task)
    nothing
end

end
