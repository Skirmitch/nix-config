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
    # PINNED 2026-06-22 to PR #730's head (7dbe93b) — the FIX for the 1.13576.0+
    # runtime hang. Background: the 1.13576.0 bump (da341d) through 1.14271.0
    # (d7e0611) built fine but hung before app-ready and never opened a window
    # (verified GPU on/off; our claude.nix seds are no-ops against those revs, so
    # it was upstream, not us — issue #729). Root cause, per PR #730: app 1.14271
    # calls the Windows-only `readRegistryValues()` at startup, which throws a
    # TypeError on Linux and stalls before app-ready. PR #730 shims that call.
    # VERIFIED 2026-06-22: built `.#…diana.pkgs.claude-desktop` against 7dbe93b
    # (still app 1.14271.0), launched it, main.log reached app-ready in ~1s and
    # the window opened. So this rev gets us the working newer version while the
    # PR is unmerged. modules/apps/claude.nix's build-time seds still apply for
    # the older #649/addTrustedFolder *build* breaks (no-ops here).
    # UNPIN when PR #730 MERGES: drop the rev suffix below (back to bare
    # ".../claude-desktop-debian"), re-lock, rebuild. Until then this is an
    # unmerged PR commit — keep an eye on github.com/aaddrick/claude-desktop-debian/pull/730.
    # UNPIN TEST for future bumps: override this input to HEAD, rebuild, then
    # `CLAUDE_DISABLE_GPU=0 timeout 30 claude-desktop` and confirm
    # ~/.config/Claude/logs/main.log gains a fresh "app-ready" line.
    # History: pinned 2d1d0c5 (1.12603.1) 2026-06-17; un-pinned 2026-06-15;
    # pinned e85450c 2026-06-12.
    claude-desktop.url = "github:aaddrick/claude-desktop-debian/7dbe93b317f568d1eb97f9eb0c6d6d81437425d7";
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
