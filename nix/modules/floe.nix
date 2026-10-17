# floe: the UTxO index itself, syncing chainsync/blockfetch directly
# against amaru (no oura/utxo-cache hop). `mkArgs` is floe's own pure
# CLI-argv builder (its flake's `lib.mkArgs`, wired in from flake.nix,
# where `inputs` is in scope); process-compose specifics (readiness_probe,
# availability, depends_on) are this stack's own concern, same as every
# other component module here.
#
# floe-server went gRPC-first (dropped REST, see its own plan-rpc.md),
# but its `/health`/`/metrics` routes were always a separate concern
# and are back (`--metrics host:port`, alongside `--grpc`) -- readiness
# here is a real `/health` check (reports ready once past seed/catch-up,
# see floe's own `metrics.rs`), and floe is registered as a
# monitoring.targets scrape target again. REST is also back, as its
# own transport (`--http host:port`, mirroring gRPC) -- see floe's own
# plan-dto-http.md.
{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkEnableOption mkIf types;
  top = config.cardano;
  cfg = top.floe;
  dir = "${top.dataDir}/floe/${top.network}";
  db = "${dir}/floe.sqlite";
  exe = lib.getExe' cfg.package "floe";
  magicOf = {
    mainnet = 764824073;
    preprod = 1;
    preview = 2;
  };
  metricsAddr = "${cfg.metricsHost}:${toString cfg.metricsPort}";
  httpAddr = "${cfg.httpHost}:${toString cfg.httpPort}";
  args = cfg.mkArgs {
    inherit db;
    peer = top.amaru.address;
    magic = magicOf.${top.network};
    seed = cfg.seedArchive;
    grpc = "${cfg.host}:${toString cfg.port}";
    http = httpAddr;
    httpJson = true;
    httpCbor = true;
    metrics = metricsAddr;
    amaruSubmitApi = top.amaru.submitApi;
    inherit (cfg) k margin pruneInterval;
  };
in {
  options.cardano.floe = {
    enable = mkEnableOption "floe UTxO index" // {default = true;};
    package = mkOption {
      type = types.package;
      description = "floe's own `packages.floe`.";
    };
    mkArgs = mkOption {
      type = types.functionTo (types.listOf types.str);
      description = "floe's own `lib.mkArgs`: run-config attrs -> CLI argv.";
    };
    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "gRPC QueryService listen host.";
    };
    port = mkOption {
      type = types.port;
      default = 9001;
      description = "gRPC QueryService listen port.";
    };
    metricsHost = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "`/health`/`/metrics` listen host.";
    };
    metricsPort = mkOption {
      type = types.port;
      default = 9002;
      description = "`/health`/`/metrics` listen port.";
    };
    httpHost = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "REST transport listen host (see floe's own plan-dto-http.md).";
    };
    httpPort = mkOption {
      type = types.port;
      default = 9003;
      description = "REST transport listen port.";
    };
    seedArchive = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Amaru bootstrap snapshot (<slot>.<hash>.tar.zst) to seed from, skipped
        once already seeded. A relative path resolves against process-compose's
        CWD, like `cardano.dataDir` -- not a Nix path, so it's read at run
        time and never copied into the store.
      '';
    };
    k = mkOption {
      type = types.ints.positive;
      default = 32400; # ~1.5 epochs' worth of blocks (15 * consensus k=2160), not the bare minimum -- see floe's own --k.
      description = "Reorg depth, and how much history `prune` retains.";
    };
    margin = mkOption {
      type = types.ints.unsigned;
      default = 500;
      description = "Margin added to k before switching out of catch-up.";
    };
    pruneInterval = mkOption {
      type = types.ints.positive;
      default = 100;
      description = "Blocks between running-mode prunes.";
    };
    url = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.host}:${toString cfg.port}";
      description = "gRPC QueryService address, e.g. for `floe-client --server`.";
    };
    urlRest = mkOption {
      type = types.str;
      readOnly = true;
      default = httpAddr;
      description = "REST transport address, e.g. for `floe-client --transport http --server`.";
    };
  };

  config = mkIf cfg.enable {
    cardano.monitoring.targets.floe = {address = metricsAddr;};

    settings.processes.floe = {
      command = "mkdir -p ${lib.escapeShellArg dir} && exec ${exe} ${lib.escapeShellArgs args}";
      # amaru's own readiness_probe (amaru.nix) now checks its N2N
      # listener is actually bound (not just that the process is
      # alive), so "process_healthy" here is safe to connect against
      # straight away -- see lib.nix's `listenProbe` doc comment for
      # why that used to race floe's first connect attempt.
      depends_on.amaru.condition = "process_healthy";
      readiness_probe = {
        # A real `/health` check, not just "is the port open": always
        # 200 (seeding/catching-up/ready are all normal operation, not
        # a failure an orchestrator should restart over -- see
        # `metrics.rs`'s `health_handler`), so this only ever fails
        # while the process genuinely isn't listening yet.
        http_get = {
          host = cfg.metricsHost;
          port = cfg.metricsPort;
          path = "/health";
        };
        # floe seeds (can take minutes on a large snapshot) before its
        # HTTP server even starts -- same tolerance amaru.nix gives its
        # own slow bootstrap below, needed for the same reason: the
        # default failure_threshold (3) kills it ~15s in, long before
        # seeding finishes, restarting it forever.
        initial_delay_seconds = 5;
        period_seconds = 5;
        failure_threshold = 100;
      };
      availability.restart = "on_failure";
    };
  };
}
