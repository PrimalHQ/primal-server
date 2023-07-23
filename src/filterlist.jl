module Filterlist

using Serialization: serialize, deserialize

using ..Utils: ThreadSafe
import ..Nostr

import_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_pubkey_blocked    = Set{Nostr.PubKeyId}() |> ThreadSafe
analytics_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_event_blocked    = Set{Nostr.EventId}() |> ThreadSafe
analytics_event_blocked = Set{Nostr.EventId}() |> ThreadSafe

function save(dest::Union{String, IOBuffer})
    d = Dict()
    for n in names(@__MODULE__; all=true)
        if !startswith(string(n), '#') && endswith(string(n), "_blocked") && (occursin("_pubkey_", string(n)) || occursin("_event_", string(n)))
            d[n] = lock(getproperty(@__MODULE__, n)) do v; copy(v); end
        end
    end
    serialize(dest, d)
end

function load(src::Union{String, IOBuffer})
    d = deserialize(src)
    for (n, v) in d
        lock(getproperty(@__MODULE__, n)) do s
            copy!(s, v)
        end
    end
end

end
