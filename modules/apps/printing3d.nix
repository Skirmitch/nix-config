{ pkgs, ... }: {
  # --- 3D PRINTING ---
  environment.systemPackages = with pkgs; [
    orca-slicer
  ];
}
