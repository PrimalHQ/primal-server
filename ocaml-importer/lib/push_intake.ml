(* The push notification intake of Julia's PushNotifications (push_notifications.jl start /
   handle_client / notification): a TCP line protocol where another service (the wallet server)
   sends one JSON object per line, {"pubkey": <hex receiver>, "created_at": <unix>, "type": ...},
   to have it rendered and delivered to the receiver's devices. No answer is written; an empty
   line or EOF ends the connection.

   The one type that arrives this way is "wallet-transaction" (fields amount_sats, tx_network,
   tx_state, tx_type, note, optional pubkey_2: the counterparty), rendered as Julia does:
   - lightning SUCCEEDED DEPOSIT: "<amt> sats received", the note as body, the counterparty's picture;
   - onchain PROCESSING DEPOSIT: "Payment received" / "<amt> sats on-chain";
   - onchain SUCCEEDED: "Transaction confirmed" / "<amt> sats received on-chain" (DEPOSIT) or
     "<amt> sats sent on-chain" (WITHDRAW);
   linking to https://primal.net/wallet, only when the receiver's pushNotifications
   WALLET_TRANSACTIONS is on and the amount is above notificationsAdditional
   show_wallet_push_notifications_above_sats, and not when the receiver only wants notifications
   from users they follow and does not follow the counterparty. Every line is logged to
   t_push_notifications_log first, as Julia did. Other types are logged and dropped (Julia's
   notification() rendered them too, but every other producer of them lives in this importer).

   Delivery goes through Push_notifications' buffer, so [Push_notifications.run] (the sender
   subprocess) must run too: the intake is only started with push_notifications_enabled. *)

open Eio.Std
module CS = Cache_storage
module PN = Push_notifications

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [push-intake] %s\n%!" (Procinfo.timestamp ()) s) fmt

let max_line = 1 lsl 20

