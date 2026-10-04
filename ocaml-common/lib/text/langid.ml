(* Language identification as Julia's Languages.jl (a port of whatlang-rs): script detection by
   character ranges with the Julia port's rule that a script must cover more than half of the
   text's characters, then either a script-determined language or a trigram-profile comparison
   (300-trigram distance, confidence from the gap to the runner-up). Returns the ISO 639-3 code
   and the confidence, as reads.lang / reads.lang_prob store them. *)

type script =
  | Latin | Cyrillic | Arabic | Mandarin | Devanagari | Hebrew | Ethiopic | Georgian | Bengali | Hangul | Hiragana | Katakana | Greek | Kannada | Tamil | Thai
  | Gujarati | Gurmukhi | Telugu | Malayalam | Oriya | Myanmar | Sinhala | Khmer

let script_order = [ Latin; Cyrillic; Arabic; Mandarin; Devanagari; Hebrew; Ethiopic; Georgian; Bengali; Hangul; Hiragana; Katakana; Greek; Kannada; Tamil; Thai; Gujarati; Gurmukhi; Telugu; Malayalam; Oriya; Myanmar; Sinhala; Khmer ]

let in_ c a b = c >= a && c <= b

let is_script (s : script) (c : int) : bool =
  match s with
  | Cyrillic -> in_ c 0x0400 0x0484 || in_ c 0x0487 0x052F || in_ c 0x2DE0 0x2DFF || in_ c 0xA640 0xA69D || c = 0x1D2B || c = 0x1D78 || c = 0xA69F
  | Latin ->
      in_ c 0x61 0x7A || in_ c 0x41 0x5A || in_ c 0x80 0xFF || in_ c 0x100 0x17F || in_ c 0x180 0x24F || in_ c 0x250 0x2AF || in_ c 0x1D00 0x1D7F || in_ c 0x1D80 0x1DBF || in_ c 0x1E00 0x1EFF
      || in_ c 0x2100 0x214F || in_ c 0x2C60 0x2C7F || in_ c 0xA720 0xA7FF || in_ c 0xAB30 0xAB6F
  | Arabic -> in_ c 0x0600 0x06FF || in_ c 0x0750 0x07FF || in_ c 0x08A0 0x08FF || in_ c 0xFB50 0xFDFF || in_ c 0xFE70 0xFEFF
  | Devanagari -> in_ c 0x0900 0x097F || in_ c 0xA8E0 0xA8FF || in_ c 0x1CD0 0x1CFF
  | Ethiopic -> in_ c 0x1200 0x139F || in_ c 0x2D80 0x2DDF || in_ c 0xAB00 0xAB2F
  | Hebrew -> in_ c 0x0590 0x05FF
  | Georgian -> in_ c 0x10A0 0x10FF
  | Mandarin -> in_ c 0x2E80 0x2E99 || in_ c 0x2E9B 0x2EF3 || in_ c 0x2F00 0x2FD5 || c = 0x3005 || c = 0x3007 || in_ c 0x3021 0x3029 || in_ c 0x3038 0x303B || in_ c 0x3400 0x4DB5 || in_ c 0x4E00 0x9FCC || in_ c 0xF900 0xFA6D || in_ c 0xFA70 0xFAD9
  | Bengali -> in_ c 0x0980 0x09FF
  | Hiragana -> in_ c 0x3040 0x309F
  | Katakana -> in_ c 0x30A0 0x30FF
  | Hangul -> in_ c 0xAC00 0xD7AF || in_ c 0x1100 0x11FF || in_ c 0x3130 0x318F || in_ c 0x3200 0x32FF || in_ c 0xA960 0xA97F || in_ c 0xD7B0 0xD7FF || in_ c 0xFF00 0xFFEF
  | Greek -> in_ c 0x0370 0x03FF
  | Kannada -> in_ c 0x0C80 0x0CFF
  | Tamil -> in_ c 0x0B80 0x0BFF
  | Thai -> in_ c 0x0E00 0x0E7F
  | Gujarati -> in_ c 0x0A80 0x0AFF
  | Gurmukhi -> in_ c 0x0A00 0x0A7F
  | Telugu -> in_ c 0x0C00 0x0C7F
  | Malayalam -> in_ c 0x0D00 0x0D7F
  | Oriya -> in_ c 0x0B00 0x0B7F
  | Myanmar -> in_ c 0x1000 0x109F
  | Sinhala -> in_ c 0x0D80 0x0DFF
  | Khmer -> in_ c 0x1780 0x17FF || in_ c 0x19E0 0x19FF

