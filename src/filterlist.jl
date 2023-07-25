module Filterlist

using ..Utils: ThreadSafe
import ..Nostr

import_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_pubkey_blocked    = Set{Nostr.PubKeyId}() |> ThreadSafe
analytics_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_event_blocked    = Set{Nostr.EventId}() |> ThreadSafe
analytics_event_blocked = Set{Nostr.EventId}() |> ThreadSafe

access_pubkey_unblocked    = Set{Nostr.PubKeyId}() |> ThreadSafe
analytics_pubkey_unblocked = Set{Nostr.PubKeyId}() |> ThreadSafe

function get_dict()
    d = Dict()
    for n in names(@__MODULE__; all=true)
        if !startswith(string(n), '#') && endswith(string(n), "_blocked") && (occursin("_pubkey_", string(n)) || occursin("_event_", string(n)))
            d[n] = lock(getproperty(@__MODULE__, n)) do v; copy(v); end
        end
    end
    d
end

function load(d::Dict)
    for (n, v) in d
        lock(getproperty(@__MODULE__, Symbol(n))) do s
            ty = typeof(s).parameters[1]
            v = Set([e isa ty ? e : ty(e) for e in v])
            copy!(s, v)
        end
    end
end

end
