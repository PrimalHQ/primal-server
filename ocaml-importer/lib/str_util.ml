(* Small string helpers (no regex / Str dependency). *)

(* Index of the first occurrence of [sub] in [s], or None. *)
let find_substring (s : string) (sub : string) : int option =
  let n = String.length s and m = String.length sub in
  if m = 0 then Some 0
  else begin
    let rec loop i =
      if i + m > n then None
      else if String.sub s i m = sub then Some i
      else loop (i + 1)
    in
    loop 0
  end

(* Split [s] at the first occurrence of [sep] into (before, after); None if [sep] absent. *)
let split_on_substring (s : string) (sep : string) : (string * string) option =
  match find_substring s sep with
  | None -> None
  | Some i ->
      let m = String.length sep in
      Some (String.sub s 0 i, String.sub s (i + m) (String.length s - i - m))
