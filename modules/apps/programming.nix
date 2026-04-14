{ pkgs, ... }: {
  # --- PROGRAMMING / DEV TOOLS ---
  environment.systemPackages = with pkgs; [
    vscode
    awscli2
    nodejs
    jetbrains.rust-rover
  ];
}
