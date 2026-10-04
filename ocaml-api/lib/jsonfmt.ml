(* Julia JSON.json(x, 2): two-space indentation, one element per line, "key": value, empty
   containers as {} / []. InternalServices answers nostr.json and /spam in this format. *)

let julia_pretty (j : Yojson.Safe.t) : string =
  let b = Buffer.create 1024 in
  let rec go indent (j : Yojson.Safe.t) =
    let pad n = Buffer.add_string b (String.make n ' ') in
    match j with
    | `Assoc [] -> Buffer.add_string b "{}"
    | `List [] -> Buffer.add_string b "[]"
    | `Assoc fields ->
        Buffer.add_string b "{\n";
        List.iteri
          (fun i (k, v) ->
            pad (indent + 2);
            Buffer.add_string b (Yojson.Safe.to_string (`String k));
            Buffer.add_string b ": ";
            go (indent + 2) v;
            if i < List.length fields - 1 then Buffer.add_char b ',';
            Buffer.add_char b '\n')
          fields;
        pad indent;
        Buffer.add_char b '}'
    | `List items ->
        Buffer.add_string b "[\n";
        List.iteri
          (fun i v ->
            pad (indent + 2);
            go (indent + 2) v;
            if i < List.length items - 1 then Buffer.add_char b ',';
            Buffer.add_char b '\n')
          items;
        pad indent;
        Buffer.add_char b ']'
    | v -> Buffer.add_string b (Yojson.Safe.to_string v)
  in
  go 0 j;
  Buffer.contents b
