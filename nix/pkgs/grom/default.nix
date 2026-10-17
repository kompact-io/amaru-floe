# grom: btop-style terminal dashboards for Prometheus (github:qf-studio/grom, MIT).
# `src` is the flake input. Bump vendorHash (build prints the real one) when the input changes.
{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "grom";
  version = "unstable";
  inherit src;
  subPackages = ["cmd/grom"];
  vendorHash = "sha256-/1niwdNbfERsA4R5jPNoUbYlRs3Xpn9Cvfxn0EXiBSk=";
  meta = {
    description = "btop-style terminal dashboards for Prometheus";
    mainProgram = "grom";
    license = lib.licenses.mit;
  };
}
