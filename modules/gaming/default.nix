{ ... }: {
  imports = [ ./aagl.nix ];

  # --- GAMING ---
  programs.steam.enable = true;
  hardware.xpadneo.enable = true;
}
