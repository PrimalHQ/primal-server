/* Minimal C stubs binding libsecp256k1's BIP340 Schnorr verification, mirroring the
   Julia FFI in primal-server/src/secp256k1.jl (Secp256k1.verify).

   Nostr signatures are BIP340 Schnorr over an x-only (32-byte) public key, with a
   64-byte signature over the 32-byte event-id hash. The ECDSA-only `secp256k1` opam
   package cannot do this, so we bind the schnorrsig module directly.

   We use `secp256k1_context_static`, which is a const context safe to use from multiple
   threads/domains for verification (no per-call context creation needed). */

#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>

/* verify : msg32 (string) -> pubkey32 (string) -> sig64 (string) -> bool */
CAMLprim value caml_secp256k1_schnorr_verify(value vmsg, value vpub, value vsig) {
  CAMLparam3(vmsg, vpub, vsig);
  if (caml_string_length(vmsg) != 32 || caml_string_length(vpub) != 32 ||
      caml_string_length(vsig) != 64)
    CAMLreturn(Val_false);

  const secp256k1_context *ctx = secp256k1_context_static;
  secp256k1_xonly_pubkey xonly;
  if (!secp256k1_xonly_pubkey_parse(ctx, &xonly,
                                    (const unsigned char *)String_val(vpub)))
    CAMLreturn(Val_false);

  int ok = secp256k1_schnorrsig_verify(
      ctx, (const unsigned char *)String_val(vsig),
      (const unsigned char *)String_val(vmsg), 32, &xonly);
  CAMLreturn(ok ? Val_true : Val_false);
}
