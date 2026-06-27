(* Nostr protocol types and verification, mirroring Julia src/nostr.jl (module Nostr).

   Ids, pubkeys and signatures are kept as raw byte strings (32/32/64 bytes); the wire
   form is lowercase hex. Tags are kept as parsed JSON values so the event-id
   serialization round-trips exactly. *)

(* A single tag is a JSON array, usually of strings (["e", <id>, <relay>, <marker>]). We
   keep the elements as Yojson values for fidelity when recomputing the event id. *)
type tag = Yojson.Safe.t list

type t = {
  id : string; (* 32 raw bytes *)
  pubkey : string; (* 32 raw bytes *)
  created_at : int;
  kind : int;
  tags : tag list;
  content : string;
  sig_ : string; (* 64 raw bytes *)
}

(* {1 Tag helpers} (mirror Julia tag.fields[i] access) *)

let tag_field (tg : tag) i : string option =
  match List.nth_opt tg i with Some (`String s) -> Some s | _ -> None

let tag_name (tg : tag) : string option = tag_field tg 0
let tag_len (tg : tag) : int = List.length tg

(* {1 Nostr event kinds} (Julia @enum Kind + extra consts in nostr.jl) *)

let kind_set_metadata = 0
let kind_text_note = 1
let kind_contact_list = 3
let kind_direct_message = 4
let kind_event_deletion = 5
let kind_repost = 6
let kind_reaction = 7
let kind_zap_receipt = 9735
let kind_mute_list = 10000
let kind_relay_list_metadata = 10002
let kind_categorized_people = 30000
let kind_long_form_content = 30023
let kind_bookmarks = 10003
let kind_highlight = 9802
let kind_picture = 20
let kind_follow_pack = 39089
let kind_reporting = 1984
let kind_poll = 1068
let kind_poll_vote = 1018
let kind_zap_poll = 6969
let kind_live_event = 30311
let kind_video_long_form = 34235
let kind_video_short_form = 34236
let kind_comment = 1111

(* Canonical NIP-01 serialization for the event id.

   The id is sha256 of the compact JSON array [0, pubkey_hex, created_at, kind, tags,
   content]. NIP-01 mandates UTF-8, no whitespace, and escaping ONLY of these characters
   in strings: newline, double-quote, backslash, carriage-return, tab, backspace, and
   form-feed. We must not use a general JSON printer (Yojson would escape control chars
   and non-ASCII differently). *)

let escape_string buf s =
  String.iter
    (fun c ->
      match c with
      | '\n' -> Buffer.add_string buf "\\n"
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\b' -> Buffer.add_string buf "\\b"
      | '\012' -> Buffer.add_string buf "\\f"
      | c -> Buffer.add_char buf c)
    s

let add_quoted buf s =
  Buffer.add_char buf '"';
  escape_string buf s;
  Buffer.add_char buf '"'

(* Serialize a JSON value (a tag element) in NIP-01 compact form. *)
let rec add_json buf (v : Yojson.Safe.t) =
  match v with
  | `String s -> add_quoted buf s
  | `Int i -> Buffer.add_string buf (string_of_int i)
  | `Intlit s -> Buffer.add_string buf s
  | `Bool b -> Buffer.add_string buf (if b then "true" else "false")
  | `Null -> Buffer.add_string buf "null"
  | `Float f -> Buffer.add_string buf (Yojson.Safe.to_string (`Float f))
  | `List l -> add_list buf l
  | `Assoc a ->
      Buffer.add_char buf '{';
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_char buf ',';
          add_quoted buf k;
          Buffer.add_char buf ':';
          add_json buf v)
        a;
      Buffer.add_char buf '}'
  | (`Tuple _ | `Variant _) as other ->
      (* Yojson-only constructors; should never appear in Nostr data. *)
      Buffer.add_string buf (Yojson.Safe.to_string other)

and add_list buf l =
  Buffer.add_char buf '[';
  List.iteri
    (fun i v ->
      if i > 0 then Buffer.add_char buf ',';
      add_json buf v)
    l;
  Buffer.add_char buf ']'

let serialize_for_id ~pubkey ~created_at ~kind ~tags ~content : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "[0,";
  add_quoted buf (Hex_util.encode pubkey);
  Buffer.add_char buf ',';
  Buffer.add_string buf (string_of_int created_at);
  Buffer.add_char buf ',';
  Buffer.add_string buf (string_of_int kind);
  Buffer.add_char buf ',';
  add_list buf (List.map (fun (tg : tag) -> `List tg) tags);
  Buffer.add_char buf ',';
  add_quoted buf content;
  Buffer.add_char buf ']';
  Buffer.contents buf

(* Julia: Nostr.event_id(...) — sha256 of the serialized event, as 32 raw bytes. *)
let event_id ~pubkey ~created_at ~kind ~tags ~content : string =
  serialize_for_id ~pubkey ~created_at ~kind ~tags ~content
  |> Digestif.SHA256.digest_string |> Digestif.SHA256.to_raw_string

let id_of (e : t) : string =
  event_id ~pubkey:e.pubkey ~created_at:e.created_at ~kind:e.kind ~tags:e.tags
    ~content:e.content

(* Julia: Nostr.verify(e) — id matches the serialization AND the Schnorr sig is valid. *)
let verify (e : t) : bool =
  String.equal e.id (id_of e)
  && Secp256k1.verify ~msg_hash:e.id ~serialized_pubkey:e.pubkey ~signature:e.sig_

(* {1 Parsing} (Julia dict2event / event_from_msg) *)

let of_json (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let tags =
    j |> member "tags" |> to_list |> List.map (fun tg -> to_list tg)
  in
  {
    id = Hex_util.decode_exn (j |> member "id" |> to_string);
    pubkey = Hex_util.decode_exn (j |> member "pubkey" |> to_string);
    created_at = j |> member "created_at" |> to_int;
    kind = j |> member "kind" |> to_int;
    tags;
    content = j |> member "content" |> to_string;
    sig_ = Hex_util.decode_exn (j |> member "sig" |> to_string);
  }

(* Julia: DB.event_from_msg(m) — a firehose line is
   [timestamp, metadata, ["EVENT", subscription_id, event]]. Returns the optional relay
   url (from metadata) and the parsed event. *)
let event_from_msg (j : Yojson.Safe.t) : (string option * t) option =
  let open Yojson.Safe.Util in
  match j with
  | `List (_ts :: md :: payload :: _) -> (
      match payload with
      | `List (`String "EVENT" :: _subid :: ev :: _) ->
          let relay =
            match md with
            | `Assoc _ -> ( try Some (md |> member "relay" |> to_string) with _ -> None)
            | _ -> None
          in
          Some (relay, of_json ev)
      | _ -> None)
  | _ -> None

let id_hex (e : t) : string = Hex_util.encode e.id
let pubkey_hex (e : t) : string = Hex_util.encode e.pubkey
