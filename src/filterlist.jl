module Filterlist

import JSON
using DataStructures: OrderedSet

using ..Utils: ThreadSafe, Throttle
import ..Nostr

import_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_pubkey_blocked    = Set{Nostr.PubKeyId}() |> ThreadSafe
analytics_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_event_blocked    = Set{Nostr.EventId}() |> ThreadSafe
analytics_event_blocked = Set{Nostr.EventId}() |> ThreadSafe

access_pubkey_unblocked    = Set{Nostr.PubKeyId}() |> ThreadSafe
analytics_pubkey_unblocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_pubkey_blocked_spam = OrderedSet{Nostr.PubKeyId}() |> ThreadSafe
access_pubkey_unblocked_spam = Set{Nostr.PubKeyId}() |> ThreadSafe
access_event_blocked_spam  = OrderedSet{Nostr.EventId}() |> ThreadSafe

access_pubkey_blocked_nsfw = Set{Nostr.PubKeyId}() |> ThreadSafe
access_pubkey_unblocked_nsfw = Set{Nostr.PubKeyId}() |> ThreadSafe

function get_dict()
    d = Dict()
    for n in names(@__MODULE__; all=true)
        if  !startswith(string(n), '#') && 
            (endswith(string(n), "_blocked") || endswith(string(n), "_unblocked")) && 
            (occursin("_pubkey_", string(n)) || occursin("_event_", string(n)))
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

function is_hidden(eid::Nostr.EventId)
    eid in access_event_blocked || eid in access_event_blocked_spam
end

periodic_unblocked_pubkeys = Throttle(; period=5.0, t=0.0)
DEFAULT_UNBLOCKED_PUBKEYS_FILE = Ref("unblocked-pubkeys.json")

function is_hidden(pubkey::Nostr.PubKeyId)
    periodic_unblocked_pubkeys() do
        if isfile(DEFAULT_UNBLOCKED_PUBKEYS_FILE[])
            copy!(access_pubkey_unblocked,
                  Set(try [Nostr.PubKeyId(pk) for (pk, _) in JSON.parse(read(DEFAULT_UNBLOCKED_PUBKEYS_FILE[], String))]
                      catch _; [] end))
        end
    end

    (pubkey in access_pubkey_blocked || pubkey in import_pubkey_blocked) && !(pubkey in access_pubkey_unblocked)
end

end
