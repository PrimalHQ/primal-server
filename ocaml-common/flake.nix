{
  # The ONE OCaml toolchain for every Primal OCaml project in this repo (ocaml-common, ocaml-api,
  # ocaml-importer, ocaml-fetcher, ocaml-jobs) and for the private ocaml-ext in the parent repo.
  # OCaml 5 / Eio only (no Lwt). SQL is statically checked at compile time by the PGOCaml
  # [%pgsql] ppx against the live database named by PG* below.
  #
  # Use it from any project directory:  nix develop "path:<repo>/ocaml-common" -c dune build @all
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ocamlPkgs = pkgs.ocaml-ng.ocamlPackages_5_3;
        # C libraries the OCaml bindings link against.
        cLibs = [
          pkgs.secp256k1 # libsecp256k1; our own C stubs bind schnorrsig verify (BIP340)
          pkgs.zlib # camlzip (zlib EVENTS frames in the API)
        ];
        # httpun-ws 0.2.0 (master too) hands the application only the head of its parsed-frame
        # queue per socket read: when one client write carries three or more frames, the third
        # and later ones wait until the peer sends more bytes (browsers open a cache connection
        # with a burst of 15+ REQs, so the feeds never answered). patches/ fixes
        # Websocket_connection._next_read_operation; test "ws burst" in test/ covers it.
        httpun-ws = ocamlPkgs.httpun-ws.overrideAttrs (o: {
          patches = (o.patches or [ ]) ++ [ ./patches/httpun-ws-frame-queue.patch ];
        });
        ocamlLibs = [
          ocamlPkgs.eio
          ocamlPkgs.eio_main
          ocamlPkgs.eio_posix
          ocamlPkgs.pgocaml
          ocamlPkgs.pgocaml_ppx
          ocamlPkgs.yojson
          ocamlPkgs.ppx_yojson_conv
          ocamlPkgs.ppx_yojson_conv_lib
          ocamlPkgs.hex
          ocamlPkgs.uuidm
          ocamlPkgs.digestif
          ocamlPkgs.saturn
          # TLS / crypto stack (LNURL over SOCKS5, outbound relay WebSockets, S3/CDN APIs).
          ocamlPkgs.tls
          ocamlPkgs.tls-eio
          ocamlPkgs.x509
          ocamlPkgs.ca-certs
          ocamlPkgs.mirage-crypto
          ocamlPkgs.mirage-crypto-rng
          ocamlPkgs.ptime
          ocamlPkgs.domain-name
          # Pure-Eio DNS (lib/net/dns_eio.ml): getaddrinfo blocks a systhread that Eio cannot
          # cancel, so it escapes request timeouts.
          ocamlPkgs.dns
          ocamlPkgs.dns-client
          ocamlPkgs.ipaddr
          ocamlPkgs.cstruct
          ocamlPkgs.mtime
          # HTTP/1.1 + WebSocket server stack (ocaml-api), as used by the tsunami kernel.
          ocamlPkgs.httpun
          ocamlPkgs.httpun-eio
          httpun-ws
          ocamlPkgs.gluten
          ocamlPkgs.gluten-eio
          # Misc.
          ocamlPkgs.base64
          ocamlPkgs.xmlm
          ocamlPkgs.camlzip
        ];
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            ocamlPkgs.ocaml
            ocamlPkgs.dune_3
            ocamlPkgs.findlib
            ocamlPkgs.ocaml-lsp
            ocamlPkgs.ocamlformat
            ocamlPkgs.alcotest
            pkgs.postgresql_16
            pkgs.jq
          ] ++ ocamlLibs ++ cLibs;

          # Live cache database (primal1) used for compile-time [%pgsql] schema checking of
          # cache-DB queries (and by the dev tools at runtime). Production daemons read their
          # connections from their JSON config file, not from these.
          PGHOST = "127.0.0.1";
          PGPORT = "54017";
          PGDATABASE = "primal1";
          PGUSER = "pr";

          # Membership DB (Julia :membership). Used at runtime by the dev tools; membership-table
          # queries are compile-time checked against the local schema-only clone
          # primal_membership_ref (sql/membership-refdb-setup.sh) via per-directory dune env.
          # The host is deployment-specific: export PGMEMBERSHIPHOST in the environment (the code
          # falls back to PGHOST).
          PGMEMBERSHIPPORT = "5432";
          PGMEMBERSHIPDATABASE = "primal";
          PGMEMBERSHIPUSER = "primal";
        };

        packages.default = ocamlPkgs.buildDunePackage {
          pname = "primal_common";
          version = "0.1.0";
          src = ./.;
          buildInputs = ocamlLibs ++ cLibs;
          # NOTE: the package build also needs PG* pointing at a reachable DB carrying the
          # schema, because [%pgsql] type-checks at compile time.
        };
      });
}
