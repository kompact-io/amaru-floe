{
  description = "Amaru + floe, orchestrated with process-compose";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    amaru = {
      url = "github:kompact-io/amaru/nix-proper";
    };
    floe.url = "github:kompact-io/floe";
    grom = {
      url = "github:qf-studio/grom";
      flake = false;
    };
  };

  outputs = inputs @ {flake-parts, ...}: let
    stackModule = {
      pkgs,
      lib,
      ...
    }: {
      imports = [./nix/modules];
    };
    network = "preprod";
    upstreamNodes = {
      preprod = ["preprod-node.play.dev.cardano.org:3001"];
    };
    # TODO :: make this more robust
    seedArchive = "./snapshots/preprod/130982398.6b78e3cbc65e4cc9ca036c03ab125697b9a31954f55219bf7ad5397d63286c43.tar.zst";
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
      imports = [inputs.process-compose-flake.flakeModule];

      # Reusable by other flakes: process-compose.<name>.imports = [ this ];
      flake.processComposeModules.default = stackModule;

      perSystem = {
        config,
        system,
        pkgs,
        self',
        ...
      }: {
        packages = {
          amaru = inputs.amaru.packages.${system}.amaru;
          floe = inputs.floe.packages.${system}.floe;
          floe-client = inputs.floe.packages.${system}.floe-client;
          floe-smoke = inputs.floe.packages.${system}.floe-smoke;
          grom = pkgs.callPackage ./nix/pkgs/grom {src = inputs.grom;};
          # nix run .#monitor   in a second terminal: grom dashboard over VictoriaMetrics
          monitor = config.process-compose.stack.cardano.monitoring.tui;
          default = self'.packages.stack;
        };

        process-compose.stack = {
          imports = [stackModule];

          cardano = {
            inherit network;
            dataDir = "./data";

            amaru = {
              package = self'.packages.amaru;
              upstream = upstreamNodes.${network};
              listen.port = 3000;
              submitApi = "127.0.0.1:8090";
            };

            floe = {
              inherit seedArchive;
              package = self'.packages.floe;
              mkArgs = inputs.floe.lib.mkArgs;
              port = 9001;
            };

            monitoring.grom.package = self'.packages.grom;

            smoke = {
              enable = true;
              package = self'.packages.floe-smoke;
              mkArgs = inputs.floe.lib.mkSmokeArgs;
              # Covers a real catch-up window, not just floe-smoke's
              # own 30s default -- see smoke.nix's own doc.
              readyTimeoutSecs = 600;
              submit = true;
              skeyFile = "./.env";
            };
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [self'.packages.amaru pkgs.process-compose pkgs.curl pkgs.jq];
        };
      };
    };
}
