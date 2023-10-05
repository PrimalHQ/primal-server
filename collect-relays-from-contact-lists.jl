##
@time eids=collect(values(cache_storage.contact_lists))
##
running=Utils.PressEnterToStop()
relays=Utils.DataStructures.Accumulator{String,Int}()
errs=Ref(0)
@time for (i, eid) in enumerate(eids)
    yield()
    running[] || break
    i % 1000 == 0 && print("$i/$(length(eids))  \r")
    try for url in collect(keys(JSON.parse(cache_storage.events[eid].content))); relays[url]+=1; end
    catch _ errs[]+=1 end
end
errs
##
running=Utils.PressEnterToStop()
@time open("relays-mined-from-contact-lists.txt", "w+") do f
    r = Set() |> Utils.ThreadSafe
    i = Ref(0) |> Utils.ThreadSafe
    tstart = time()
    asyncmap(collect(sort(collect(relays); by=r->-r[2])) #= [1:100] =#; ntasks=200) do (url, _)
        running[] || return
        DB.incr(i)
        print("$(i[])/$(length(relays))  $(trunc(Int, time()-tstart))s  $(length(r))   \r")
        if !isnothing(local u = try Fetching.sanitize_valid_relay_url(url) catch _ end)
            startswith(string(u), "ws") || return
            if try
                    HTTP.WebSockets.open(string(u); connect_timeout=2, readtimeout=2, timeout=2, proxy=Fetching.PROXY_URI[]) do ws
                        close(ws)
                    end
                    true
                catch _
                    false
                end
                println("valid: $u")
                push!(r, string(u))
                println(f, string(u))
            else
                println("invalid: $u")
            end
        end
    end
    # for u in collect(r)
    #     println(f, u)
    # end
end
##
