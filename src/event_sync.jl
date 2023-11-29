module EventSync

import JSON

import ..Iterators

import ..Nostr
import ..DB

function import_from(
        from::Tuple{Int, Int}, 
        est::DB.CacheStorage=Main.cache_storage;
        since_hours=6, 
        since=trunc(Int, time()-since_hours*3600),
        until=trunc(Int, time()),
        limit=100000,
    )
    eids = Main.rex(from..., :([Nostr.EventId(eid) for (eid,) in DB.exec(est.event_created_at, 
                                                                         "select event_id from kv where created_at >= ?1 and created_at <= ?2 limit ?3", 
                                                                         ($since, $until, $limit))]))
    @assert length(eids) < limit
    missing_eids = []
    for (i, eid) in enumerate(eids)
        (i % 1000 == 0) && yield()
        eid in est.events || push!(missing_eids, eid)
    end
    imported = []
    i = 0
    for eids_chunk in Iterators.partition(missing_eids, 100)
        yield()
        for e in Main.rex(from..., :([est.events[eid] for eid in $(eids_chunk)]))
            i += 1
            msg = JSON.json([nothing, nothing, ["EVENT", "", e]])
            DB.import_msg_into_storage(msg, est) && push!(imported, e.id)
        end
        print("$i / $(length(missing_eids))\r")
    end
    println()
    @show length(imported)
    imported
end

end
