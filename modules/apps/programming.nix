{ pkgs, ... }: {
  # --- PROGRAMMING / DEV TOOLS ---
  environment.systemPackages = with pkgs; [
    vscode
    awscli2
    ssm-session-manager-plugin
    nodejs
    jetbrains.rust-rover
    sqlite
    file
  ];
}
