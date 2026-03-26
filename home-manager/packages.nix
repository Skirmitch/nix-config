{ pkgs, ... }: {
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
}
