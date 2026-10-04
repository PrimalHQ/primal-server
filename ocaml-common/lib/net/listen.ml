(* Listening sockets shared across domains.

   A daemon binds each port ONCE (SO_REUSEADDR | SO_REUSEPORT, so a replacement generation can bind
   the same port during a rolling restart, see ocaml-plan.md §6) and then imports a dup of the fd
   into every worker domain; each domain runs its own accept loop and the kernel balances incoming
   connections across them. Eio sockets are domain-bound, which is why the raw fd is shared instead
   of an Eio listening socket. *)

let ipaddr_of_host (host : string) : Unix.inet_addr =
  match host with
  | "" | "0.0.0.0" -> Unix.inet_addr_any
  | "localhost" -> Unix.inet_addr_loopback
  | h -> Unix.inet_addr_of_string h

(* Bind + listen; the fd is in non-blocking mode (Eio requires it). Raises on failure. *)
let bind ?(backlog = 1024) ~(host : string) ~(port : int) () : Unix.file_descr =
  let fd = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  (try
     Unix.setsockopt fd Unix.SO_REUSEADDR true;
     Unix.setsockopt fd Unix.SO_REUSEPORT true;
     Unix.bind fd (Unix.ADDR_INET (ipaddr_of_host host, port));
     Unix.listen fd backlog;
     Unix.set_nonblock fd
   with e ->
     Unix.close fd;
     raise e);
  fd

(* An Eio listening socket for the CURRENT domain over a dup of [fd]; the dup is closed with [sw]. *)
let import ~sw (fd : Unix.file_descr) : [ `Unix_fd | [ `Generic | `Unix ] Eio.Net.listening_socket_ty ] Eio.Std.r =
  let d = Unix.dup ~cloexec:true fd in
  Unix.set_nonblock d;
  Eio_unix.Net.import_socket_listening ~sw ~close_unix:true d

let port_of_fd (fd : Unix.file_descr) : int =
  match Unix.getsockname fd with Unix.ADDR_INET (_, p) -> p | Unix.ADDR_UNIX _ -> 0
