module Filterlist

using ..Utils: ThreadSafe
import ..Nostr

access_pubkey_blocked    = Set{Nostr.PubKeyId}() |> ThreadSafe
analytics_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_event_blocked    = Set{Nostr.EventId}() |> ThreadSafe
analytics_event_blocked = Set{Nostr.EventId}() |> ThreadSafe

function is_blocked(est, pubkey::Nostr.PubKeyId)::Bool
    pubkey in access_pubkey_blocked
end
function is_blocked(est, eid::Nostr.EventId)::Bool
    eid in access_event_blocked
end

end
