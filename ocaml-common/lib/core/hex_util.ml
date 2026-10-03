(* Hex encoding/decoding of raw byte strings.

   Nostr ids, pubkeys and signatures are 32/32/64 raw bytes on the wire they are
   lowercase hex. We keep the raw-bytes representation internally and convert at the
   JSON/DB boundaries. *)

let encode (s : string) : string =
  let buf = Buffer.create (String.length s * 2) in
  String.iter
    (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c)))
    s;
  Buffer.contents buf

let nibble c =
  match c with
  | '0' .. '9' -> Char.code c - Char.code '0'
  | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
  | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
  | _ -> invalid_arg "Hex_util: not a hex digit"

let decode_exn (h : string) : string =
  let n = String.length h in
  if n land 1 <> 0 then invalid_arg "Hex_util.decode_exn: odd-length hex string";
  let b = Bytes.create (n / 2) in
  for i = 0 to (n / 2) - 1 do
    Bytes.set b i (Char.chr ((nibble h.[2 * i] lsl 4) lor nibble h.[(2 * i) + 1]))
  done;
  Bytes.unsafe_to_string b

let decode_opt h = try Some (decode_exn h) with Invalid_argument _ -> None
