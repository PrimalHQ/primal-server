(* Blossom client for checks and operations:
     blossom_tool auth NSEC_FILE ACTION [SHA256HEX]           print the Authorization header value (kind 24242, 10 min)
     blossom_tool put BASE_URL NSEC_FILE FILE [upload|media]  upload a file
     blossom_tool mirror BASE_URL NSEC_FILE URL
     blossom_tool get BASE_URL SHA256HEX[.ext]                 HEAD + GET (no redirect following), prints status and headers
     blossom_tool list BASE_URL NSEC_FILE
     blossom_tool delete BASE_URL NSEC_FILE SHA256HEX[.ext] *)

let read_key path =
  let s = String.trim (In_channel.with_open_text path In_channel.input_all) in
  match (if String.length s >= 4 && String.sub s 0 4 = "nsec" then Bech32.decode ~hrp:"nsec" s else Hex_util.decode_opt s) with Some k when String.length k = 32 -> k | _ -> failwith "not an nsec/hex key"

let auth_header ~seckey ~action ?sha256_hex () =
  let tags = [ [ `String "t"; `String action ]; [ `String "expiration"; `String (string_of_int (Utils.current_time () + 600)) ] ] @ (match sha256_hex with Some x -> [ [ `String "x"; `String x ] ] | None -> []) in
  let e = Nostr.create ~seckey ~created_at:(Utils.current_time ()) ~kind:24242 ~tags ~content:(action ^ " blob") in
  "Nostr " ^ Base64.encode_string (Nostr.to_string e)

let sha256_hex s = Digestif.SHA256.(to_hex (digest_string s))

let request ~net ~clock ~meth ?(headers = []) ?(body = "") url =
  match Http.request ~net ~clock ~timeout:600.0 ~meth ~headers ~body ~max_redirects:0 url with
  | Some r -> Printf.printf "%d\n%s\n%s\n" r.Http.status (String.concat "\n" (List.map (fun (k, v) -> k ^ ": " ^ v) r.resp_headers)) (String.sub r.body 0 (min 2000 (String.length r.body)))
  | None -> print_endline "request failed"

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Http.init_tls ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  match Array.to_list Sys.argv with
  | [ _; "auth"; key; action ] -> print_endline (auth_header ~seckey:(read_key key) ~action ())
  | [ _; "auth"; key; action; sha ] -> print_endline (auth_header ~seckey:(read_key key) ~action ~sha256_hex:sha ())
  | _ :: "put" :: base :: key :: file :: rest ->
      let kind = match rest with k :: _ -> k | [] -> "upload" in
      let data = In_channel.with_open_bin file In_channel.input_all in
      let sha = sha256_hex data in
      request ~net ~clock ~meth:"PUT" ~headers:[ ("Authorization", auth_header ~seckey:(read_key key) ~action:"upload" ~sha256_hex:sha ()); ("X-SHA-256", sha); ("Content-Type", "application/octet-stream") ] ~body:data (base ^ "/" ^ kind)
  | [ _; "mirror"; base; key; url ] ->
      let sha = match Http.parse_url url with Some u -> ( let p = List.hd (List.rev (String.split_on_char '/' u.Http.path)) in List.hd (String.split_on_char '.' p)) | None -> failwith "bad url" in
      request ~net ~clock ~meth:"PUT" ~headers:[ ("Authorization", auth_header ~seckey:(read_key key) ~action:"upload" ~sha256_hex:sha ()); ("Content-Type", "application/json") ] ~body:(Yojson.Safe.to_string (`Assoc [ ("url", `String url) ])) (base ^ "/mirror")
  | [ _; "get"; base; sha ] -> request ~net ~clock ~meth:"HEAD" (base ^ "/" ^ sha); request ~net ~clock ~meth:"GET" (base ^ "/" ^ sha)
  | [ _; "list"; base; key ] ->
      let seckey = read_key key in
      request ~net ~clock ~meth:"GET" ~headers:[ ("Authorization", auth_header ~seckey ~action:"list" ()) ] (base ^ "/list/" ^ Hex_util.encode (Nostr.pubkey_of_seckey seckey))
  | [ _; "delete"; base; key; sha ] ->
      let x = List.hd (String.split_on_char '.' sha) in
      request ~net ~clock ~meth:"DELETE" ~headers:[ ("Authorization", auth_header ~seckey:(read_key key) ~action:"delete" ~sha256_hex:x ()) ] (base ^ "/" ^ sha)
  | _ -> prerr_endline "usage: blossom_tool auth|put|mirror|get|list|delete ..."; exit 2
