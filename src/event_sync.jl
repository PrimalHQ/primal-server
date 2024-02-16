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
    imported = []
    i = 0
    for eids_chunk in Iterators.partition(missing_eids, 100)
        running[] || break
        yield()
        es = Main.rex(from..., :([cache_storage.events[eid] for eid in $(eids_chunk)]))
        for e in es
            running[] || break
            i += 1
            msg = JSON.json([nothing, nothing, ["EVENT", "", e]])
            DB.import_msg_into_storage(msg, est; disable_daily_stats=true) && push!(imported, e.id)
        end
        print("$i / $(length(imported)) / $(length(missing_eids))\r")
    end
    println()
    @show (length(imported), length(eids))
    imported
end

function event_ids_by_created_at(
        from::Tuple{Int, Int}, 
        since_hours=6, 
        since=trunc(Int, time()-since_hours*3600),
        until=trunc(Int, time()),
        limit=100000,
)
    eids = Main.rex(from..., :([Nostr.EventId(eid) for (eid,) in DB.exec(cache_storage.event_created_at, 
                                                                         "select event_id from kv where created_at >= ?1 and created_at <= ?2 limit ?3", 
                                                                         ($since, $until, $limit))]))
    @assert length(eids) < limit
    eids
end

end
