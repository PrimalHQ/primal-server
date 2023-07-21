module Filterlist

using ..Utils: ThreadSafe
import ..Nostr

import_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_pubkey_blocked    = Set{Nostr.PubKeyId}() |> ThreadSafe
analytics_pubkey_blocked = Set{Nostr.PubKeyId}() |> ThreadSafe

access_event_blocked    = Set{Nostr.EventId}() |> ThreadSafe
analytics_event_blocked = Set{Nostr.EventId}() |> ThreadSafe

end
