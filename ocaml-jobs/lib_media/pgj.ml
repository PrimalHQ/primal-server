(* The processing graph's typed JSON (processing_graph.jl arg_serialize / arg_deserialize, Rust
   processing_graph.rs wrappers): every non-JSON Julia value travels as {"_ty": T, "_v": v} —
   Tuple, NamedTuple, Symbol, NodeId, PubKeyId, EventId, Event, UUID, CacheStorage, Vector{UInt8}
   (inline hex up to 256 bytes, else {"_ty","_cache_sha256"} naming a file in the binary cache).

   Serialisation is insertion-ordered, floats in Julia's shortest repr, so a node id
   (sha256 of {"mod","func","args","kwargs"}) and a media_storage key hash come out as Julia and the
   blossom server (serde_json with preserve_order) produce them. *)

type t = Yojson.Safe.t

let shortest_repr (x : float) : string =
  let rec go p = if p > 17 then Printf.sprintf "%.17g" x else let s = Printf.sprintf "%.*g" p x in if float_of_string s = x then s else go (p + 1) in
  go 1

(* Julia Float64 printing: shortest round-trip digits; scientific beyond 1e5 or below 1e-5 *)
let julia_float (x : float) : string =
  if Float.is_nan x then "NaN"
  else if Float.is_integer x && Float.abs x < 1e6 then Printf.sprintf "%.1f" x
  else
    let s = shortest_repr x in
    let mant, ex = match String.index_opt (String.lowercase_ascii s) 'e' with Some i -> (String.sub s 0 i, int_of_string (String.sub s (i + 1) (String.length s - i - 1))) | None -> (s, 0) in
    if ex = 0 && (Float.abs x >= 1e-4 && Float.abs x < 1e6) then (if String.contains mant '.' then mant else mant ^ ".0")
    else begin
      (* normalise to d.ddd e exp *)
      let neg = x < 0. in
      let digits = String.concat "" (String.split_on_char '.' (if neg then String.sub mant 1 (String.length mant - 1) else mant)) in
      let intpart_len = match String.index_opt mant '.' with Some i -> i - (if neg then 1 else 0) | None -> String.length mant - (if neg then 1 else 0) in
      let e10 = ex + intpart_len - 1 in
      (* strip leading zeros (0.000123) *)
      let rec lead i = if i < String.length digits - 1 && digits.[i] = '0' then lead (i + 1) else i in
      let li = lead 0 in
      let digits = String.sub digits li (String.length digits - li) and e10 = e10 - li in
      let digits = let n = ref (String.length digits) in while !n > 1 && digits.[!n - 1] = '0' do decr n done; String.sub digits 0 !n in
      if e10 >= -4 && e10 <= 5 then Printf.sprintf "%s%s" (if neg then "-" else "") (Printf.sprintf "%.*f" (max 1 (String.length digits - 1 - e10)) (Float.abs x))
      else Printf.sprintf "%s%c.%se%d" (if neg then "-" else "") digits.[0] (if String.length digits > 1 then String.sub digits 1 (String.length digits - 1) else "0") e10
    end

