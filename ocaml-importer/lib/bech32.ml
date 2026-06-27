(* Bech32 / Bech32m decoding, mirroring Julia src/bech32.jl (module Bech32).

   Used for LNURL lud06 decoding (zapper verification). The nip19 TLV decoders (nevent /
   naddr / nprofile) used by for_mentiones content mentions are a TODO — only the generic
   decode needed for LNURL is implemented here. *)

let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
let bech32m_const = 0x2bc830a3

let charset_index c =
  (* position of [c] in [charset], or -1 *)
  match String.index_opt charset c with Some i -> i | None -> -1

let polymod (values : int list) : int =
  let generator = [| 0x3b6a57b2; 0x26508e6d; 0x1ea119fa; 0x3d4233dd; 0x2a1462b3 |] in
  let chk = ref 1 in
  List.iter
    (fun v ->
      let top = !chk lsr 25 in
      chk := ((!chk land 0x1ffffff) lsl 5) lxor v;
      for i = 0 to 4 do
        if (top lsr i) land 1 <> 0 then chk := !chk lxor generator.(i)
      done)
    values;
  !chk

let hrp_expand (hrp : string) : int list =
  let hi = List.init (String.length hrp) (fun i -> Char.code hrp.[i] lsr 5) in
  let lo = List.init (String.length hrp) (fun i -> Char.code hrp.[i] land 31) in
  hi @ [ 0 ] @ lo

(* BECH32 (=1) | BECH32M (=2) | None *)
let verify_checksum hrp data =
  match polymod (hrp_expand hrp @ data) with
  | 1 -> Some `Bech32
  | c when c = bech32m_const -> Some `Bech32m
  | _ -> None

let is_all_lower s = String.lowercase_ascii s = s
let is_all_upper s = String.uppercase_ascii s = s

(* (hrp, data-without-checksum) on success. data values are 5-bit groups. *)
let bech32_decode (bech : string) : (string * int list) option =
  let n = String.length bech in
  let bad_char = ref false in
  String.iter (fun c -> if Char.code c < 33 || Char.code c > 126 then bad_char := true) bech;
  if !bad_char || not (is_all_lower bech || is_all_upper bech) then None
  else begin
    let bech = String.lowercase_ascii bech in
    match String.rindex_opt bech '1' with
    | None -> None
    | Some pos when pos + 6 >= n || pos = 0 -> None
    | Some pos ->
        let ok = ref true in
        let data = ref [] in
        for i = n - 1 downto pos + 1 do
          let v = charset_index bech.[i] in
          if v < 0 then ok := false else data := v :: !data
        done;
        if not !ok then None
        else
          let hrp = String.sub bech 0 pos in
          let data = !data in
          (match verify_checksum hrp data with
          | None -> None
          | Some _ ->
              (* drop the 6-symbol checksum *)
              let len = List.length data - 6 in
              Some (hrp, List.filteri (fun i _ -> i < len) data))
  end

(* Julia convertbits(data, frombits, tobits; pad). Returns None on invalid padding. *)
let convertbits (data : int list) ~frombits ~tobits ~pad : int list option =
  let acc = ref 0 and bits = ref 0 and ret = ref [] in
  let maxv = (1 lsl tobits) - 1 in
  let max_acc = (1 lsl (frombits + tobits - 1)) - 1 in
  let ok = ref true in
  List.iter
    (fun v ->
      if v < 0 || v lsr frombits <> 0 then ok := false
      else begin
        acc := ((!acc lsl frombits) lor v) land max_acc;
        bits := !bits + frombits;
        while !bits >= tobits do
          bits := !bits - tobits;
          ret := ((!acc lsr !bits) land maxv) :: !ret
        done
      end)
    data;
  if not !ok then None
  else if pad then begin
    if !bits <> 0 then ret := ((!acc lsl (tobits - !bits)) land maxv) :: !ret;
    Some (List.rev !ret)
  end
  else if !bits >= frombits || (!acc lsl (tobits - !bits)) land maxv <> 0 then None
  else Some (List.rev !ret)

(* Julia decode(hrp, addr): bech32_decode then 5->8 bit conversion (no padding). Returns the
   decoded 8-bit bytes as a string, or None on mismatch. *)
let decode ~hrp (addr : string) : string option =
  match bech32_decode addr with
  | Some (hrpgot, data) when hrpgot = hrp -> (
      match convertbits data ~frombits:5 ~tobits:8 ~pad:false with
      | Some bytes -> Some (String.init (List.length bytes) (fun i -> Char.chr (List.nth bytes i)))
      | None -> None)
  | _ -> None

(* LNURL (lud06): an "lnurl"-HRP bech32 string whose payload is the ASCII URL. *)
let lnurl_decode (lnurl : string) : string option = decode ~hrp:"lnurl" lnurl

(* {1 NIP-19} (mirrors Julia Bech32.nip19_decode) — enough for for_mentiones content mentions. *)

type nip19 =
  | Npub of string (* 32-byte pubkey *)
  | Note of string (* 32-byte event id *)
  | Nprofile of string (* pubkey (Special TLV) *)
  | Nevent of string (* event id (Special TLV) *)
  | Naddr of { kind : int; author : string; identifier : string }

(* decode the bech32 payload to raw 8-bit bytes *)
let to_bytes (data5 : int list) : string option =
  match convertbits data5 ~frombits:5 ~tobits:8 ~pad:false with
  | None -> None
  | Some bs ->
      let b = Bytes.create (List.length bs) in
      List.iteri (fun i v -> Bytes.set b i (Char.chr v)) bs;
      Some (Bytes.unsafe_to_string b)

(* TLV: (type, length, value)*. Returns the first value for each type. *)
let parse_tlv (data : string) : (int * string) list =
  let n = String.length data in
  let rec loop i acc =
    if i + 2 > n then List.rev acc
    else
      let t = Char.code data.[i] and l = Char.code data.[i + 1] in
      if i + 2 + l > n then List.rev acc else loop (i + 2 + l) ((t, String.sub data (i + 2) l) :: acc)
  in
  loop 0 []

let nip19_decode (s : string) : nip19 option =
  match bech32_decode s with
  | None -> None
  | Some (hrp, data5) -> (
      match to_bytes data5 with
      | None -> None
      | Some raw -> (
          let tlv () = parse_tlv raw in
          let u32be v =
            (Char.code v.[0] lsl 24) lor (Char.code v.[1] lsl 16) lor (Char.code v.[2] lsl 8) lor Char.code v.[3]
          in
          match hrp with
          | "npub" when String.length raw = 32 -> Some (Npub raw)
          | "note" when String.length raw = 32 -> Some (Note raw)
          | "nprofile" -> (
              match List.assoc_opt 0 (tlv ()) with
              | Some v when String.length v = 32 -> Some (Nprofile v)
              | _ -> None)
          | "nevent" -> (
              match List.assoc_opt 0 (tlv ()) with
              | Some v when String.length v = 32 -> Some (Nevent v)
              | _ -> None)
          | "naddr" -> (
              let t = tlv () in
              match (List.assoc_opt 0 t, List.assoc_opt 2 t, List.assoc_opt 3 t) with
              | Some ident, Some author, Some k when String.length author = 32 && String.length k = 4 ->
                  Some (Naddr { kind = u32be k; author; identifier = ident })
              | _ -> None)
          | _ -> None))