let is_stop_char c = in_ c 0 0x40 || in_ c 0x5B 0x60 || in_ c 0x7B 0x7E

(* the text as code points (invalid bytes become U+FFFD, as Julia's iteration yields them) *)
let code_points (s : string) : int array =
  let acc = ref [] in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let d = String.get_utf_8_uchar s !i in
    acc := Uchar.to_int (Uchar.utf_decode_uchar d) :: !acc;
    i := !i + Uchar.utf_decode_length d
  done;
  Array.of_list (List.rev !acc)

(* Unicode lowercase for the scripts the trigram profiles cover (Latin, Cyrillic, Greek) *)
let lowercase (c : int) : int =
  if in_ c 0x41 0x5A then c + 32
  else if (in_ c 0xC0 0xDE) && c <> 0xD7 then c + 32
  else if in_ c 0x100 0x137 && c land 1 = 0 then c + 1
  else if in_ c 0x139 0x148 && c land 1 = 1 then c + 1
  else if in_ c 0x14A 0x177 && c land 1 = 0 then c + 1
  else if c = 0x178 then 0xFF
  else if in_ c 0x179 0x17E && c land 1 = 1 then c + 1
  else if in_ c 0x391 0x3A9 && c <> 0x3A2 then c + 32
  else if in_ c 0x410 0x42F then c + 32
  else if in_ c 0x400 0x40F then c + 80
  else if in_ c 0x460 0x481 && c land 1 = 0 then c + 1
  else if in_ c 0x48A 0x4BF && c land 1 = 0 then c + 1
  else if in_ c 0x4D0 0x52F && c land 1 = 0 then c + 1
  else c

type detected = Script of script | Script_p of script * float

(* detect_script: the Julia port returns a script only when it covers more than half of the
   characters (stop characters included in the length), with the CJK special case *)
let detect_script (cps : int array) : detected option =
  let counters = Array.of_list (List.map (fun s -> (s, ref 0)) script_order) in
  let half = float_of_int (Array.length cps) /. 2.0 in
  let n = Array.length counters in
  let result = ref None in
  (try
     Array.iter
       (fun ch ->
         if not (is_stop_char ch) then
           for i = 0 to n - 1 do
             let s, cnt = counters.(i) in
             if is_script s ch then begin
               incr cnt;
               if float_of_int !cnt > half && not (s = Mandarin || s = Hiragana || s = Katakana) then begin
                 result := Some (Script s);
                 raise Exit
               end;
               if i > 0 then begin
                 let t = counters.(i - 1) in
                 counters.(i - 1) <- counters.(i);
                 counters.(i) <- t
               end
             end
           done)
       cps
   with Exit -> ());
  match !result with
  | Some r -> Some r
  | None ->
      let count s = match Array.find_opt (fun (x, _) -> x = s) counters with Some (_, c) -> !c | None -> 0 in
      let mandarin = count Mandarin and hiragana = count Hiragana and katakana = count Katakana in
      if mandarin + hiragana + katakana > 0 then begin
        let japanese = katakana + hiragana in
        let pct = float_of_int japanese /. float_of_int (mandarin + japanese) in
        let kana = if katakana > hiragana then Katakana else Hiragana in
        if pct > 0.2 then Some (Script kana) else if pct > 0.05 then Some (Script_p (kana, 0.5)) else if pct > 0.02 then Some (Script_p (Mandarin, 0.5)) else Some (Script Mandarin)
      end
      else None

let max_trigram_distance = 300
let max_total_distance = 90_000
let text_trigrams_size = 600

let utf8_of_cp (c : int) : string =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b (Uchar.of_int (if Uchar.is_valid c then c else 0xFFFD));
  Buffer.contents b

(* count_trigrams over the lowercased text with stop characters as spaces *)
let count_trigrams (cps : int array) : (string, int) Hashtbl.t =
  let h = Hashtbl.create 1024 in
  let chars = Array.map (fun c -> if is_stop_char c then 0x20 else lowercase c) cps in
  let chars = Array.append chars [| 0x20 |] in
  let c1 = ref 0x20 and c2 = ref (if Array.length chars > 0 then chars.(0) else 0x20) in
  for k = 1 to Array.length chars - 1 do
    let c3 = chars.(k) in
    if not (!c2 = 0x20 && (!c1 = 0x20 || c3 = 0x20)) then begin
      let tri = utf8_of_cp !c1 ^ utf8_of_cp !c2 ^ utf8_of_cp c3 in
      Hashtbl.replace h tri (1 + Option.value (Hashtbl.find_opt h tri) ~default:0)
    end;
    c1 := !c2;
    c2 := c3
  done;
  h

let trigrams_with_positions (cps : int array) : (string, int) Hashtbl.t =
  let counts = Hashtbl.fold (fun k v acc -> (v, k) :: acc) (count_trigrams cps) [] in
  let sorted = List.sort (fun (c1, t1) (c2, t2) -> match compare c2 c1 with 0 -> compare t2 t1 | c -> c) counts in
  let h = Hashtbl.create 1024 in
  List.iteri (fun i (_, t) -> if i < text_trigrams_size then Hashtbl.replace h t (i + 1)) sorted;
  h

let distance (profile : string array) (text : (string, int) Hashtbl.t) : int =
  let total = ref 0 in
  Array.iteri (fun i tri -> let pos = i + 1 in let d = (match Hashtbl.find_opt text tri with Some p -> p | None -> max_trigram_distance + pos) - pos in total := !total + abs d) profile;
  !total

let detect_trigrams (cps : int array) (profiles : (string * string array) list) : (string * float) option =
  let text = trigrams_with_positions cps in
  let dists = List.map (fun (code, prof) -> (code, distance prof text)) profiles |> List.stable_sort (fun (_, a) (_, b) -> compare a b) in
  match dists with
  | [] -> None
  | [ (code, _) ] -> Some (code, 1.0)
  | (code1, d1) :: (_, d2) :: _ ->
      let score1 = max_total_distance - d1 and score2 = max_total_distance - d2 in
      if score1 = 0 then None
      else if score2 = 0 then Some (code1, Float.min 1.0 (float_of_int score1 /. 500.0))
      else
        let rate = float_of_int (score1 - score2) /. float_of_int score2 in
        let confident_rate = (12.0 /. float_of_int (Hashtbl.length text)) +. 0.05 in
        Some (code1, if rate > confident_rate then 1.0 else rate /. confident_rate)

let profiles_of_script (s : script) : (string * string array) list option =
  let name = match s with Latin -> Some "Latin" | Cyrillic -> Some "Cyrillic" | Arabic -> Some "Arabic" | Devanagari -> Some "Devanagari" | Ethiopic -> Some "Ethiopic" | Hebrew -> Some "Hebrew" | _ -> None in
  Option.bind name (fun n -> List.assoc_opt n Langid_data.profiles)

(* (ISO 639-3 code, confidence); None when no script dominates the text *)
let detect (text : string) : (string * float) option =
  if text = "" then None
  else
    let cps = code_points text in
    match detect_script cps with
    | None -> None
    | Some (Script_p (Mandarin, p)) -> Some ("cmn", p)
    | Some (Script_p ((Hiragana | Katakana), p)) -> Some ("jpn", p)
    | Some (Script_p (_, p)) -> Some ("", p)
    | Some (Script s) -> (
        match s with
        | Mandarin -> Some ("cmn", 1.0)
        | Hiragana | Katakana -> Some ("jpn", 1.0)
        | Bengali -> Some ("ben", 1.0)
        | Hangul -> Some ("kor", 1.0)
        | Georgian -> Some ("kat", 1.0)
        | Greek -> Some ("ell", 1.0)
        | Kannada -> Some ("kan", 1.0)
        | Tamil -> Some ("tam", 1.0)
        | Thai -> Some ("tha", 1.0)
        | Gujarati -> Some ("guj", 1.0)
        | Gurmukhi -> Some ("pan", 1.0)
        | Telugu -> Some ("tel", 1.0)
        | Malayalam -> Some ("mal", 1.0)
        | Oriya -> Some ("ori", 1.0)
        | Myanmar -> Some ("mya", 1.0)
        | Sinhala -> Some ("sin", 1.0)
        | Khmer -> Some ("khm", 1.0)
        | _ -> ( match profiles_of_script s with Some profiles -> detect_trigrams cps profiles | None -> None))
