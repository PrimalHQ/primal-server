(* LNURL zapper verification, mirroring Julia src/cache_storage.jl:1271-1289.

   To confirm a zap receipt is genuine, we look up the *zapped* user's metadata, derive their
   LNURL-pay endpoint from lud16 / lud06, GET it (through the SOCKS5 proxy if configured), and
   check that the endpoint's advertised nostrPubkey equals the zap receipt's author. Any failure
   (missing metadata, bad URL, network error, mismatch) returns false. *)

(* Build the LNURL-pay URL from a metadata event's JSON content. lud16 ("name@domain") maps to
   https://domain/.well-known/lnurlp/name; lud06 is a bech32 "lnurl" that decodes to the URL. *)
let build_url (content : string) : string option =
  match Yojson.Safe.from_string content with
  | `Assoc kv -> (
      match List.assoc_opt "lud16" kv with
      | Some (`String lud16) when String.trim lud16 <> "" -> (
          match String.split_on_char '@' (String.trim lud16) with
          | [ name; domain ] when name <> "" && domain <> "" ->
              Some (Printf.sprintf "https://%s/.well-known/lnurlp/%s" domain name)
          | _ -> None)
      | _ -> (
          match List.assoc_opt "lud06" kv with
          | Some (`String lud06) when lud06 <> "" -> Bech32.lnurl_decode lud06
          | _ -> None))
  | _ -> None
  | exception _ -> None

(* Extract the raw 32-byte nostrPubkey from an LNURL-pay JSON response. *)
let extract_nostr_pubkey (body : string) : string option =
  match Yojson.Safe.from_string body with
  | `Assoc kv -> (
      match List.assoc_opt "nostrPubkey" kv with
      | Some (`String h) when String.length h = 64 -> Hex_util.decode_opt h
      | _ -> None)
  | _ -> None
  | exception _ -> None

let verify ~net ~clock ?proxy ?timeout (est : Cache_storage.est) ~(zapped_pk : string)
    ~(zapper_pubkey : string) : bool =
  match Cache_storage.get_meta_data_event est zapped_pk with
  | None -> false
  | Some md -> (
      match build_url md.content with
      | None -> false
      | Some url -> (
          match Http.parse_url url with
          | None -> false
          | Some u -> (
              match Http.https_get ~net ~clock ?proxy ?timeout u with
              | None -> false
              | Some body -> (
                  match extract_nostr_pubkey body with
                  | Some pk -> pk = zapper_pubkey
                  | None -> false))))
