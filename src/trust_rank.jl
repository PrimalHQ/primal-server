module TrustRank

import ..Nostr

pubkey_rank = Dict{Nostr.PubKeyId, Float64}()

humaness_threshold = Ref(0.0)

function load(tr)
    merge!(pubkey_rank, tr)
    humaness_threshold[] = sort(collect(pubkey_rank); by=x->-x[2])[50000][2]
end

end
