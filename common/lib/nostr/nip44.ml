(* NIP-44 v2 encryption (nostr-sdk's nip44::encrypt as the RSS importer used it): conversation
   key = HKDF-extract(salt "nip44-v2", ECDH x), message keys = HKDF-expand(conversation key,
   nonce, 76) -> chacha key 32 | nonce 12 | hmac key 32; payload = base64(0x02 | nonce |
   ciphertext | hmac(aad=nonce, ciphertext)); plaintext padded with a 2-byte big-endian length to
   the NIP-44 bucket size. *)

let hmac_sha256 ~key msg = Digestif.SHA256.(to_raw_string (hmac_string ~key msg))
let hkdf_extract ~salt ~ikm = hmac_sha256 ~key:salt ikm

let hkdf_expand ~prk ~info ~len =
  let b = Buffer.create len in
  let rec go t i = if Buffer.length b >= len then () else (let t = hmac_sha256 ~key:prk (t ^ info ^ String.make 1 (Char.chr i)) in Buffer.add_string b t; go t (i + 1)) in
  go "" 1;
  Buffer.sub b 0 len

let conversation_key ~(seckey : string) ~(pubkey : string) : string option =
  Option.map (fun x -> hkdf_extract ~salt:"nip44-v2" ~ikm:x) (Secp256k1.ecdh_x ~seckey ~pubkey)

let calc_padded_len (n : int) : int =
  if n <= 32 then 32
  else
    let next_power = 1 lsl (int_of_float (Float.log2 (float_of_int (n - 1))) + 1) in
    let chunk = if next_power <= 256 then 32 else next_power / 8 in
    chunk * ((n - 1) / chunk + 1)

let pad (s : string) : string =
  let n = String.length s in
  if n < 1 || n > 65535 then invalid_arg "nip44: invalid plaintext length";
  let padded = calc_padded_len n in
  String.make 1 (Char.chr (n lsr 8)) ^ String.make 1 (Char.chr (n land 0xff)) ^ s ^ String.make (padded - n) '\000'

let unpad (s : string) : string =
  if String.length s < 2 then invalid_arg "nip44: invalid padding";
  let n = (Char.code s.[0] lsl 8) lor Char.code s.[1] in
  if n < 1 || n > 65535 || String.length s <> 2 + calc_padded_len n then invalid_arg "nip44: invalid padding";
  String.sub s 2 n

let message_keys ~(conversation_key : string) ~(nonce : string) : string * string * string =
  let k = hkdf_expand ~prk:conversation_key ~info:nonce ~len:76 in
  (String.sub k 0 32, String.sub k 32 12, String.sub k 44 32)

let chacha20 ~key ~nonce (data : string) : string = Mirage_crypto.Chacha20.crypt ~key:(Mirage_crypto.Chacha20.of_secret key) ~nonce data

let encrypt_with_nonce ~(conversation_key : string) ~(nonce : string) (plaintext : string) : string =
  let chacha_key, chacha_nonce, hmac_key = message_keys ~conversation_key ~nonce in
  let ciphertext = chacha20 ~key:chacha_key ~nonce:chacha_nonce (pad plaintext) in
  let mac = hmac_sha256 ~key:hmac_key (nonce ^ ciphertext) in
  Base64.encode_string ("\002" ^ nonce ^ ciphertext ^ mac)

let encrypt ~(conversation_key : string) (plaintext : string) : string = encrypt_with_nonce ~conversation_key ~nonce:(Mirage_crypto_rng.generate 32) plaintext

let decrypt ~(conversation_key : string) (payload : string) : (string, string) result =
  if String.length payload > 0 && payload.[0] = '#' then Error "unsupported version"
  else
    match Base64.decode payload with
    | Error _ -> Error "invalid base64"
    | Ok d ->
        let n = String.length d in
        if n < 1 + 32 + 32 + 32 || d.[0] <> '\002' then Error "invalid payload"
        else
          let nonce = String.sub d 1 32 and ciphertext = String.sub d 33 (n - 65) and mac = String.sub d (n - 32) 32 in
          let chacha_key, chacha_nonce, hmac_key = message_keys ~conversation_key ~nonce in
          if not (String.equal (hmac_sha256 ~key:hmac_key (nonce ^ ciphertext)) mac) then Error "invalid MAC"
          else try Ok (unpad (chacha20 ~key:chacha_key ~nonce:chacha_nonce ciphertext)) with Invalid_argument m -> Error m
