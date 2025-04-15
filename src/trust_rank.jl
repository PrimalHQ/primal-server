module TrustRank

import ..Nostr
using ..Utils: ThreadSafe
import ..Postgres

pubkey_rank = Dict{Nostr.PubKeyId, Float64}() |> ThreadSafe
pubkey_rank_sorted = Vector{Tuple{Nostr.PubKeyId, Float64}}() |> ThreadSafe

humaness_threshold = Ref(0.0)
external_resources_threshold = Ref(0.0)

function load(tr)
    lock(pubkey_rank) do pubkey_rank
        lock(pubkey_rank_sorted) do pubkey_rank_sorted
            merge!(pubkey_rank, tr)
            sorted = sort(collect(pubkey_rank); by=x->-x[2])
            empty!(pubkey_rank_sorted)
            append!(pubkey_rank_sorted, [Tuple(p) for p in sorted])
            humaness_threshold[] = first(sorted, 50000)[end][2]
            external_resources_threshold[] = first(sorted, 100000)[end][2]
            nothing
        end
    end
end

function import_trustrank(server, tr_sorted::Vector; running=Ref(true))
    session = Postgres.make_session(Postgres.servers[server].connstr)
    try
        Postgres.transaction(session) do session
            Postgres.execute(session, "truncate pubkey_trustrank")
            for (i, (pk, rank)) in enumerate(tr_sorted)
                running[] || break
                if i % 1000 == 0
                    yield()
                    print("import_trustrank: $i / $(length(tr_sorted))\r")
                end
                rank > 0 && Postgres.execute(session, 
                                             "insert into pubkey_trustrank values (\$1, \$2)",
                                             [pk, rank])
            end
        end
    finally
        try close(session) catch _ end
    end
    println()
end

end
