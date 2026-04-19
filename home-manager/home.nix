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
    initExtra = ''
    rebuild() {
        if [ -z "$1" ]; then
          echo "Usage: rebuild <message>"
          return 1
        fi
        cd ~/nix-config && echo "$*" > .nixos-label && git add -A && git commit -m "$*" && sudo nixos-rebuild switch --flake ~/nix-config#diana
      }
    '';
    shellAliases = {
      dif = "cd /home/skirmitch/nix-config && nix flake update && nixos-rebuild build --flake ~/nix-config#diana && nvd diff /run/current-system ./result";
      update = "cd /home/skirmitch/nix-config && sudo nix flake update /home/skirmitch/nix-config && rebuild \"Updated previous system\"";
      nordconnect = "sudo wgnord connect";
      norddisconnect = "sudo wgnord disconnect";
    };
  };

  programs.home-manager.enable = true;
}
