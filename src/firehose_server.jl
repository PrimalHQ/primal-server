module FirehoseServer

using Sockets
using DataStructures: CircularBuffer, SortedDict
import JSON

import ..Utils
using ..Utils: ThreadSafe, wait_for

const HOST = Ref("127.0.0.1")
const PORT = Ref(9000)

const PRINT_EXCEPTIONS = Ref(true)

const server = Ref{Any}(nothing)
const listen_task = Ref{Any}(nothing)
const cleanup_task = Ref{Any}(nothing)

const latest_sent_messages = ThreadSafe(CircularBuffer(50))

const connections = ThreadSafe(TCPSocket[])
const stream_conns = ThreadSafe(TCPSocket[])

const latest_received_messages = ThreadSafe(CircularBuffer(50))
const latest_exceptions = ThreadSafe(CircularBuffer(50))

const message_processors = ThreadSafe(SortedDict{Symbol, Function}())

isactive() = !isnothing(server[])

function start()
    @assert isempty(connections)

    empty!(latest_sent_messages)
    empty!(latest_received_messages)
    empty!(latest_exceptions)

    listen_task[] = 
    errormonitor(@async begin
                     server[] = listen(IPv4(HOST[]), PORT[])
                     @info "started message firehose server on port $(PORT[]), thread id: $(Threads.threadid())"
                     try
                         while true
                             try
                                 sock = accept(server[])
                                 @debug "accepted connection $sock"
                                 push!(connections, sock)
                                 start_reader_task(sock)
                             catch IOError
                                 break
                             end
                         end
                     finally
                         server[] = nothing
                     end
                     @debug "server is closed"
                 end)

    cleanup_task[] = 
    errormonitor(@async while isactive() || !isempty(connections)
                     lock(connections) do conns
                         deleted = []
                         for sock in conns
                             if !isopen(sock) || !iswritable(sock)|| !isreadable(sock)
                                 try
                                     try write(sock, "bye") catch _ end
                                     try close(sock) catch _ end
                                 catch _ end
                                 @debug "$sock is closed"
                                 push!(deleted, sock)
                             end
                         end
                         filter!(s->!(s in deleted), conns)
                     end
                     sleep(1)
                 end)

    start_channel_task()
end

function stop()
    stop_channel_task()
    try close(server[]) catch _ end
    lock(connections) do conns
        for sock in conns
            try write(sock, "bye") catch _ end
            try close(sock) catch _ end
        end
    end
    wait_for(()->isempty(connections) && !isactive(); dt=0.5)
    wait(cleanup_task[])
    listen_task[] = cleanup_task[] = nothing
    @info "stopped message firehose server on port $(PORT[])"
end

function start_reader_task(sock)
    errormonitor(@async begin
                     while isactive() && isopen(sock) && isreadable(sock)
                         s = readline(sock)
                         isempty(s) && break
                         push!(latest_received_messages, s)
                         if s == "STREAM-NEW-EVENTS"
                             push!(stream_conns, sock)
                         else
                             lock(message_processors) do mprocs
                                 for mproc in values(mprocs)
                                     r = try
                                         Base.invokelatest(mproc, s)
                                     catch ex
                                         PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                                         push!(latest_exceptions, (s, mproc, ex))
                                         ["ERROR", string(typeof(ex))]
                                     end
                                     try println(sock, JSON.json(r)) catch _ end
                                 end
                             end
                         end
                     end
                     try close(sock) catch _ end
                     lock(connections) do conns
                         filter!(s->s !== sock, conns)
                     end
                     lock(stream_conns) do stream_conns
                         filter!(s->s !== sock, stream_conns)
                     end
                 end)
end

function broadcast(msgs::Vector{String}) # it's better to use broadcast_via_channel
    lock(latest_sent_messages) do lmsgs
        for msg in msgs
            push!(lmsgs, msg)
        end
    end
    lock(connections) do conns
        for sock in conns
            sock in stream_conns || continue
            try
                for msg in msgs
                    println(sock, msg)
                end
            catch IOError
                try close(sock) catch _ end
            end
        end
    end
end

const chan = Ref{Any}(nothing)
const chan_task = Ref{Any}(nothing)
const chan_running = Ref(true)
const chan_cnt = Ref(0)
function start_channel_task()
    chan_running[] = true
    chan[] = Channel{Any}(20_000)
    chan_task[] = errormonitor(@async while chan_running[]
                                   msgs = take!(chan[])
                                   if !isempty(msgs)
                                       broadcast(msgs)
                                       chan_cnt[] += 1
                                   end
                               end)
end
function stop_channel_task()
    isnothing(chan_task[]) && return
    chan_running[] = false
    put!(chan[], [])
    wait(chan_task[])
    chan_task[] = nothing
end

broadcast_via_channel(msgs::Vector{String}) = !Utils.isfull(chan[]) && put!(chan[], msgs)

end
