{ inputs, pkgs, ... }: {
  nixpkgs.overlays = [ inputs.claude-desktop.overlays.default ];
  environment.systemPackages = [ pkgs.claude-desktop ];
}
