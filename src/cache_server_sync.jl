module CacheServerSync

import ..Nostr
import ..Utils

include("rexec_client.jl")

PRINT_EXCEPTIONS = Ref(true)
LOG = Ref(false)

MYSELF = Ref{Union{Nothing, Tuple{Int, Int}}}(nothing)
SRC = Ref{Any}(nothing)
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
                             isnothing(SRC[]) || try
                                 last_duration[] = @elapsed Base.invokelatest(pull_media, SRC[], MYSELF[])
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

function stop_unblock()
    @async begin
        running[] = false
        Threads.@threads :static for i in 1:Threads.nthreads()
            try @show (i, Base.throwto(tsk[], ErrorException("unblock")))
            catch ex println(ex) end
        end
    end
end

function rex_(srvnode, expr)
    if isnothing(srvnode)
        Main.eval(expr)
    else
        rex(srvnode..., expr)
    end
end

function pull_media(src, dst)
    for (tblsrc, tbldst, ty) in [
                                 (:(Main.cache_storage.ext[].media), :(Main.cache_storage.media), Nothing),
                                 (:(Main.cache_storage.ext[].event_media), :(Main.cache_storage.event_media), Nostr.EventId),
                                 (:(Main.cache_storage.ext[].preview), :(Main.cache_storage.preview), Nothing),
                                 (:(Main.cache_storage.ext[].event_preview), :(Main.cache_storage.event_preview), Nothing),
                                 (:(Main.cache_storage.dyn[:video_thumbnails]), :(Main.cache_storage.dyn[:video_thumbnails]), Nothing),
                                ]
        tblsrcname = rex_(src, :(($tblsrc).table))
        tbldstname = rex_(dst, :(($tbldst).table))

        q1 = "select max(rowid) from $tbldstname"
        q2 = "select max(rowid) from $tblsrcname"
        mr1 = rex_(dst, :(DB.exec($tbldst, $q1)[1][1]))
        mr2 = rex_(src, :(DB.exec($tblsrc, $q2)[1][1]))

        LOG[] && println(@__MODULE__, ": ", ((tbldstname, mr1), (tblsrcname, mr2)))

        ismissing(mr2) && continue
        ismissing(mr1) && (mr1 = 0)
        mr1 == mr2 && continue

        n = 2000
        for i in mr1+1:n:mr2
            running[] || break
            yield()
            r = i:min(i+n-1, mr2)
            progress[] = (tbldstname, r.start, mr2)
            q = "select *, rowid from $tblsrcname where rowid >= $(r.start) and rowid <= $(r.stop)"
            for row in rex_(src, :(DB.exec($tblsrc, $q)))
                qi = "insert into $tbldstname values ($(join(["?$i" for i in 1:length(row)], ','))) on conflict do nothing"
                if ty == Nothing
                    rex_(dst, :(DB.exec($tbldst, $qi, $row)))
                else
                    args = (ty(row[1]), row[2:end]...)
                    rex_(dst, :(DB.exe($tbldst, $qi, ($args)...)))
                end
            end
        end
    end
end

end

