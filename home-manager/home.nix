{ ... }: {
  imports = [ ./packages.nix ];

  home.username = "skirmitch";
  home.homeDirectory = "/home/skirmitch";
  home.stateVersion = "25.11";

  # GNOME specific overrides
  dconf.settings = {
    "org/gnome/shell" = {
      enabled-extensions = [ "kimpanel@kde.org" ];
    };
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      rebuild = "sudo nixos-rebuild switch --flake ~/nix-config#diana";
      update = "sudo nixos-rebuild switch --flake ~/nix-config#diana --upgrade";
    };
  };

  programs.home-manager.enable = true;
}
