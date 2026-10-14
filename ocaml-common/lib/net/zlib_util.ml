(* zlib (RFC 1950) compress/uncompress of whole strings over camlzip. Default level 6 is what
   ws-connector (flate2's Compression::default()) and Julia (CodecZlib) used, so the API's zlib
   `EVENTS` frames are byte-identical to theirs. *)

let compress ?(level = 6) (s : string) : string =
  let n = String.length s in
  let inpos = ref 0 in
  let out = Buffer.create ((n / 2) + 64) in
  Zlib.compress ~level ~header:true
    (fun buf ->
      let k = min (Bytes.length buf) (n - !inpos) in
      Bytes.blit_string s !inpos buf 0 k;
      inpos := !inpos + k;
      k)
    (fun buf len -> Buffer.add_subbytes out buf 0 len);
  Buffer.contents out

let uncompress (s : string) : string =
  let n = String.length s in
  let inpos = ref 0 in
  let out = Buffer.create (n * 4) in
  Zlib.uncompress ~header:true
    (fun buf ->
      let k = min (Bytes.length buf) (n - !inpos) in
      Bytes.blit_string s !inpos buf 0 k;
      inpos := !inpos + k;
      k)
    (fun buf len -> Buffer.add_subbytes out buf 0 len);
  Buffer.contents out