let rec write (b : Buffer.t) (v : t) : unit =
  match v with
  | `Null -> Buffer.add_string b "null"
  | `Bool x -> Buffer.add_string b (if x then "true" else "false")
  | `Int i -> Buffer.add_string b (string_of_int i)
  | `Intlit s -> Buffer.add_string b s
  | `Float f -> Buffer.add_string b (julia_float f)
  | `String s -> Buffer.add_string b (Yojson.Safe.to_string (`String s))
  | `List l ->
      Buffer.add_char b '[';
      List.iteri (fun i x -> if i > 0 then Buffer.add_char b ','; write b x) l;
      Buffer.add_char b ']'
  | `Assoc kvs ->
      Buffer.add_char b '{';
      List.iteri (fun i (k, x) -> if i > 0 then Buffer.add_char b ','; Buffer.add_string b (Yojson.Safe.to_string (`String k)); Buffer.add_char b ':'; write b x) kvs;
      Buffer.add_char b '}'
  | `Tuple l -> write b (`List l)
  | `Variant (k, Some x) -> write b (`List [ `String k; x ])
  | `Variant (k, None) -> write b (`String k)

let to_string (v : t) : string = let b = Buffer.create 256 in write b v; Buffer.contents b

let sha256_hex (s : string) : string = Digestif.SHA256.(to_hex (digest_string s))
let sha256_raw (s : string) : string = Digestif.SHA256.(to_raw_string (digest_string s))

(* {1 constructors} *)
let tuple (l : t list) : t = `Assoc [ ("_ty", `String "Tuple"); ("_v", `List l) ]
let namedtuple (kvs : (string * t) list) : t = `Assoc [ ("_ty", `String "NamedTuple"); ("_v", `Assoc kvs) ]
let symbol (s : string) : t = `Assoc [ ("_ty", `String "Symbol"); ("_v", `String s) ]
let event_id_hex (h : string) : t = `Assoc [ ("_ty", `String "EventId"); ("_v", `String h) ]
let pubkey_id_hex (h : string) : t = `Assoc [ ("_ty", `String "PubKeyId"); ("_v", `String h) ]
let node_id_hex (h : string) : t = `Assoc [ ("_ty", `String "NodeId"); ("_v", `String h) ]
let cache_storage : t = `Assoc [ ("_ty", `String "CacheStorage"); ("_v", `Null) ]
let vec_u8_inline (bytes : string) : t = `Assoc [ ("_ty", `String "Vector{UInt8}"); ("_v", `String (Hex_util.encode bytes)) ]
let vec_u8_cached (sha_hex : string) : t = `Assoc [ ("_ty", `String "Vector{UInt8}"); ("_cache_sha256", `String sha_hex) ]
let opt f = function Some x -> f x | None -> `Null

(* {1 binary cache} *)
let cache_path ~(dir : string) (hh : string) : string = Printf.sprintf "%s/%s/%s/%s" dir (String.sub hh 0 2) (String.sub hh 2 2) hh

let cache_write ~(dir : string) (bytes : string) : string =
  let hh = sha256_hex bytes in
  let path = cache_path ~dir hh in
  if not (Sys.file_exists path) then begin
    Pushgateway.mkdir_p (Filename.dirname path);
    let tmp = path ^ ".tmp-" ^ string_of_int (Unix.getpid ()) in
    let oc = open_out_bin tmp in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc bytes);
    Sys.rename tmp path
  end;
  hh

(* arg_serialize(::Vector{UInt8}): inline up to 256 bytes, otherwise the cache file *)
let vec_u8 ~(dir : string) (bytes : string) : t = if String.length bytes <= 256 then vec_u8_inline bytes else vec_u8_cached (cache_write ~dir bytes)

let read_file (path : string) : string =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> really_input_string ic (in_channel_length ic))

(* {1 accessors} *)
let ty (v : t) : string option = match v with `Assoc f -> ( match List.assoc_opt "_ty" f with Some (`String s) -> Some s | _ -> None) | _ -> None
let inner (v : t) : t = match v with `Assoc f -> ( match List.assoc_opt "_v" f with Some x -> x | None -> `Null) | _ -> `Null
let as_tuple (v : t) : t list = match (ty v, inner v) with Some "Tuple", `List l -> l | _, _ -> ( match v with `List l -> l | _ -> failwith "expected Tuple")
let as_symbol (v : t) : string option = match (ty v, inner v) with Some "Symbol", `String s -> Some s | _ -> ( match v with `String s -> Some s | _ -> None)
let as_hex_id (v : t) : string option = match (ty v, inner v) with Some ("EventId" | "PubKeyId" | "NodeId" | "Event"), `String s -> Some s | _ -> None
let as_string (v : t) : string option = match v with `String s -> Some s | _ -> None
let as_bool (v : t) : bool option = match v with `Bool b -> Some b | `Int 1 -> Some true | `Int 0 -> Some false | _ -> None
let as_int (v : t) : int option = match v with `Int i -> Some i | `Float f -> Some (int_of_float f) | `Intlit s -> int_of_string_opt s | _ -> None
let as_float (v : t) : float option = match v with `Int i -> Some (float_of_int i) | `Float f -> Some f | `Intlit s -> float_of_string_opt s | _ -> None

(* Vector{UInt8}: inline hex or the cache file *)
let read_vec_u8 ~(dir : string) (v : t) : string option =
  match v with
  | `Assoc f when List.assoc_opt "_ty" f = Some (`String "Vector{UInt8}") -> (
      match (List.assoc_opt "_v" f, List.assoc_opt "_cache_sha256" f) with
      | Some (`String hex), _ -> Hex_util.decode_opt hex
      | _, Some (`String hh) when String.length hh >= 4 -> ( try Some (read_file (cache_path ~dir hh)) with _ -> None)
      | _ -> None)
  | _ -> None

(* kwargs are a plain object (or a NamedTuple wrapper) *)
let kwargs_fields (v : t) : (string * t) list = match (ty v, inner v, v) with Some "NamedTuple", `Assoc f, _ -> f | _, _, `Assoc f -> f | _ -> []
let kw (v : t) (k : string) : t option = List.assoc_opt k (kwargs_fields v)
let namedtuple_fields = kwargs_fields

(* processing_graph.jl cleanup_binary_cache_arguments *)
let rec cleanup_binary_cache ~(dir : string) (v : t) : unit =
  match v with
  | `Assoc f -> (
      match List.assoc_opt "_ty" f with
      | Some (`String "Vector{UInt8}") -> ( match List.assoc_opt "_cache_sha256" f with Some (`String hh) when String.length hh >= 4 -> ( try Sys.remove (cache_path ~dir hh) with _ -> ()) | _ -> ())
      | Some (`String "Tuple") -> ( match List.assoc_opt "_v" f with Some (`List l) -> List.iter (cleanup_binary_cache ~dir) l | _ -> ())
      | Some _ -> ()
      | None -> List.iter (fun (_, x) -> cleanup_binary_cache ~dir x) f)
  | `List l -> List.iter (cleanup_binary_cache ~dir) l
  | _ -> ()

(* {1 node ids}

   Three producers hash three serialisations of the same {mod, func, args, kwargs}: Julia (NamedTuple
   order, wrappers _ty first), the blossom server (serde_json preserve_order, as written: _ty first)
   and Rust primal-media (serde_json BTreeMap: every object's keys sorted bytewise). jsonb loses the
   stored order, so only the sorted form can be recomputed from a row; nodes this executor creates
   use the sorted form, as the Rust executor it replaces did. *)
let rec sort_keys (v : t) : t = match v with `Assoc f -> `Assoc (List.sort (fun (a, _) (b, _) -> compare a b) (List.map (fun (k, x) -> (k, sort_keys x)) f)) | `List l -> `List (List.map sort_keys l) | x -> x
let top ~mod_ ~func ~args ~kwargs : t = `Assoc [ ("mod", `String mod_); ("func", `String func); ("args", args); ("kwargs", kwargs) ]
let node_id_sorted ~mod_ ~func ~args ~kwargs : string = sha256_hex (to_string (sort_keys (top ~mod_ ~func ~args ~kwargs)))
let node_id_insertion ~mod_ ~func ~args ~kwargs : string = sha256_hex (to_string (top ~mod_ ~func ~args ~kwargs))

(* Rust node_id_juliaish: wrappers as _ty, _v, _cache_sha256, rest; plain objects' keys sorted *)
let rec juliaish (v : t) : t =
  match v with
  | `Assoc f when List.mem_assoc "_ty" f ->
      let pick k = match List.assoc_opt k f with Some x -> [ (k, juliaish x) ] | None -> [] in
      let rest = List.filter (fun (k, _) -> not (List.mem k [ "_ty"; "_v"; "_cache_sha256" ])) f in
      `Assoc (pick "_ty" @ pick "_v" @ pick "_cache_sha256" @ List.sort (fun (a, _) (b, _) -> compare a b) (List.map (fun (k, x) -> (k, juliaish x)) rest))
  | `Assoc f -> `Assoc (List.sort (fun (a, _) (b, _) -> compare a b) (List.map (fun (k, x) -> (k, juliaish x)) f))
  | `List l -> `List (List.map juliaish l)
  | x -> x
let node_id_juliaish ~mod_ ~func ~args ~kwargs : string = sha256_hex (to_string (`Assoc [ ("mod", `String mod_); ("func", `String func); ("args", juliaish args); ("kwargs", juliaish kwargs) ]))

let node_id = node_id_sorted

let all_variants : t = `List (List.concat_map (fun s -> List.map (fun a -> tuple [ symbol s; `Bool a ]) [ true; false ]) [ "original"; "small"; "medium"; "large" ])

(* a stored variant_specs vector -> (size, animated) list *)
let variant_specs_of (v : t) : (string * bool) list =
  let items = match v with `List l -> l | _ -> ( match (ty v, inner v) with Some "Vector", `List l -> l | _ -> []) in
  List.filter_map (fun it -> match as_tuple it with [ s; a ] -> ( match (as_symbol s, as_bool a) with Some s, Some a -> Some (s, a) | _ -> None) | _ -> None | exception _ -> None) items
