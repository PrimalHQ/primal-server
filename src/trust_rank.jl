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
    session = Postgres.make_session(server isa Symbol ? Postgres.servers[server].connstr : server)
    try
        # Create new table with same structure (including PK)
        Postgres.execute(session, "DROP TABLE IF EXISTS pubkey_trustrank_new")
        Postgres.execute(session, "CREATE UNLOGGED TABLE pubkey_trustrank_new (LIKE pubkey_trustrank INCLUDING ALL)")
        # Populate new table (no lock on live table)
        Postgres.transaction(session) do session
            for (i, (pk, rank)) in enumerate(tr_sorted)
                running[] || break
                if i % 1000 == 0
                    yield()
                    print("import_trustrank: $i / $(length(tr_sorted))\r")
                end
                rank > 0 && Postgres.execute(session,
                                             "insert into pubkey_trustrank_new values (\$1, \$2)",
                                             [pk, rank])
            end
        end
        # Analyze for query planner
        Postgres.execute(session, "ANALYZE pubkey_trustrank_new")
        # Atomic swap — ACCESS EXCLUSIVE lock held only for the instant of rename
        Postgres.transaction(session) do session
            # Drop dependent view
            Postgres.execute(session, "DROP VIEW IF EXISTS trusted_users_trusted_followers")
            # Swap tables
            Postgres.execute(session, "ALTER TABLE pubkey_trustrank RENAME TO pubkey_trustrank_old")
            Postgres.execute(session, "ALTER TABLE pubkey_trustrank_new RENAME TO pubkey_trustrank")
            Postgres.execute(session, "DROP TABLE pubkey_trustrank_old")
            # Recreate dependent view
            Postgres.execute(session, "CREATE VIEW trusted_users_trusted_followers AS
                SELECT pf.pubkey, tr1.rank AS pubkey_rank, pf.follower_pubkey, tr2.rank AS follower_pubkey_rank
                FROM pubkey_followers pf, pubkey_trustrank tr1, pubkey_trustrank tr2
                WHERE pf.pubkey = tr1.pubkey AND pf.follower_pubkey = tr2.pubkey")
        end
    finally
        try close(session) catch _ end
    end
    println()
end

end
