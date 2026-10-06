# CLAUDE.md — ocaml-common

Shared library (`primal_common`) for all Primal OCaml daemons; see `README.md` for the module map
and `../ocaml-plan.md` for the overall port plan (this is §4 of it).

- Build/test from any project dir with this project's flake:
  `nix develop "path:$(git rev-parse --show-toplevel)/ocaml-common" -c dune build @all`
  (`dune test` for alcotest). `_build/` is at the repo root (one dune workspace).
- OCaml 5 + Eio only, no Lwt. `[%pgsql]` for SQL (checked against live `primal1`; membership tables
  against `primal_membership_ref`, see `sql/membership-refdb-setup.sh`).
- Changing a module here affects every consumer: after an edit, build the whole workspace
  (`dune build @all` from the repo root) and redeploy the importer with
  `../ocaml-importer/rebuild-restart-importer.sh`.
- Keep it generic: nothing importer-, api- or job-specific lands here (no counters records, no
  handlers, no job loops). Parameterise (as `Worker_pool` is over `'est`) instead.
- A PGOCaml connection is single-fiber; `Postgres.use` closes a poisoned connection and refills
  the slot lazily — never return a connection to a pool after a non-`PostgreSQL_Error` exception.
- Third-party fixes go in `patches/` and are applied in `flake.nix` with `overrideAttrs` (httpun-ws 0.2.0
  delivered only the head of its frame queue per socket read; test "ws burst" fails without the patch).
- Domain safety, learned the hard way: `Str` and `Stdlib.Parsing` (ocamlyacc) are not domain-safe (SIGSEGV)
  — use `Re` and guard parsers with a mutex; `Eio.Process` forks a multi-GB process (use `Unix.create_process_env`);
  `Mirage_crypto_rng_unix.use_default ()` per domain; Postgres connections and Eio sockets are domain-bound;
  `MALLOC_ARENA_MAX=2` halves RSS; DNS lookups need the cache in `Http.resolve`.
- Headless browser for end-to-end checks: `nix shell nixpkgs#chromium` + python playwright (README "Build").
