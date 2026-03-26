{ ... }: {
  # --- USER DEFINITIONS ---
  users.users.skirmitch = {
    isNormalUser = true;
    description = "Skirmitch";
    extraGroups = [ "networkmanager" "wheel" "video" "dialout" ];
    hashedPassword = "$y$j9T$z7hQ9X7Lykrjb38n3V2y8/$jS7EbPmQZQHHt1VS8wTAHtTOS.YtgXK7BtU.H75iiL0";
  };

  users.users.root = {
    # COPY YOUR ROOT hashedPassword FROM hosts/desktop/default.nix
    hashedPassword = "$y$j9T$//7vocA0e8I58ihBSCM1.1$GWGXy9DfvYZPxQt8WYMWn9DQco2ACo8Dlt2vZ3RXf/7";
  };
}
