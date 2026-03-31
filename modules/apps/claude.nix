{ inputs, pkgs, ... }: {
  nixpkgs.overlays = [ inputs.claude-desktop.overlays.default ];
  environment.systemPackages = [
    pkgs.claude-desktop
    inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
