{ inputs, ... }: {
  # --- GENSHIN IMPACT (AAGL) ---
  nix.settings = {
    substituters = [ "https://ezkea.cachix.org" ];
    trusted-public-keys = [ "ezkea.cachix.org-1:ioBmUbJTZIKsHmWWXPe1FSFbeVe+afhfgqgTSNd34eI=" ];
  };

  programs.anime-game-launcher.enable = true;

  nixpkgs.overlays = [
    inputs.aagl.overlays.default
  ];
}
