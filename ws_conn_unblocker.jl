module WSConnUnblocker

import HTTP
import Dates

import ..CacheServerHandlers

DELETE_AFTER_PERIODS = Ref(15)

running = Ref(true)
tsk = Ref{Any}(nothing)

locked = Dict()

function start()
    @assert isnothing(tsk[])
    tsk[] = errormonitor(@async monitor_conns())
end

function stop()
    @assert !isnothing(tsk[])
    running[] = false
    wait(tsk[])
    tsk[] = nothing
end

function monitor_conns()
    while running[]
        s = Set()
        for c in collect(CacheServerHandlers.conns)
            if !isnothing(c.second.ws.lock.locked_by)
                ws = c.first
                push!(s, ws)
            end
        end
        for ws in keys(locked)
            ws in s || delete!(locked, ws)
        end
        for ws in s
            locked[ws] = get(locked, ws, 0) + 1
            if locked[ws] >= DELETE_AFTER_PERIODS[]
                println(Dates.now(), "  closing blocked websocket connection: $(ws.id)")
                delete!(locked, ws)
                HTTP.WebSockets.close(ws)
            end
        end
        sleep(1+rand()*0.5)
    end
end

end
