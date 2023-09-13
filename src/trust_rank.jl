module TrustRank

import ..Nostr

pubkey_rank = Dict{Nostr.PubKeyId, Float64}()

humaness_threshold = Ref(0.0)
external_resources_threshold = Ref(0.0)

function load(tr)
    merge!(pubkey_rank, tr)
    sorted = sort(collect(pubkey_rank); by=x->-x[2])
    humaness_threshold[] = sorted[50000][2]
    external_resources_threshold[] = sorted[50000][2]
    nothing
end

end
