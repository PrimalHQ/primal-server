module CacheServerSync

import ..Nostr
import ..Utils

include("rexec_client.jl")

PRINT_EXCEPTIONS = Ref(true)

MYSELF = Ref{Union{Nothing, Tuple{Int, Int}}}(nothing)
SRC = Ref((3,17))
PERIOD = Ref(5.0)

tsk = Ref{Any}(nothing)
running = Ref(false)
last_t = Ref(0.0)
last_duration = Ref(0.0)
progress = Ref{Any}(nothing)

function start()
    # @assert !isnothing(MYSELF[])
    @assert !running[]
    running[] = true
    tsk[] = errormonitor(@async while running[]
                             try
                                 last_duration[] = @elapsed pull_media(SRC[], MYSELF[])
                                 last_t[] = time()
                             catch _
                                 PRINT_EXCEPTIONS[] && Utils.print_exceptions()
                             end
                             Utils.active_sleep(PERIOD[], running)
                         end)
    nothing
end

function stop()
    @assert running[]
    running[] = false
    wait(tsk[])
    tsk[] = nothing
    nothing
end

function rex_(srvnode, expr)
    if isnothing(srvnode)
        Main.eval(expr)
    else
        rex(srvnode..., expr)
    end
end

function pull_media(src, dst)
    for (tbl, tblname, ty) in [
                               (:(Main.cache_storage.ext[].media), "media", Nothing),
                               (:(Main.cache_storage.ext[].event_media), "event_media", Nostr.EventId),
                              ]
        q = "select max(rowid) from $tblname"
        mr1 = rex_(dst, :(DB.exec($tbl, $q)[1][1]))
        mr2 = rex_(src, :(DB.exec($tbl, $q)[1][1]))

        n = 2000
        for i in mr1+1:n:mr2
            yield()
            r = i:min(i+n-1, mr2)
            progress[] = (r.start, mr2)
            q = "select * from $tblname where rowid >= $(r.start) and rowid <= $(r.stop)"
            for row in rex_(src, :(DB.exec($tbl, $q)))
                qi = "insert into $tblname values ($(join(['?' for _ in 1:length(row)], ',')))"
                if ty == Nothing
                    rex_(dst, :(DB.exec($tbl, $qi, $row)))
                else
                    args = (ty(row[1]), row[2:end]...)
                    rex_(dst, :(DB.exe($tbl, $qi, ($args)...)))
                end
            end
        end
    end
end

end

