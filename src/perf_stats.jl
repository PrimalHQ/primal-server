module PerfStats

import Dates

using ..Utils: ThreadSafe
import ..Clocks

tstart = Ref(0.0) |> ThreadSafe

collections = Dict() |> ThreadSafe

function get_collection(d::Symbol)
    c = lock(collections) do collections
        get!(collections, d) do; (; d=Dict(), tstart=Ref(time())) |> ThreadSafe; end
    end
end

function reset!()
   empty!(collections)
   nothing
end

function reset!(d::Symbol)
    lock(get_collection(d)) do c
        c.tstart[] = time()
        empty!(c.d)
    end
end

function report(d::Symbol; by=x->x.avgduration)
    lock(get_collection(d)) do c
        totalduration = sum([v.duration for (k, v) in collect(c.d)])
        sort([k=>(; v..., 
                  durationperc=v.duration/totalduration, 
                  wallperc=v.duration/(Threads.nthreads()*(time()-tstart[])),
                  avgduration=v.duration/v.count,
                  avgcpuusage=v.cpuusage/v.count,
                  avgallocs=v.allocs/v.count,
                  avgallocbytes=v.allocbytes/v.count,
                 ) 
              for (k, v) in collect(c.d)]; by=x->-by(x[2]))
    end
end

function mkmetrics()
    (; 
     count=0, 
     duration=0.0, 
     cpuusage=0.0, 
     maxduration=0.0, 
     maxcpuusage=0.0,
     allocbytes=0,
     allocs=0,
     disktime=0,
     readbytes=0,
     readcalls=0,
     writebytes=0,
     writecalls=0,
    )
end

function record!(body::Function, d::Symbol, key)
    sticky = Base.current_task().sticky

    tid1 = Threads.threadid()
    cput1 = sticky ? Clocks.clock_gettime(Clocks.CLOCK_THREAD_CPUTIME_ID) : 0.0

    t = @timed body()

    tid2 = Threads.threadid()
    cput2 = sticky ? Clocks.clock_gettime(Clocks.CLOCK_THREAD_CPUTIME_ID) : 0.0

    cpuusage = tid1 == tid2 ? (cput2-cput1)/1e9 : 0.0

    lock(get_collection(d)) do c
        r = get!(mkmetrics, c.d, key)
        c.d[key] = (; 
                    count=r.count+1, 
                    duration=r.duration+t.time,
                    cpuusage=r.cpuusage+cpuusage,
                    maxduration=max(r.maxduration, t.time),
                    maxcpuusage=max(r.maxcpuusage, cpuusage),
                    allocbytes=r.allocbytes+t.bytes,
                    allocs=r.allocs+Base.gc_alloc_count(t.gcstats),
                    disktime=0,
                    readbytes=0,
                    readcalls=0,
                    writebytes=0,
                    writecalls=0,
                   )
    end

    t.value
end

function recordspi!(body::Function, d::Symbol, backendpid::Int, key)
    u1 = Main.DAG.process_usage_stats(backendpid)

    t = @timed body()

    u2 = Main.DAG.process_usage_stats(backendpid)

    u = u2 - u1

    cpuusage = u.cputime

    lock(get_collection(d)) do c
        r = get!(mkmetrics, c.d, key)
        c.d[key] = (; 
                    count=r.count+1, 
                    duration=r.duration+t.time,
                    cpuusage=r.cpuusage+cpuusage,
                    maxduration=max(r.maxduration, t.time),
                    maxcpuusage=max(r.maxcpuusage, cpuusage),
                    allocbytes=r.allocbytes+0,
                    allocs=r.allocs+0,
                    disktime=r.disktime+u.disktime,
                    readbytes=r.readbytes+u.readbytes,
                    readcalls=r.readcalls+u.readcalls,
                    writebytes=r.writebytes+u.writebytes,
                    writecalls=r.writecalls+u.writecalls,
                   )
    end

    t.value
end

end
