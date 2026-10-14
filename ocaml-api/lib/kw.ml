(* Typed access to a funcall's kwargs. Every accessor returns an option or a default; [Invalid] is
   raised where ws-connector returned an error for a malformed argument (the dispatcher then treats
   the request as not handled: NOTICE "error"). *)

exception Invalid of string

type t = Yojson.Safe.t

let member (k : t) (name : string) : Yojson.Safe.t =
  match k with `Assoc f -> ( match List.assoc_opt name f with Some v -> v | None -> `Null) | _ -> `Null

let str_opt k name = match member k name with `String s -> Some s | _ -> None
let str k name ~default = Option.value (str_opt k name) ~default
let str_exn k name = match str_opt k name with Some s -> s | None -> raise (Invalid ("invalid " ^ name))

let int_opt k name : int option =
  match member k name with
  | `Int i -> Some i
  | `Intlit s -> int_of_string_opt s
  | `Float f when Float.is_integer f -> Some (int_of_float f)
  | _ -> None

let int k name ~default = Option.value (int_opt k name) ~default
let int_exn k name = match int_opt k name with Some i -> i | None -> raise (Invalid ("invalid " ^ name))

let bool_opt k name = match member k name with `Bool b -> Some b | _ -> None
let bool k name ~default = Option.value (bool_opt k name) ~default

(* 32-byte hex id (pubkey / event id) as raw bytes. *)
let hex32_opt k name : string option =
  match str_opt k name with
  | Some h when String.length h = 64 -> Hex_util.decode_opt h
  | _ -> None

let hex32_exn k name = match hex32_opt k name with Some b -> b | None -> raise (Invalid ("invalid " ^ name))

(* ws-connector: hex::decode(...).ok() — any even-length hex is accepted for user_pubkey. *)
let hex_any_opt k name : string option =
  match str_opt k name with Some h -> Hex_util.decode_opt h | None -> None

let int_list_opt k name : int list option =
  match member k name with
  | `List l ->
      Some
        (List.filter_map
           (function `Int i -> Some i | `Intlit s -> int_of_string_opt s | _ -> None)
           l)
  | _ -> None

let str_list_opt k name : string list option =
  match member k name with
  | `List l -> Some (List.filter_map (function `String s -> Some s | _ -> None) l)
  | _ -> None

let has k name = match member k name with `Null -> false | _ -> true

(* kwargs as an assoc list with a key removed / set (mega_feed_directive rewrites). *)
let fields (k : t) : (string * Yojson.Safe.t) list = match k with `Assoc f -> f | _ -> []
let remove (k : t) name : t = `Assoc (List.filter (fun (n, _) -> n <> name) (fields k))
let set (k : t) name v : t = `Assoc ((name, v) :: List.filter (fun (n, _) -> n <> name) (fields k))

(* serde_json Map::append semantics: entries of [extra] overwrite [k]'s. *)
let merge (k : t) (extra : (string * Yojson.Safe.t) list) : t =
  List.fold_left (fun acc (n, v) -> set acc n v) k extra
