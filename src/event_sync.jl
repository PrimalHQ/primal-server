module EventSync

import JSON

import ..Iterators

import ..Utils
import ..Nostr
import ..DB

function import_from(
        from::Tuple{Int, Int}, 
        eids::Vector{Nostr.EventId},
        est::DB.CacheStorage=Main.cache_storage;
        # running=Ref(true),
        running=Utils.PressEnterToStop(),
    )
    missing_eids = []
    for (i, eid) in enumerate(eids)
        running[] || break
        if i % 1000 == 0
            yield()
            print("$(length(missing_eids)) / $i\r")
        end
        eid in est.events || push!(missing_eids, eid)
    end
    println()
    imported = [] |> Utils.ThreadSafe
    i = Ref(0) |> Utils.ThreadSafe
    Threads.@threads for eids_chunk in collect(Iterators.partition(map(Nostr.hex, missing_eids), 100))
        running[] || break
        yield()
        es = Main.rex(from..., :([Main.cache_storage.events[Nostr.EventId(eid)]
                                  for eid in $(eids_chunk)
                                  if Nostr.EventId(eid) in Main.cache_storage.events]))
        for e in es
            running[] || break
            DB.incr(i)
            DB.import_event(est, e; disable_daily_stats=true) && push!(imported, e.id)
        end
        lock(i) do i
            print("$(i[]) / $(length(imported)) / $(length(missing_eids))\r")
        end
    end
    println()
    @show (length(imported), length(eids))
    collect(imported)
end

function event_ids_by_created_at(
        from::Tuple{Int, Int}; 
        since_hours=6, 
        since=trunc(Int, time()-since_hours*3600),
        until=trunc(Int, time()),
        limit=100000,
)
    eids = Main.rex(from..., :([Nostr.EventId(eid) for (eid,) in DB.exec(Main.cache_storage.event_created_at, 
                                                                         "select event_id from event_created_at where created_at >= ?1 and created_at <= ?2 limit ?3", 
                                                                         ($since, $until, $limit))]))
    @assert length(eids) < limit
    eids
end

end
