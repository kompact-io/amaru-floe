# VictoriaMetrics (scrapes + stores, Prometheus-compatible API) + grom (terminal dashboard).
# Components register scrape targets under cardano.monitoring.targets.
# Dashboard in a second terminal:  nix run .#monitor   (keys: ? help, enter zoom, +/- range)
{
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkEnableOption mkIf types;
  top = config.cardano;
  cfg = top.monitoring;
  dir = "${top.dataDir}/monitoring";
  vm = cfg.victoriametrics;
  json = name: v: pkgs.writeText name (builtins.toJSON v);
  yaml = pkgs.formats.yaml {};

  scrapeConfig = json "scrape.yml" {
    global.scrape_interval = vm.scrapeInterval;
    scrape_configs =
      lib.mapAttrsToList (job: t: {
        job_name = job;
        metrics_path = t.path;
        static_configs = [{targets = [t.address];}];
      })
      cfg.targets;
  };

  # ── Dashboard (grom native format; grid is 24 columns wide) ──────────────
  gromUnit = u:
    {
      decimal = "short";
      seconds = "s";
      bytes = "bytes";
    }.${
      u
    };

  # grom can't render text/labels in a stat -- numeric value + threshold
  # color only. One stat row for "is it healthy" (cheap to check, rarely
  # changes); the real estate below goes to what actually moves -- "up" and
  # "UTxOs total" earned their keep better as lines than as static numbers.
  stat = {
    title,
    expr,
    unit ? "decimal",
    thresholds ? [],
    x,
    y ? 0,
  }:
    {
      type = "stat";
      inherit title;
      unit = gromUnit unit;
      sparkline = true;
      grid = {
        inherit x y;
        w = 6;
        h = 4;
      };
      queries = [{inherit expr;}];
    }
    // lib.optionalAttrs (thresholds != []) {inherit thresholds;};

  # Timeseries; `queries` = [ { expr; legend; } ]. y is offset below the one stat row.
  #
  # These render as filled braille *area* charts, not solid blocks -- that's
  # already the softer of grom's two single-series options. Checked once
  # (don't re-check): grom's `WidgetSpec` (internal/config/config.go) has no
  # field selecting a plain-line style; `TimeSeries.Solid` (block-character
  # fallback) is never set from the YAML path (only construction site is
  # `NewTimeSeries` in internal/app/build.go, which never touches it) so it's
  # always false here; and `render.BrailleLine` (pkg/tui/render/braille.go)
  # exists but nothing in the app ever calls it. Getting actual unfilled
  # lines needs a patch to grom itself (a style:line field wired to
  # BrailleLine) -- not just a dashboard config change.
  series = {
    title,
    queries,
    unit ? "decimal",
    x,
    y,
    w ? 12,
    h ? 8,
  }: {
    type = "timeseries";
    inherit title queries;
    unit = gromUnit unit;
    grid = {
      inherit x w h;
      y = y + 4;
    };
  };

  single = args @ {
    expr,
    legend ? "",
    ...
  }:
    series (removeAttrs args ["expr" "legend"] // {queries = [{inherit expr legend;}];});

  widgets = [
    (stat {
      title = "floe: stage (0 seed/1 catchup/2 run)";
      expr = "floe_stage";
      x = 0;
      thresholds = [
        {color = "red";}
        {
          value = 1;
          color = "yellow";
        }
        {
          value = 2;
          color = "green";
        }
      ];
    })
    (stat {
      title = "floe: sync depth (blocks)";
      expr = "floe_depth";
      x = 6;
      thresholds = [
        {color = "green";}
        {
          value = 500;
          color = "yellow";
        }
        {
          value = 2160;
          color = "red";
        }
      ];
    })
    (stat {
      title = "floe: rollbacks (total)";
      expr = "floe_rolled_back_total";
      x = 12;
    })
    (stat {
      title = "floe: tip slot";
      expr = "floe_tip_slot";
      x = 18;
    })

    (single {
      title = "floe: up over time (gaps/0 = crashed)";
      expr = ''up{job="floe"}'';
      legend = "up";
      x = 0;
      y = 0;
    })
    (single {
      title = "floe: sync depth over time";
      expr = "floe_depth";
      legend = "depth";
      x = 12;
      y = 0;
    })

    # One shared linear y-scale across catchup and running would make
    # running's throughput (a handful of UTxOs/min on preprod) invisible
    # next to catchup's (thousands/sec) -- so split by stage with PromQL
    # masking (`and`) rather than one chart: each gets its own scale, and
    # the `and` leaves a gap (not a false zero) for the stage it isn't.
    #
    # min_over_time(...)==2, not instantaneous floe_stage==2: rate(...[1m])
    # looks *backward* 60s, so right at the catchup->running switch the
    # first sample(s) already labeled "running" still have that window
    # straddling catchup's tail -- a brief, enormous false spike otherwise.
    # Requiring the stage to have BEEN 2 for the whole lookback window
    # excludes exactly those straddling samples.
    (single {
      title = "floe: catchup throughput (created/sec)";
      expr = "rate(floe_utxos_created_total[1m]) and (max_over_time(floe_stage[1m]) == 1)";
      legend = "created/s";
      x = 0;
      y = 8;
    })
    (single {
      title = "floe: running throughput (created/min)";
      expr = "rate(floe_utxos_created_total[1m]) * 60 and (min_over_time(floe_stage[1m]) == 2)";
      legend = "created/min";
      x = 12;
      y = 8;
    })

    (single {
      title = "floe: UTxO set size over time";
      expr = "floe_utxo_count";
      legend = "utxos";
      x = 0;
      y = 16;
      w = 24;
    })
  ];

  dashboard = yaml.generate "amaru-floe-dashboard.yaml" {
    title = "amaru-floe";
    theme = "tokyo-night";
    refresh = "10s";
    range = "1h";
    inherit widgets;
  };

  # A TUI needs a real terminal, so it's a package to run, not a process-compose process.
  tui = pkgs.writeShellApplication {
    name = "monitor";
    text = ''
      exec ${lib.getExe cfg.grom.package} run --config ${dashboard} --prom ${vm.url} "$@"
    '';
  };
in {
  options.cardano.monitoring = {
    enable = mkEnableOption "VictoriaMetrics + grom" // {default = true;};

    targets = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          address = mkOption {
            type = types.str;
            description = "host:port";
          };
          path = mkOption {
            type = types.str;
            default = "/metrics";
          };
        };
      });
      default = {};
      description = "Scrape targets by job name. Components register themselves; add more here.";
      example = {floe = {address = "127.0.0.1:9001";};};
    };

    victoriametrics = {
      package = mkOption {
        type = types.package;
        default = pkgs.victoriametrics;
      };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
      };
      port = mkOption {
        type = types.port;
        default = 8428;
      };
      scrapeInterval = mkOption {
        type = types.str;
        default = "10s";
      };
      retention = mkOption {
        type = types.str;
        default = "15d";
      };
      memoryMiB = mkOption {
        type = types.ints.positive;
        default = 64;
        description = "Soft cap: GOMEMLIMIT and cache size.";
      };
      url = mkOption {
        type = types.str;
        readOnly = true;
        default = "http://${vm.host}:${toString vm.port}";
      };
    };

    grom.package = mkOption {
      type = types.package;
      description = "The grom terminal dashboard.";
    };

    tui = mkOption {
      type = types.package;
      readOnly = true;
      default = tui;
      description = "The `monitor` launcher.";
    };
  };

  config = mkIf cfg.enable {
    settings.processes.victoriametrics = {
      command = pkgs.writeShellApplication {
        name = "victoriametrics-run";
        runtimeInputs = [pkgs.coreutils];
        text = ''
          mkdir -p "${dir}/victoriametrics"
          export GOMEMLIMIT=${toString vm.memoryMiB}MiB
          exec ${lib.getExe' vm.package "victoria-metrics"} \
            -storageDataPath="${dir}/victoriametrics" \
            -retentionPeriod=${vm.retention} \
            -memory.allowedBytes=${toString (vm.memoryMiB * 1024 * 1024 * 3 / 4)} \
            -promscrape.config=${scrapeConfig} \
            -httpListenAddr=${vm.host}:${toString vm.port}
        '';
      };
      readiness_probe = {
        http_get = {
          host = vm.host;
          port = vm.port;
          path = "/health";
        };
        period_seconds = 5;
      };
      availability.restart = "on_failure";
    };
  };
}
