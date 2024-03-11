module TrustRank

import ..Nostr

pubkey_rank = Dict{Nostr.PubKeyId, Float64}()
pubkey_rank_sorted = Vector{Tuple{Nostr.PubKeyId, Float64}}()

humaness_threshold = Ref(0.0)
external_resources_threshold = Ref(0.0)

function load(tr)
    merge!(pubkey_rank, tr)
    sorted = sort(collect(pubkey_rank); by=x->-x[2])
    empty!(pubkey_rank_sorted)
    append!(pubkey_rank_sorted, [Tuple(p) for p in sorted])
    humaness_threshold[] = first(sorted, 50000)[end][2]
    external_resources_threshold[] = first(sorted, 100000)[end][2]
    nothing
end

end
