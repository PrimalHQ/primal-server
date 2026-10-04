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
#include <caml/alloc.h>

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

/* sign : seckey32 -> msg32 -> aux_rand32 -> sig64 (empty string on failure). Signing needs a
   non-static context; one is created per call (rare: DVM job requests, service events). */
CAMLprim value caml_secp256k1_schnorr_sign(value vsec, value vmsg, value vaux) {
  CAMLparam3(vsec, vmsg, vaux);
  CAMLlocal1(res);
  if (caml_string_length(vsec) != 32 || caml_string_length(vmsg) != 32 ||
      caml_string_length(vaux) != 32)
    CAMLreturn(caml_alloc_string(0));
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  secp256k1_keypair kp;
  unsigned char sig[64];
  int ok = secp256k1_keypair_create(ctx, &kp, (const unsigned char *)String_val(vsec)) &&
           secp256k1_schnorrsig_sign32(ctx, sig, (const unsigned char *)String_val(vmsg), &kp,
                                       (const unsigned char *)String_val(vaux));
  secp256k1_context_destroy(ctx);
  if (!ok) CAMLreturn(caml_alloc_string(0));
  res = caml_alloc_initialized_string(64, (const char *)sig);
  CAMLreturn(res);
}

/* xonly_pubkey : seckey32 -> pubkey32 (empty string on failure) */
CAMLprim value caml_secp256k1_xonly_pubkey(value vsec) {
  CAMLparam1(vsec);
  CAMLlocal1(res);
  if (caml_string_length(vsec) != 32) CAMLreturn(caml_alloc_string(0));
  secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
  secp256k1_keypair kp;
  secp256k1_xonly_pubkey xonly;
  unsigned char out[32];
  int ok = secp256k1_keypair_create(ctx, &kp, (const unsigned char *)String_val(vsec)) &&
           secp256k1_keypair_xonly_pub(ctx, &xonly, NULL, &kp) &&
           secp256k1_xonly_pubkey_serialize(ctx, out, &xonly);
  secp256k1_context_destroy(ctx);
  if (!ok) CAMLreturn(caml_alloc_string(0));
  res = caml_alloc_initialized_string(32, (const char *)out);
  CAMLreturn(res);
}
