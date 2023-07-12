module Filterlist

using ..Utils: ThreadSafe
import ..Nostr

pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe
event_blocked = Set{Nostr.EventId}() |> ThreadSafe

function is_blocked(est, pubkey::Nostr.PubKeyId)::Bool
    pubkey in pubkey_blocked
end
function is_blocked(est, eid::Nostr.EventId)::Bool
    eid in event_blocked
end

end
