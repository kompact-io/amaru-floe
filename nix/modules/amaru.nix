{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkEnableOption mkIf types;
  top = config.cardano;
  cfg = top.amaru;
  helpers = import ./lib.nix {inherit pkgs;};
  dir = "${top.dataDir}/amaru/${top.network}";
  pidFile = "${dir}/amaru.pid";
  exe = lib.getExe' cfg.package "amaru";
  peers = lib.concatMapStringsSep " " (p: "--peer-address ${p}") cfg.upstream;
in {
  options.cardano.amaru = {
    enable = mkEnableOption "Amaru node" // {default = true;};
    package = mkOption {type = types.package;};
    upstream = mkOption {
      type = types.nonEmptyListOf types.str;
      description = "Upstream peers (host:port) Amaru syncs from.";
    };
    listen = {
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
      };
      port = mkOption {
        type = types.port;
        default = 3000;
      };
    };
    address = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.listen.host}:${toString cfg.listen.port}";
      description = "N2N endpoint floe connects to as a chainsync/blockfetch client.";
    };
    bootstrap = mkOption {
      type = types.bool;
      default = true;
      description = "Run `amaru bootstrap` once before the node (skipped if ledger exists).";
    };
    submitApi = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        host:port for amaru's own HTTP Cardano Submit API
        (`POST /api/submit/tx`, raw tx CBOR as the body). `null`
        (default) leaves it disabled -- opt-in, same as floe's own
        `--node-socket`-based `SubmitService` this bypasses entirely.
      '';
    };
    log = mkOption {
      type = types.str;
      default = "info";
      description = "RUST_LOG filter.";
    };
    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
    };
  };

  config = mkIf cfg.enable {
    settings.processes = {
      amaru-bootstrap = mkIf cfg.bootstrap {
        command = pkgs.writeShellApplication {
          name = "amaru-bootstrap";
          text = ''
            if [ -d "${dir}/ledger.db" ]; then echo "already bootstrapped"; exit 0; fi
            mkdir -p "${dir}"
            ${exe} bootstrap --network ${top.network} \
              --ledger-dir "${dir}/ledger.db" --chain-dir "${dir}/chain.db"
          '';
        };
      };

      amaru = {
        command = pkgs.writeShellApplication {
          name = "amaru-node";
          text = ''
            export RUST_LOG=${lib.escapeShellArg cfg.log}
            mkdir -p "${dir}"
            exec ${exe} node run --network ${top.network} ${peers} \
              --listen-address ${cfg.address} \
              --ledger-dir "${dir}/ledger.db" --chain-dir "${dir}/chain.db" \
              --pid-export "${pidFile}" \
              ${lib.optionalString (cfg.submitApi != null) "--submit-api-listen-on ${cfg.submitApi}"} \
              ${lib.escapeShellArgs cfg.extraArgs}
          '';
        };
        depends_on = mkIf cfg.bootstrap {
          amaru-bootstrap.condition = "process_completed_successfully";
        };
        readiness_probe = {
          exec.command = helpers.listenProbe cfg.listen.host cfg.listen.port;
          initial_delay_seconds = 2;
          period_seconds = 3;
          failure_threshold = 100;
        };
        availability.restart = "on_failure";
      };
    };
  };
}
