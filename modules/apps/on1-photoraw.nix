{ pkgs, ... }:
let
  # ON1 Photo RAW on Linux = the WINDOWS build under Wine. ON1 has never
  # shipped a native Linux version (verified 2026-07-12: the specs page lists
  # only Windows 11 / macOS 13+, and "Linux" exists on on1.com solely as a
  # login-walled feature request). The community-tested route is Lutris +
  # GE-Proton, with three non-negotiable prefix ingredients:
  #   1. Microsoft .NET 4.8 OFFLINE installer — without it ON1 installs but
  #      renders a blank window (the #1 reported failure; the in-wizard
  #      "download .NET" prompts do NOT work).
  #   2. WinMetadata.zip extracted into system32/WinMetadata (WinRT metadata,
  #      needed by ON1's WinML/DirectML AI path).
  #   3. winetricks vcrun2022 corefonts tahoma win11 renderer=vulkan.
  # Sources: https://code.mendhak.com/on1-photo-raw-linux/  (guide, 2026-04-04)
  #          https://lutris.net/games/on1-photo-raw/        (script, 2026-04-09)
  # GPU accel is confirmed working under this recipe (AMD reports; NVIDIA on
  # Linux is unreported territory — the 3060 Ti meets ON1's "recommended"
  # 8 GB VRAM spec, and DXVK/vkd3d-proton sidesteps the Windows-side NVIDIA
  # DirectML VRAM bug, but first launch will be the real test).
  #
  # Version: 2026.4.1, build 20.4.1.18862 (released 2026-06-25). Installer
  # URLs are ON1's own CDN (cachefly), published in their Zendesk release-note
  # articles — the HTML 403s bots but the JSON API is open:
  #   standalone: https://on1help.zendesk.com/api/v2/help_center/en-us/articles/39165360108045.json
  #   MAX:        https://on1help.zendesk.com/api/v2/help_center/en-us/articles/39165445373581.json
  # To UPDATE: pull the new gm_NNNNN link from those articles, bump build +
  # hash below. Old build dirs stay live (gm_18729 still serves), so the pin
  # doesn't rot quickly.
  #
  # INSTALL FLOW (one-time, after nixos-rebuild):
  #   1. protonup-qt  → add version → GE-Proton10-34 → target: Lutris
  #   2. on1-install  → Lutris opens; click through the .NET 4.8 wizard
  #      ("Restart later" at the end), then the ON1 wizard (keep the default
  #      TargetDir; decline "launch now" at the end).
  #   3. Launch from the ON1 desktop entry (or Lutris), sign in to activate.
  #      Gotcha: ON1's login endpoint 500s on passwords with several special
  #      characters (confirmed by ON1 support, Apr 2026) — if sign-in fails,
  #      simplify the account password first, don't debug Wine.
  # Edits live in .on1 sidecars next to the photos if enabled in
  # Preferences → Files → Sidecar Options — do that; the catalog DB inside the
  # prefix is explicitly not portable.

  # Flip to "max" if the license is Photo RAW MAX (same build, own installer).
  edition = "standalone";

  # Each edition carries its OWN build: they are released together but were
  # pinned at different times here, and a single shared `build` silently
  # invalidated the other edition's hash whenever one was bumped.
  editions = {
    standalone = rec {
      installerName = "ON1_Photo_RAW_2026.exe";
      # 2026.5.1 (20.5.1.19148), released 2026-08-31.
      build = "19148";
      hash = "sha256-FWyDBI9MDnhpbxJR/sT/1TqETOs62Gj+01LPY7uZmvY=";
      windowsDir = "ON1 Photo RAW 2026";
      exeName = "${windowsDir}.exe";
    };
    max = rec {
      installerName = "ON1_Photo_RAW_MAX_2026.exe";
      # Last hash verified here; MAX is also at 19148 upstream but that build
      # was never downloaded, so this stays on the one whose hash is known.
      # gm_18862 still serves (checked 2026-09-18). To move MAX to 19148, bump
      # this build and take the new hash from the build error.
      build = "18862";
      hash = "sha256-sIbkMlTKSd15xAwpyktVfikB4c2RWENBQ+eDR/FijoY=";
      # Unconfirmed default install dir for MAX — the wizard shows it; if it
      # differs, fix the exe path afterwards in Lutris (game → Configure).
      windowsDir = "ON1 Photo RAW MAX 2026";
      exeName = "${windowsDir}.exe";
    };
  };
  ed = editions.${edition};

  slug = "on1-photo-raw-2026";
  prefixDir = "Games/${slug}";

  on1Installer = pkgs.fetchurl {
    url = "https://ononesoft.cachefly.net/photoraw2026/win/gm_${ed.build}/${ed.installerName}";
    inherit (ed) hash;
  };

  dotnet48 = pkgs.fetchurl {
    url = "https://download.visualstudio.microsoft.com/download/pr/2d6bb6b2-226a-4baa-bdec-798822606ff1/8494001c276a4b96804cde7829c04d7f/ndp48-x86-x64-allos-enu.exe";
    hash = "sha256-aMmYao3MAhTZCaofMb7p+1Rhu4Oe3KmWp1sI3f/BSD8=";
  };

  winMetadata = pkgs.fetchurl {
    url = "https://archive.org/download/win-metadata/WinMetadata.zip";
    hash = "sha256-AuXCiWsSZ1VItldrz54Ul+ZDoMT1/cis5cETpVSpVKA=";
  };

  # The lutris.net script verbatim. Files must stay as "N/A:" picker prompts:
  # Lutris (tested 2026-07-12, 0.5.x) routes any non-N/A files: entry —
  # including $SCRIPTDIR-relative local paths — through its HTTP downloader,
  # and python-requests has no file:// adapter, so the install dies with
  # "No connection adapters were found". The on1-install wrapper stages the
  # nix-store artifacts in ~/.cache/on1-install; pick them there (Ctrl+L in
  # the GTK picker, paste the path).
  installScript = pkgs.writeText "on1-photo-raw-lutris.yml" ''
    name: ON1 Photo RAW 2026
    game_slug: ${slug}
    version: NixOS nix-staged files
    slug: ${slug}
    runner: wine

    script:
      files:
        - setup: N/A:Select ${ed.installerName} from ~/.cache/on1-install
        - dotnet_installer: N/A:Select ndp48-x86-x64-allos-enu.exe from ~/.cache/on1-install
        - WinMetadata: N/A:Select WinMetadata.zip from ~/.cache/on1-install

      game:
        arch: win64
        prefix: $GAMEDIR
        exe: $GAMEDIR/drive_c/Program Files/ON1/${ed.windowsDir}/${ed.exeName}

      wine:
        version: GE-Proton10-34
        dxvk: true
        vkd3d: true

      installer:
        - task:
            name: create_prefix
            description: Creating Wine prefix...
            arch: win64
            prefix: $GAMEDIR

        - task:
            name: wineexec
            description: Installing .NET 4.8 (click through; pick "Restart later" at the end)
            prefix: $GAMEDIR
            executable: dotnet_installer

        - execute:
            file: mkdir
            args: -p "$GAMEDIR/drive_c/windows/system32/WinMetadata"
            description: Creating WinMetadata directory...

        - execute:
            file: unzip
            args: -j -q -o $WinMetadata -d "$GAMEDIR/drive_c/windows/system32/WinMetadata"
            description: Extracting WinRT metadata files...

        - task:
            name: winetricks
            description: Installing dependencies (vcrun2022, fonts, win11, vulkan renderer)...
            arch: win64
            prefix: $GAMEDIR
            app: "--unattended --force vcrun2022 corefonts tahoma win11 renderer=vulkan"

        - task:
            name: wineexec
            description: Running ON1 installer (keep default path; decline launch at the end)...
            arch: win64
            prefix: $GAMEDIR
            executable: $setup
            args: TargetDir="C:\Program Files\ON1\${ed.windowsDir}"
  '';

  on1Install = pkgs.writeShellScriptBin "on1-install" ''
    set -euo pipefail
    stage="''${XDG_CACHE_HOME:-$HOME/.cache}/on1-install"
    rm -rf "$stage" && mkdir -p "$stage"
    ln -s ${on1Installer} "$stage/${ed.installerName}"
    ln -s ${dotnet48}     "$stage/ndp48-x86-x64-allos-enu.exe"
    ln -s ${winMetadata}  "$stage/WinMetadata.zip"
    cp ${installScript} "$stage/on1-photo-raw.yml"

    if ! ls "$HOME/.local/share/lutris/runners/wine" 2>/dev/null | grep -q "GE-Proton10-34"; then
      echo "NOTE: GE-Proton10-34 not found in ~/.local/share/lutris/runners/wine."
      echo "      Run protonup-qt first (add version -> GE-Proton10-34 -> Lutris),"
      echo "      or let Lutris pick a runner when it asks (untested versions may work)."
    fi
    echo "Staged installer files in $stage — handing off to Lutris."
    exec lutris -i "$stage/on1-photo-raw.yml"
  '';

  # UPDATING an existing install. on1-install must NOT be used for this: it
  # hands Lutris a fresh install script, which builds a NEW prefix and would
  # leave the signed-in account, licence state and preferences behind in the
  # old one (they live in
  # <prefix>/drive_c/users/steamuser/AppData/Roaming/ON1, not in the store).
  # This runs the pinned installer INSIDE the existing prefix with the same
  # GE-Proton runner Lutris uses, so ON1 upgrades in place: account, settings
  # and the Lutris game entry all survive, and the exe path is unchanged
  # ("ON1 Photo RAW 2026.exe" across 2026.x), so the desktop entry keeps
  # working. AppData/Roaming/ON1 is tarred up first as cheap insurance.
  on1Update = pkgs.writeShellScriptBin "on1-update" ''
    set -euo pipefail
    prefix="$HOME/${prefixDir}"
    appdata="$prefix/drive_c/users/steamuser/AppData/Roaming/ON1"

    if [ ! -d "$prefix/drive_c" ]; then
      echo "No existing prefix at $prefix." >&2
      echo "This command only UPDATES an install; use on1-install for a first one." >&2
      exit 1
    fi

    runner=$(ls -d "$HOME/.local/share/lutris/runners/wine"/GE-Proton* 2>/dev/null | sort -V | tail -1 || true)
    if [ -z "$runner" ]; then
      echo "No GE-Proton runner under ~/.local/share/lutris/runners/wine." >&2
      echo "Run protonup-qt and add one (target: Lutris)." >&2
      exit 1
    fi

    # Pick a wine that can actually RUN, not just one that exists. GE-Proton
    # ships files/bin/wine as a 32-bit i386 binary whose ELF interpreter is
    # /lib/ld-linux.so.2; NixOS' nix-ld only provides the 64-bit
    # /lib64/ld-linux-x86-64.so.2, so exec'ing it fails with a bare
    # "No such file or directory" that names the wrapper, not the missing
    # loader. wine64 is the 64-bit sibling and is what a win64 app like ON1
    # needs anyway. `--version` is the liveness test: it fails for a missing
    # interpreter exactly as it would for a missing file.
    wine=""
    for cand in "$runner/files/bin/wine64" "$runner/files/bin/wine"; do
      if [ -x "$cand" ] && "$cand" --version >/dev/null 2>&1; then
        wine="$cand"; break
      fi
    done
    if [ -z "$wine" ]; then
      echo "Found runner $runner but neither wine64 nor wine is runnable there." >&2
      echo "(A 32-bit-only wine cannot start on this host: no /lib/ld-linux.so.2.)" >&2
      exit 1
    fi

    # Insurance only: an in-place upgrade does not touch AppData. The
    # regenerable bulk is skipped deliberately -- AppData/Roaming/ON1 is ~6.4 GB
    # here and almost all of it is re-downloadable or rebuildable
    # (PhotoSettingsCache 4.2G, Models 1.5G, NDService 641M, the browse caches).
    # What is kept is the small irreplaceable part: licence/account state,
    # preferences, plists and the component/lens databases.
    if [ -d "$appdata" ]; then
      stamp=$(date +%Y-%m-%d-%H%M%S)
      backup="''${XDG_CACHE_HOME:-$HOME/.cache}/on1-update/ON1-settings-$stamp.tar.gz"
      mkdir -p "$(dirname "$backup")"
      tar -C "$(dirname "$appdata")" \
        --exclude=ON1/PerfectBrowseCache \
        --exclude='ON1/*/PhotoSettingsCache' \
        --exclude='ON1/*/Models' \
        --exclude='ON1/*/NDService' \
        --exclude='ON1/*/ExploreService' \
        -czf "$backup" ON1
      echo "Backed up account/settings -> $backup ($(du -h "$backup" | cut -f1))"
    else
      echo "NOTE: no AppData/Roaming/ON1 yet; nothing to back up."
    fi

    echo "Runner : $wine ($("$wine" --version 2>/dev/null))"
    echo "Prefix : $prefix"
    echo "Installing ${ed.installerName} (build ${ed.build}) into the EXISTING prefix."
    echo "Keep the default install directory so it upgrades in place."
    exec env WINEPREFIX="$prefix" "$wine" ${on1Installer}
  '';

  desktopItem = pkgs.makeDesktopItem {
    name = "on1-photo-raw";
    desktopName = "ON1 Photo RAW 2026";
    comment = "Photo editor (Windows build via Lutris/GE-Proton)";
    exec = "lutris lutris:rungame/${slug}";
    icon = "lutris";
    categories = [ "Graphics" "Photography" ];
  };
in {
  environment.systemPackages = [
    pkgs.lutris
    pkgs.protonup-qt # one-time: fetches the GE-Proton runner into Lutris
    pkgs.unzip # the install script's WinMetadata extract step runs host unzip
    on1Install
    on1Update
    desktopItem
  ];
}
