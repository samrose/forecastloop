{
  description = "ForecastLoop dev environment: Elixir 1.20 on OTP 28, PostgreSQL 18";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        beam = pkgs.beam28Packages;
        elixir = beam.elixir_1_20;
        postgres = pkgs.postgresql_18;
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            beam.erlang
            elixir
            postgres
            pkgs.git
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.fswatch ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.inotify-tools ];

          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export PATH=$MIX_HOME/bin:$MIX_HOME/escripts:$HEX_HOME/bin:$PATH
            export ERL_AFLAGS="-kernel shell_history enabled"
            export LANG=C.UTF-8

            # Project-local PostgreSQL 18 cluster in ./.pgdata, listening on a unix socket in ./.pgdata.
            export PGDATA=$PWD/.pgdata
            export PGHOST=$PGDATA
            export PGPORT=5432
            export PGUSER=postgres
            if [ ! -d "$PGDATA" ]; then
              initdb --auth=trust --username=postgres -D "$PGDATA" >/dev/null
              echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
              echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"
            fi
            echo "PostgreSQL: run 'pg_ctl -l \$PGDATA/log start' to start the local cluster."
          '';
        };
      });
}
