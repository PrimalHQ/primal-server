(* Clean OCaml mappings for the PostgreSQL USER-DEFINED enum types, so inline [%pgsql]
   queries need no `::text` casts. PGOCaml's ppx, on encountering a column of PG type
   `filterlist_target`, emits calls to the unqualified `string_of_filterlist_target` /
   `filterlist_target_of_string`; we provide those (and a real OCaml variant) here, and
   `open Pg_types` wherever such columns are queried.

   bytea, jsonb, int8 etc. already marshal cleanly (string / string / int64) and need no
   help. *)

type filterlist_target = Pubkey | Event

let string_of_filterlist_target = function Pubkey -> "pubkey" | Event -> "event"

let filterlist_target_of_string = function
  | "pubkey" -> Pubkey
  | "event" -> Event
  | s -> invalid_arg ("filterlist_target_of_string: " ^ s)

type filterlist_grp =
  | Spam
  | Nsfw
  | Csam
  | Impersonation
  | In_app_purchase
  | Trending

let string_of_filterlist_grp = function
  | Spam -> "spam"
  | Nsfw -> "nsfw"
  | Csam -> "csam"
  | Impersonation -> "impersonation"
  | In_app_purchase -> "in_app_purchase"
  | Trending -> "trending"

let filterlist_grp_of_string = function
  | "spam" -> Spam
  | "nsfw" -> Nsfw
  | "csam" -> Csam
  | "impersonation" -> Impersonation
  | "in_app_purchase" -> In_app_purchase
  | "trending" -> Trending
  | s -> invalid_arg ("filterlist_grp_of_string: " ^ s)
