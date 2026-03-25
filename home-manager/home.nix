{ pkgs, ... }: {
  home.username = "skirmitch";
  home.homeDirectory = "/home/skirmitch";
  home.stateVersion = "25.11"; 

  home.packages = with pkgs; [
    jq
    discord
    vivaldi
    git
    gedit
    btop
    nano
    pciutils
    dmidecode
    gnomeExtensions.kimpanel
    nvitop
  ];

  # GNOME specific overrides [cite: 13]
  dconf.settings = {
    "org/gnome/shell" = {
      enabled-extensions = [ "kimpanel@kde.org" ];
    };
  };

  programs.home-manager.enable = true;
}
