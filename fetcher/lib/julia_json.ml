(* Julia's JSON.json rendering of the envelope timestamp: time() is a Float64 and JSON.jl prints
   it with Julia's shortest round-trip repr, "1.791140507318978e9" for ~1.79e9 (scientific
   notation beyond 1e5), so archive consumers that parse that column keep seeing the same shape. *)

let shortest_repr (x : float) : string =
  let rec go p = if p > 17 then Printf.sprintf "%.17e" x else let s = Printf.sprintf "%.*e" (p - 1) x in if float_of_string s = x then s else go (p + 1) in
  go 1

let julia_float (x : float) : string =
  if Float.is_integer x && Float.abs x < 1e5 then Printf.sprintf "%.1f" x
  else
    let s = shortest_repr x in
    (* "d.ddde+09" -> mantissa, exponent *)
    match String.index_opt s 'e' with
    | None -> s
    | Some i ->
        let mant = String.sub s 0 i and ex = int_of_string (String.sub s (i + 1) (String.length s - i - 1)) in
        let mant = if String.contains mant '.' then mant else mant ^ ".0" in
        if ex >= -5 && ex < 6 then Printf.sprintf "%.*f" (max 1 (String.length mant - 2 - ex)) x |> fun f -> if String.contains f '.' then f else f ^ ".0"
        else Printf.sprintf "%se%d" mant ex

(* [ts, meta, m] with the timestamp spliced in as text *)
let envelope ~(now : float) (meta : Yojson.Safe.t) (m : Yojson.Safe.t) : string =
  Printf.sprintf "[%s,%s,%s]" (julia_float now) (Yojson.Safe.to_string meta) (Yojson.Safe.to_string m)
