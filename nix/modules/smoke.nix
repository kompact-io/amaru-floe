{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkEnableOption mkIf types;
  top = config.cardano;
  cfg = top.smoke;
  exe = lib.getExe' cfg.package "floe-smoke";
in {
  options.cardano.smoke = {
    enable = mkEnableOption "a floe-smoke oneshot service (crates/client/src/bin/smoke/main.rs), for deploy tooling to trigger via `systemctl start floe-smoke` -- not wanted by any target, since it asserts against *this* deployment's live data rather than running continuously";
    package = mkOption {
      type = types.package;
      description = "The floe-smoke package (this flake's `packages.floe-smoke`).";
    };
    mkArgs = mkOption {
      type = types.functionTo (types.listOf types.str);
      description = "floe-smoke's own `lib.mkSmokeArgs`: run-config attrs -> CLI argv.";
    };
    grpc = mkOption {
      type = types.nullOr types.str;
      default = top.floe.url;
      description = "floe-smoke's --grpc. Defaults to cardano.floe's gRPC address.";
    };
    # Same shape as floe's own http/httpJson/httpCbor -- one --http
    # address, plus --http-json/--http-cbor bools picking which wire
    # format(s) to dial against it (negotiated per request via Accept),
    # not addresses of their own. See ../lib.nix (floe's) `mkSmokeArgs`.
    http = mkOption {
      type = types.nullOr types.str;
      default = top.floe.urlRest;
      description = "floe-smoke's --http. Defaults to cardano.floe's REST address.";
    };
    httpJson = mkOption {
      type = types.bool;
      default = true;
      description = "floe-smoke's --http-json. Ignored if http is null.";
    };
    httpCbor = mkOption {
      type = types.bool;
      default = true;
      description = "floe-smoke's --http-cbor. Ignored if http is null.";
    };
    skeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "EnvironmentFile providing FLOE_SMOKE_SKEY.";
    };
    readyTimeoutSecs = mkOption {
      type = types.ints.positive;
      default = 30;
      description = ''
        floe-smoke's --ready-timeout-secs: budget for the initial
        per-scheme ready-wait, and (with `submit`) each relay hop's
        visibility poll -- a real catch-up window, or a slow Cardano
        block, can both easily exceed floe-smoke's own 30s default.
      '';
    };
    submit = mkEnableOption ''
      a self-pay + verify via SubmitTx (--submit) -- exercises the
      write path, not just reads of whatever's already there. Requires
      funds at FLOE_SMOKE_SKEY's own address
    '';
    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra floe-smoke flags not otherwise exposed as an option, e.g. [ \"--pay-cred\" \"...\" ].";
    };
  };

  config = mkIf cfg.enable {
    settings.processes.floe-smoke = {
      command = let
        args = cfg.mkArgs {
          inherit (cfg) grpc http httpJson httpCbor;
          extraArgs =
            [
              "--ready-timeout-secs"
              (toString cfg.readyTimeoutSecs)
              # floe-smoke's own --network default (mainnet) only
              # affects the bech32 prefix it *logs* for the derived
              # address (the pay-hash it searches/submits against is
              # network-independent) -- reuse the stack's own network
              # rather than let that mislead a reader of the logs.
              "--network"
              top.network
            ]
            ++ lib.optionals cfg.submit ["--submit"] ++ cfg.extraArgs;
        };
        run = "${exe} ${lib.escapeShellArgs args}";
      in
        if cfg.skeyFile != null
        then "bash -c 'set -a; source ${cfg.skeyFile}; set +a; ${run}'"
        else run;
      depends_on.floe.condition = "process_healthy";
    };
  };
}
