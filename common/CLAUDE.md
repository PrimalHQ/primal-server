# CLAUDE.md — common

Shared library (`primal_common`) for all Primal OCaml daemons; `README.md` has the module map.

- Build/test from any project dir with the workspace's flake (`nix/`):
  `nix develop "path:$(git rev-parse --show-toplevel)/nix" -c dune build @all`
  (`dune test` for alcotest). `_build/` is at the repo root (one dune workspace).
- OCaml 5 + Eio only, no Lwt. `[%pgsql]` for SQL, checked at compile time against a cache DB and a
  `primal_membership_ref` DB made from `schema/` (the dev shell sets `PG*`; override them inside it with
  `-c env PGPORT=... dune build`). `selfhost/primal.sh init` creates such a cluster.
- Changing a module here affects every consumer: after an edit, build the whole workspace
  (`dune build @all` from the repo root) and run the tests.
- Schema changes are migrations in the repo's `sql/migrations/` (see its README); apply them before building code that
  needs them, since the `[%pgsql]` checks see the schema.
- Keep it generic: nothing importer-, api- or job-specific lands here (no counters records, no
  handlers, no job loops). Parameterise (as `Worker_pool` is over `'est`) instead.
- A PGOCaml connection is single-fiber; `Postgres.use` closes a poisoned connection and refills
  the slot lazily — never return a connection to a pool after a non-`PostgreSQL_Error` exception.
- Third-party fixes go in `nix/patches/` and are applied in `nix/flake.nix` with `overrideAttrs` (httpun-ws 0.2.0
  delivered only the head of its frame queue per socket read; test "ws burst" fails without the patch).
- Domain safety: `Str` and `Stdlib.Parsing` (ocamlyacc) are not domain-safe (SIGSEGV) — use `Re` and guard
  parsers with a mutex; `Eio.Process` forks a multi-GB process (use `Unix.create_process_env`);
  `Mirage_crypto_rng_unix.use_default ()` per domain; Postgres connections and Eio sockets are domain-bound;
  `MALLOC_ARENA_MAX=2` halves RSS; DNS lookups go through the cache in `Http.resolve`.
- Outbound connections whose target comes from untrusted input must go through a proxy or check
  `Http.is_public_ip` on every hop.
- This repo is public: no deployment details (hosts, IPs, internal ports, paths) in files or commit messages.
