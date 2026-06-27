(* BIP340 Schnorr verification, mirroring Julia src/secp256k1.jl (module Secp256k1).

   Arguments are raw bytes: [msg_hash] is 32 bytes (the event id), [serialized_pubkey] is
   the 32-byte x-only pubkey, [signature] is 64 bytes. *)

external schnorr_verify : string -> string -> string -> bool
  = "caml_secp256k1_schnorr_verify"

(* Julia: Secp256k1.verify(msg_hash, serialized_pubkey, signature) *)
let verify ~msg_hash ~serialized_pubkey ~signature =
  schnorr_verify msg_hash serialized_pubkey signature
