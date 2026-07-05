{
  description = "Skirmitch's NixOS Flake Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    impermanence.url = "github:nix-community/impermanence";

    home-manager = {
      # Un-pinned 2026-06-05 back to master: nixpkgs nixos-unstable rolled over to
      # 26.11, so the temporary release-26.05 pin (2026-05-30) became the stale side
      # and tripped the mismatch warning. HM has no release-26.11 branch yet; master
      # tracks unstable and reports 26.11 (release.json), matching nixpkgs.
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Un-pinned 2026-06-05 back to main alongside home-manager: nixpkgs reached 26.11,
    # so the temporary release-26.05 pin (2026-06-01) now mismatches. aagl has no
    # release-26.11 branch; main declares aaglReleaseBranch = "26.11", matching nixpkgs.
    aagl.url = "github:ezKEa/aagl-gtk-on-nix";
    aagl.inputs.nixpkgs.follows = "nixpkgs";
    # UNPINNED 2026-07-05: back to tracking HEAD. The long pin saga is over —
    # upstream v3.0.0 (PR #763, 2026-07-04) rebased the package onto Anthropic's
    # OFFICIAL Linux .deb, so it no longer patches minified code and no longer
    # hangs on the Windows-only readRegistryValues() call (#729) that forced the
    # 7dbe93b pin. PR #730 (our old pin's head) was CLOSED unmerged; the fix
    # landed via #737 instead, then #763 superseded the whole approach. Verified
    # 2026-07-05 on Diana against HEAD (app 1.18286.0): builds clean, launches,
    # app-ready in ~1s. See modules/apps/claude.nix for what that rebase let us
    # delete and how to isolation-test a future bump.
    # History: pinned 7dbe93b (#730 head, 1.14271.0) 2026-06-22; 2d1d0c5
    # (1.12603.1) 2026-06-17; un-pinned 2026-06-15; pinned e85450c 2026-06-12.
    claude-desktop.url = "github:aaddrick/claude-desktop-debian";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, home-manager, impermanence, aagl, ... }@inputs:
    let
      nixosLabel = let
        labelPath = ./.nixos-label;
        raw = if builtins.pathExists labelPath
          then builtins.readFile labelPath
          else "default";
        # Make readable substitutions first, then hard-filter to the charset
        # system.nixos.label allows ([a-zA-Z0-9:_.-]) so stray chars like '+'
        # can't break the build.
        mapped = builtins.replaceStrings ["\n" " " "/"] ["" "_" "-"] raw;
        chars = nixpkgs.lib.stringToCharacters mapped;
        clean = builtins.concatStringsSep ""
          (builtins.filter (c: builtins.match "[a-zA-Z0-9:_.-]" c != null) chars);
      in builtins.substring 0 50 clean;

      mkHost = hostName: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs nixosLabel; };
        modules = [
          ./hosts/${hostName}
          impermanence.nixosModules.impermanence
          home-manager.nixosModules.home-manager
          aagl.nixosModules.default
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.skirmitch = import ./home-manager/home.nix;
          }
        ];
      };
    in {
      nixosConfigurations = {
        diana = mkHost "diana";
        lenovo = mkHost "lenovo";
      };
    };
}
