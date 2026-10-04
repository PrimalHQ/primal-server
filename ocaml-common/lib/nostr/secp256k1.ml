(* BIP340 Schnorr verification, mirroring Julia src/secp256k1.jl (module Secp256k1).

   Arguments are raw bytes: [msg_hash] is 32 bytes (the event id), [serialized_pubkey] is
   the 32-byte x-only pubkey, [signature] is 64 bytes. *)

external schnorr_verify : string -> string -> string -> bool
  = "caml_secp256k1_schnorr_verify"

(* Julia: Secp256k1.verify(msg_hash, serialized_pubkey, signature) *)
let verify ~msg_hash ~serialized_pubkey ~signature =
  schnorr_verify msg_hash serialized_pubkey signature

external schnorr_sign : string -> string -> string -> string = "caml_secp256k1_schnorr_sign"
external xonly_pubkey : string -> string = "caml_secp256k1_xonly_pubkey"

(* BIP340 signature of [msg_hash] (32 bytes) with [seckey] (32 bytes) and 32 bytes of auxiliary
   randomness; None when the key is invalid. *)
let sign ~seckey ~msg_hash ~aux_rand : string option =
  let s = schnorr_sign seckey msg_hash aux_rand in
  if String.length s = 64 then Some s else None

let pubkey_of_seckey (seckey : string) : string option =
  let p = xonly_pubkey seckey in
  if String.length p = 32 then Some p else None
