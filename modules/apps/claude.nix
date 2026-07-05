{ inputs, pkgs, ... }:
{
  # Claude Desktop for Linux, via aaddrick/claude-desktop-debian.
  #
  # As of upstream v3.0.0 (PR #763, 2026-07-04) this package is a repackage of
  # Anthropic's OFFICIAL Linux .deb: fetchurl + dpkg + autoPatchelfHook, keeping
  # the vendored Electron ELF (like nixpkgs' discord/vscode). It is NOT the old
  # reverse-engineered rebuild that patched minified code. That retirement is the
  # whole reason this module shrank: the failure class we spent months pinning
  # and sed-failsafing around — "an upstream patch stopped matching the new
  # bundle, aborting the rebuild" and "app 1.14271 hangs before app-ready on the
  # Windows-only readRegistryValues() call (#729)" — simply does not exist when
  # we ship Anthropic's own tested binary. Verified 2026-07-05 on Diana: builds
  # clean, launches, reaches app-ready in ~1s.
  #
  # What we therefore DROPPED versus the pre-v3 module:
  #   - the applyPatches + two seds against scripts/patches/config.sh (guarded
  #     the old minified-code patches; no such patching now).
  #   - the node-pty callPackage (nix/node-pty.nix is gone; the .deb is prebuilt).
  #   - the CLAUDE_DISABLE_GPU=0 makeWrapper (there is no aaddrick launcher script
  #     anymore; the NVIDIA+Wayland EGL/GPU crash-loop is fixed upstream in
  #     nix/claude-desktop.nix via glvnd/EGL appendRunpaths + a VK_ADD_DRIVER_FILES
  #     wrapper — a proper fix, not our env-var latch bypass).
  #
  # So this is now just: pull in upstream's overlay, install its package. Input
  # tracks HEAD unpinned again (see flake.nix). If a future bump ever misbehaves,
  # test in isolation first:
  #   nix build github:aaddrick/claude-desktop-debian#claude-desktop
  #   <result>/bin/claude-desktop --user-data-dir=$(mktemp -d)   # look for app-ready
  #
  # Bare `claude-desktop` vs `claude-desktop-fhs`: upstream's default is the -fhs
  # variant, a buildFHSEnv that puts nodejs/uv/docker (for MCP servers) and
  # qemu_kvm/OVMF (for Cowork's VM guest) on the app's runtime PATH. We install
  # the BARE app instead — it matches the non-FHS setup Diana has always run, and
  # avoids qemu_kvm's ~1.5 GB closure for a Cowork VM feature we don't use. Swap
  # pkgs.claude-desktop -> pkgs.claude-desktop-fhs below if you want Cowork's VM
  # or guaranteed node/uv/docker for npx/uvx-spawned MCP servers. (The overlay
  # defines both attrs, so either name resolves.)
  nixpkgs.overlays = [ inputs.claude-desktop.overlays.default ];

  environment.systemPackages = [
    pkgs.claude-desktop
    inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    # claude-code's `/voice` records the mic via sox's `rec` when its native
    # audio module doesn't load (the fallback path Diana hits). Recording only.
    pkgs.sox
  ];
}
