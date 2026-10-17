# Entry module: shared options + component imports.
{lib, ...}: {
  imports = [./amaru.nix ./floe.nix ./monitoring.nix ./smoke.nix];

  options.cardano = {
    network = lib.mkOption {
      type = lib.types.enum ["mainnet" "preprod" "preview"];
      default = "preprod";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "./data";
      description = "State root; relative paths resolve against process-compose CWD.";
    };
  };
}
