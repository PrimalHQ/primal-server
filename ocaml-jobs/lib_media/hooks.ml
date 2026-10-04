(* Registration points the private extensions fill (ocaml-plan.md §11.1 Media.Hooks): the media
   analysis after an upload, and the CDN purge call. Unset = the public build's no-ops. *)
let after_import_upload : (Procgraph.ctx -> surl:string -> data:string -> pubkey_hex:string option -> eid_hex:string option -> origin:string -> unit) option ref = ref None
let bunny_purge : (Procgraph.ctx -> unit) option ref = ref None
