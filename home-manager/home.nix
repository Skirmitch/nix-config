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
      diff = "nix store diff-closures /run/current-system $(sudo nix build --no-link --print-out-paths ~/nix-config#nixosConfigurations.diana.config.system.build.toplevel 2>/dev/null)";
      update = "sudo nix flake update ~/nix-config && sudo nixos-rebuild switch --flake ~/nix-config#diana";
      nordconnect = "sudo wgnord connect";
      norddisconnect = "sudo wgnord disconnect";
    };
  };

  programs.home-manager.enable = true;
}
