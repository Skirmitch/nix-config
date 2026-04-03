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
      dif = "nix store diff-closures /run/current-system $(sudo nix build --no-link --print-out-paths ~/nix-config#nixosConfigurations.diana.config.system.build.toplevel 2>/dev/null)";
      update = "cd /home/skirmitch/nix-config && sudo nix flake update /home/skirmitch/nix-config && sudo nixos-rebuild switch --flake /home/skirmitch/nix-config#diana";
      nordconnect = "sudo wgnord connect";
      norddisconnect = "sudo wgnord disconnect";
#      gomono = "pactl load-module module-remap-sink sink_name=mono channels=1 channel_map=mono master=$(pactl list short sinks | grep RUNNING | grep -v mono | head -1 | cut -f2) remix=yes && pactl set-default-sink mono";
#      gostereo = "pactl unload-module module-remap-sink && pactl set-default-sink $(pactl list short sinks | grep -v mono | head -1 | cut -f2)";
    };
  };

  programs.home-manager.enable = true;
}
