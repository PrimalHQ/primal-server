module RelayScanning

import JSON
import DataStructures
import HTTP

using ..Utils
import ..Utils
import ..Fetching

function collect_relays(cache_storage; proxy=nothing)
    ##
    relays = DataStructures.Accumulator{String,Int}() |> ThreadSafe
    error_kinds = DataStructures.Accumulator{String,Int}()|>ThreadSafe
    ##
    for url in JSON.parse(String(HTTP.request("GET", "https://api.nostr.watch/v1/online"; proxy).body))
        relays[url] += 1
    end
    ##
    eids = collect(values(cache_storage.contact_lists))
    Utils.process_collection(eids; error_kinds) do eid
        for url in collect(keys(JSON.parse(cache_storage.events[eid].content)))
            relays[url] += 1
        end
        ()->" relays:$(length(relays))"
    end
    ##
    eids = collect(values(cache_storage.dyn[:relay_list_metadata]))
    Utils.process_collection(eids; error_kinds) do eid
        for url in [t.fields[2] for t in cache_storage.events[eid].tags 
                    if length(t.fields) >= 2 && t.fields[1] == "r"]
            relays[url] += 1
        end
        ()->" relays:$(length(relays))"
    end
    ##
    (; relays, error_kinds)
end

function scan_relays(
        relays; 
        running=Utils.PressEnterToStop()|>ThreadSafe,
        valid_cb=(_)->nothing,
        proxy=nothing,
        timeout=10,
    )
    seen_relays = Set() |> ThreadSafe
    valid_relays = Set() |> ThreadSafe
    i = Ref(0) |> ThreadSafe
    tstart = time()
    asyncmap(collect(sort(collect(relays); by=r->-r[2])) #= [1:100] =#; ntasks=200) do (url, _)
        running[] || return
        i[] += 1
        print("$(i[])/$(length(relays))  t:$(trunc(Int, time()-tstart))s  valid:$(length(valid_relays))\r")
        if !isnothing(local u = try Fetching.sanitize_valid_relay_url(url) catch _ end)
            u = string(u)
            startswith(u, "ws") || return
            lock(seen_relays) do seen_relays
                r = u in seen_relays 
                push!(seen_relays, u)
                r
            end && return
            if try
                    HTTP.WebSockets.open(u; connect_timeout=timeout, readtimeout=timeout, timeout=timeout, proxy) do ws
                        close(ws)
                    end
                    true
                catch _
                    false
                end
                push!(valid_relays, u)
                valid_cb(u)
            end
        end
    end
    collect(valid_relays)
end

function scan_relays_to_file(
        relays; 
        output_filename="relays-mined-from-contact-lists.txt",
        valid_cb=(_)->nothing,
        kwargs...
    )
    valid_relays = []
    scan_relays(relays; 
                valid_cb=function (url) 
                    push!(valid_relays, url)
                end, 
                kwargs...)
    open(output_filename, "w+") do fout
        for url in sort(valid_relays)
            println(fout, url)
        end
    end
end

end