(* notificationsAdditional.show_wallet_push_notifications_above_sats: the user's value, else the
   server default (default-settings.json, which Julia's ext_user_get_settings merges under it) *)
let default_threshold (default_settings_file : string option) : int =
  match default_settings_file with
  | None -> 1
  | Some f -> (
      try
        match Yojson.Safe.Util.(member "show_wallet_push_notifications_above_sats" (member "notificationsAdditional" (Yojson.Safe.from_file f))) with
        | `Int n -> n
        | `Float x -> int_of_float x
        | _ -> 1
      with _ -> 1)

let wallet_threshold (est : CS.est) (pubkey : string) ~(default : int) : int =
  match Postgres.query est.CS.mem_dbh "select value from app_settings where key = decode($1,'hex') limit 1" [ Some (Hex_util.encode pubkey) ] with
  | (Some value :: _) :: _ -> (
      try
        let content = match Yojson.Safe.Util.member "content" (Yojson.Safe.from_string value) with `String s -> Yojson.Safe.from_string s | o -> o in
        match Yojson.Safe.Util.(member "show_wallet_push_notifications_above_sats" (member "notificationsAdditional" content)) with
        | `Int n -> n
        | `Float x -> int_of_float x
        | _ -> default
      with _ -> default)
  | _ -> default

type wallet_tx = {
  receiver : string; (* raw 32 bytes *)
  amount_sats : int;
  network : string;
  state : string;
  tx_type : string;
  note : string option;
  counterparty : string option; (* raw 32 bytes *)
}

(* title, body for a wallet transaction; an empty title sends nothing *)
let wallet_texts (w : wallet_tx) : string * string =
  let amt = PN.fmtsats w.amount_sats in
  match (w.network, w.state, w.tx_type) with
  | "lightning", "SUCCEEDED", "DEPOSIT" -> (amt ^ " sats received", Option.value w.note ~default:"")
  | "onchain", "PROCESSING", "DEPOSIT" -> ("Payment received", amt ^ " sats on-chain")
  | "onchain", "SUCCEEDED", "DEPOSIT" -> ("Transaction confirmed", amt ^ " sats received on-chain")
  | "onchain", "SUCCEEDED", _ -> ("Transaction confirmed", if w.tx_type = "WITHDRAW" then amt ^ " sats sent on-chain" else "")
  | _ -> ("", "")

let wallet_transaction (est : CS.est) ~(default_threshold : int) (w : wallet_tx) : unit =
  if not (PN.push_setting_enabled est w.receiver ~key:"WALLET_TRANSACTIONS") then ()
  else if w.amount_sats <= wallet_threshold est w.receiver ~default:default_threshold then ()
  else if Cache_storage_ext.blocked_sender_not_follower est ~recipient:w.receiver ~initiator:w.counterparty then ()
  else
    let title, body = wallet_texts w in
    if title <> "" then begin
      let user_displayname, _ = PN.mdpubkey est w.receiver in
      let initiator =
        match w.counterparty with
        | None -> []
        | Some pk ->
            let name, image = PN.mdpubkey est pk in
            [ ("initiator_displayname", `String name); ("initiator_pubkey", `String (Hex_util.encode pk)) ]
            @ if image <> "" then [ ("initiator_image", `String image) ] else []
      in
      let extra =
        [ ("user_pubkey", `String (Hex_util.encode w.receiver)); ("user_displayname", `String user_displayname) ]
        @ initiator
        @ [ ("link", `String "https://primal.net/wallet") ]
      in
      PN.enqueue_for_tokens est ~recipient:w.receiver ~title ~body ~extra
    end

let pubkey_field (fields : (string * Yojson.Safe.t) list) (k : string) : string option =
  match List.assoc_opt k fields with Some (`String h) when String.length h = 64 -> Hex_util.decode_opt h | _ -> None

let handle_line (est : CS.est) ~(default_threshold : int) (line : string) : unit =
  let j = Yojson.Safe.from_string line in
  PN.log_row_opt est.CS.dbh "notification" (`Assoc [ ("t", `Int (Utils.current_time ())); ("n", j) ]);
  let fields = match j with `Assoc f -> f | _ -> [] in
  let str k = match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None in
  let int k = match List.assoc_opt k fields with Some (`Int n) -> Some n | Some (`Float x) -> Some (int_of_float x) | _ -> None in
  match (pubkey_field fields "pubkey", int "created_at", str "type") with
  | Some _, Some created_at, _ when Utils.current_time () - created_at > 30 * 60 -> log "too old: %s" line
  | Some receiver, Some _, Some "wallet-transaction" ->
      wallet_transaction est ~default_threshold
        {
          receiver;
          amount_sats = Option.value (int "amount_sats") ~default:0;
          network = Option.value (str "tx_network") ~default:"";
          state = Option.value (str "tx_state") ~default:"";
          tx_type = Option.value (str "tx_type") ~default:"";
          note = str "note";
          counterparty = pubkey_field fields "pubkey_2";
        }
  | _, _, t -> log "dropped (type %s): %s" (Option.value t ~default:"?") line

let run ~net ~(host : string) ~(ports : int list) ~(est : CS.est) ~(reconnect_est : CS.est -> unit)
    ~(default_settings_file : string option) () : unit =
  let default_threshold = default_threshold default_settings_file in
  let lock = Eio.Mutex.create () in
  let handle line =
    Eio.Mutex.use_rw ~protect:true lock (fun () ->
        try handle_line est ~default_threshold line with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            log "%s: %s" (Printexc.to_string exn) line;
            if Postgres.is_connection_error exn then (try reconnect_est est with _ -> ()))
  in
  let handler flow addr =
    log "client connected: %s" (Format.asprintf "%a" Eio.Net.Sockaddr.pp addr);
    let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:max_line in
    let rec loop () =
      match Eio.Buf_read.line r with
      | "" -> ()
      | line -> handle line; loop ()
      | exception End_of_file -> ()
    in
    loop ()
  in
  let on_error = function Eio.Cancel.Cancelled _ -> () | exn -> log "connection error: %s" (Printexc.to_string exn) in
  Switch.run @@ fun sw ->
  Fiber.List.iter
    (fun port ->
      let sock = Eio.Net.listen ~sw ~reuse_addr:true ~backlog:64 net (`Tcp (Import_listener.ipaddr_of_host host, port)) in
      log "listening on %s:%d" host port;
      Fiber.fork ~sw (fun () -> while true do Eio.Net.accept_fork ~sw sock ~on_error handler done))
    ports
