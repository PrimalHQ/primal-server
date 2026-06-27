{
  # OCaml 5 translation of the Julia Nostr cache *importer* (primal-server/src/cache_storage.jl).
  # Eio-native only (no Lwt). SQL is statically checked at compile time by the PGOCaml
  # [%pgsql] ppx, which connects to the reference database described by PG* below.
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
        ];
        # Libraries used by the importer. Eio-native; no lwt.
        importerLibs = [
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
          # TLS / crypto stack for LNURL-over-SOCKS5 (zapper verification).
          ocamlPkgs.tls
          ocamlPkgs.tls-eio
          ocamlPkgs.x509
          ocamlPkgs.ca-certs
          ocamlPkgs.mirage-crypto
          ocamlPkgs.mirage-crypto-rng
          ocamlPkgs.ptime
          ocamlPkgs.domain-name
        ];
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            ocamlPkgs.ocaml
            ocamlPkgs.dune_3
            ocamlPkgs.findlib
            ocamlPkgs.ocaml-lsp
            ocamlPkgs.alcotest
            pkgs.postgresql_16
          ] ++ importerLibs ++ cLibs;

          # Reference database for compile-time [%pgsql] schema checking.
          # Created once with sql/refdb-setup.sh (loads sql/importer_schema.sql).
          PGHOST = "127.0.0.1";
          PGPORT = "54017";
          PGDATABASE = "primal_importer_ref";
          PGUSER = "pr";
        };

        packages.default = ocamlPkgs.buildDunePackage {
          pname = "primal_importer";
          version = "0.1.0";
          src = ./.;
          buildInputs = importerLibs ++ cLibs;
          # NOTE: the package build also needs PG* pointing at a reachable reference DB
          # with the importer schema, because [%pgsql] type-checks at compile time.
        };
      });
}
