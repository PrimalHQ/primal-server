module FirehoseClient

using Sockets
using DataStructures: CircularBuffer, SortedDict

import ..Utils
using ..Utils: ThreadSafe, wait_for

HOST = Ref("127.0.0.1")
PORT = Ref(9000)

running = Ref(false)
sock = Ref{Any}(nothing)
task = Ref{Any}(nothing)

latest_messages = ThreadSafe(CircularBuffer(50))
latest_exceptions = ThreadSafe(CircularBuffer(50))

message_processors = ThreadSafe(SortedDict{Symbol, Function}())

isactive() = !isnothing(task[]) && !istaskdone(task[])

function start()
    @assert !isactive() && isnothing(sock[])

    empty!(latest_messages)
    empty!(latest_exceptions)

    running[] = true

    task[] = 
    errormonitor(@async while running[]
                     try
                         sock[] = connect(HOST[], PORT[])
                         @debug "connected to firehose server"
                         try
                             while running[]
                                 try
                                     s = readline(sock[])
                                     isempty(s) && break
                                     push!(latest_messages, s)
                                     lock(message_processors) do mprocs
                                         for mproc in values(mprocs)
                                             try
                                                 Base.invokelatest(mproc, s)
                                             catch ex
                                                 #Utils.print_exceptions()
                                                 push!(latest_exceptions, (s, mproc, ex))
                                             end
                                         end
                                     end
                                 catch IOError
                                     break
                                 end
                             end
                         finally
                             try close(sock[]) catch _ end
                             sock[] = nothing
                             @debug "client disconnected"
                         end
                     catch ex
                         push!(latest_exceptions, ex)
                     end
                     sleep(1)
                 end)
    nothing
end

function stop()
    running[] = false
    wait_for(()->!isactive(); dt=0.5)
    nothing
end

end
