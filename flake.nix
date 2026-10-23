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

    # aagl's overlay builds its three launchers with rust-bin from
    # oxalica/rust-overlay, which aagl pins in its OWN lock at 2026-07-31 -
    # thirteen days short of 892c035d ("treewide: stdenv.is* ->
    # stdenv.hostPlatform.is*", 2026-08-13). That stale rev is why every eval of
    # this system printed "stdenv.isLinux is deprecated" and the isDarwin twin,
    # out of rust-overlay's lib/mk-aggregated.nix, for code we neither wrote nor
    # import directly.
    #
    # A bare `nix flake update` can never clear it: recreating the lock honours
    # each input flake's own lock for that flake's inputs, so rust-overlay stays
    # exactly where aagl left it - and d82d6d6f is still the newest aagl commit
    # as of 2026-10-23, so waiting it out is not a plan.
    #
    # Pinned to the fix commit itself rather than HEAD, and by rev so that
    # `nix flake update` cannot move it. At 892c035d `rust-bin.stable.latest` is
    # still Rust 1.97.1 and the commit only renames stdenv attributes, so the
    # toolchain derivation comes out bit-identical: VERIFIED 2026-10-23 that
    # system.build.toplevel.drvPath is unchanged and `nix-store --realise
    # --dry-run` has nothing to build. Tracking HEAD instead costs 43
    # derivations - a whole Rust 1.99.1 toolchain plus anime-game-launcher
    # rebuilt from source, forfeiting the ezkea.cachix.org hit - and re-pays it
    # every time stable Rust moves, for no benefit this config can observe.
    #
    # DELETE this input and the follows below once aagl bumps its own lock past
    # 2026-08-13; the warnings are already fixed upstream.
    rust-overlay.url = "github:oxalica/rust-overlay/892c035d7c2ff75acd5da10424a47ab454e1f3dc";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    aagl.inputs.rust-overlay.follows = "rust-overlay";
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

    # Health Connect pipeline (store side): ~/Projects/hc-sync exposes
    # packages.hc-store and packages.datasette; modules/apps/health-store.nix
    # consumes them. A path input is re-copied on `nix flake update`, which
    # is the intended way to roll a new version onto the box.
    # `path:` copies the working tree verbatim - .gitignore and all, including
    # .git - so it used to ship 84 MB of Android build intermediates to
    # /nix/store on every lock (finding 36, v3 63). Build outputs now live in
    # ~/.cache/hc-sync (android/build.gradle.kts + gradle.properties), which
    # keeps the copy at ~1 MB. Switch to git+file:///home/skirmitch/Projects/hc-sync
    # once the repo has its first commit: that copies tracked files only and
    # gives the deployed system a revision to be identified by.
    hc-sync.url = "path:/home/skirmitch/Projects/hc-sync";
    hc-sync.inputs.nixpkgs.follows = "nixpkgs";
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
        # Not `system = ...`: that feeds the deprecated nixpkgs.system. Setting
        # the platform as a module is the current idiom and evaluates to a
        # byte-identical toplevel.
        specialArgs = { inherit inputs nixosLabel; };
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
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
