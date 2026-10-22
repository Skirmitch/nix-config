{ pkgs, ... }:
let
  # --- fixavi: batch-rebuild missing AVI indexes -------------------------
  #
  # An AVI's idx1 index lives at the END of the file, so it is the first thing
  # lost when a file is truncated, carved out of free space, or pulled off a
  # failing disk. Without it a player must scan the whole stream to seek, and
  # many refuse outright. JL hit this constantly in forensic work and rebuilding
  # by hand took a long time.
  #
  # Two strategies, cheapest first:
  #   1. ffmpeg stream-copy remux — rebuilds the index without re-encoding, so
  #      it is fast and lossless. Works whenever the stream itself is intact.
  #   2. mencoder -forceidx — scans and rebuilds the index in place. Slower, but
  #      recovers files whose header ffmpeg will not accept.
  # Originals are never modified; output goes to <name>.fixed.avi.
  fixavi = pkgs.writeShellApplication {
    name = "fixavi";
    runtimeInputs = [ pkgs.ffmpeg pkgs.mplayer pkgs.mediainfo ];
    text = ''
      set -uo pipefail
      [ $# -eq 0 ] && { echo "usage: fixavi FILE.avi [more.avi ...]   (or: fixavi *.avi)"; exit 2; }
      ok=0; failed=0; skipped=0
      for f in "$@"; do
        [ -f "$f" ] || { echo "MISSING  $f"; continue; }
        # Strip the extension from the BASENAME only. `''${f%.*}` cuts at the last dot
        # anywhere in the PATH, so extensionless inputs behind a dotted path
        # component (./f0001, recup.1/clip) all collapse onto ONE output name and
        # every file after the first is SKIPped. Carved files are the main use
        # case here and they routinely have no extension.
        case "$(basename "$f")" in
          *.*) out="''${f%.*}.fixed.avi" ;;
          *)   out="$f.fixed.avi" ;;
        esac
        if [ -e "$out" ]; then echo "SKIP     $out already exists"; skipped=$((skipped+1)); continue; fi
        printf '%s ... ' "$f"
        if ffmpeg -v error -err_detect ignore_err -i "$f" -map 0 -c copy -fflags +genpts "$out" </dev/null 2>/dev/null \
           && [ -s "$out" ]; then
          echo "fixed by remux  ($(du -h "$out" | cut -f1))"; ok=$((ok+1))
        else
          rm -f "$out"
          if mencoder -quiet -forceidx -oac copy -ovc copy "$f" -o "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
            echo "fixed by mencoder -forceidx  ($(du -h "$out" | cut -f1))"; ok=$((ok+1))
          else
            rm -f "$out"; echo "COULD NOT REPAIR"; failed=$((failed+1))
          fi
        fi
      done
      echo "---"; echo "repaired $ok   failed $failed   skipped $skipped"
      echo "originals untouched; repaired files are *.fixed.avi"
    '';
  };

  # --- ltrace: its TEST FIXTURE will not compile under C++20 ----------------
  #
  # GCC 16 defaults to C++20, where ltrace's own fixture `volatile int Fv_Vi(void)`
  # draws -Wvolatile ("'volatile'-qualified return type is deprecated"). ltrace's
  # dejagnu harness counts ANY compiler output as a failed compile, so the demangle
  # test program is never built and all 15 demangle.exp cases FAIL. That failed the
  # whole toplevel, because ltrace is in systemPackages below and therefore in
  # system-path - which is how a single leaf package blocked `nix flake update`.
  #
  # THE BINARY IS NOT AFFECTED, and that was established before this was written
  # rather than assumed. On 2026-10-01: the new ltrace traces and demangles
  # identically to generation 265's across {old,new} x {gcc-15 probe, gcc-16 probe}
  # x {-C, raw}, every demangled name matches binutils c++filt, and its embedded
  # __cxa_demangle agrees with the old one on 85,789 real mangled names. With only
  # the fixture's compile fixed the suite gives 244 pass / 0 fail / 1 unsupported -
  # the old baseline exactly.
  #
  # SO THIS IS NOT `doCheck = false`. That would also work, and would throw away a
  # 244-test regression gate for every future bump. Patch the fixture's compile
  # flags and keep every test running instead.
  #
  # THE LAST LINE IS A TRIPWIRE, not a sanity check. If upstream ever edits
  # demangle.exp the sed stops matching, the count fails, and the build breaks
  # LOUDLY - so this overlay is removed rather than quietly outliving its reason.
  # The accepted cost: `dif` goes red again at that moment. That is the point.
  # Upstream had no fix as of 2026-10-01 (nixpkgs' last ltrace commit: 2026-01-01).
  ltraceCxx20FixtureOverlay = _final: prev: {
    ltrace = prev.ltrace.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        sed -i \
          -e 's/\[list debug c++\]/[list debug c++ additional_flags=-Wno-volatile]/' \
          -e 's/\[list debug shlib=\$lib_sl c++\]/[list debug shlib=\$lib_sl c++ additional_flags=-Wno-volatile]/' \
          testsuite/ltrace.minor/demangle.exp
        test "$(grep -c 'Wno-volatile' testsuite/ltrace.minor/demangle.exp)" -eq 2
      '';
    });
  };

  # --- v4l2loopback: it ships the KERNEL's depmod index --------------------
  #
  # Kernel 7.3 broke the module tree. `nixos-rebuild build` fails with
  #
  #   pkgs.buildEnv error: two given paths contain a conflicting subpath:
  #     `...-v4l2loopback-0.15.4/lib/modules/7.3.0/modules.alias' and
  #     `...-linux-7.3-modules/lib/modules/7.3.0/modules.alias'
  #
  # and the toplevel dies on that one dependency, so `dif` never reaches
  # `nvd diff` and prints nothing useful. NOTE THAT EVAL IS GREEN: `nix eval` on
  # the toplevel drvPath succeeds, so this is only visible in a build log.
  #
  # v4l2loopback-0.15.4 installs TEN depmod index files next to its own .ko -
  # modules.alias{,.bin}, modules.dep{,.bin}, modules.softdep,
  # modules.symbols{,.bin}, modules.builtin.alias.bin, modules.builtin.bin,
  # modules.devname - and every one of them is also in the kernel's output.
  #
  # nixpkgs already tries to stop this: the derivation's preBuild runs
  # `sed -i '/depmod/d' Makefile`. It no longer matches, and unlike the
  # `substituteInPlace --replace-fail` on the line above it, a bare sed FAILS
  # SILENTLY. depmod is invoked by the kernel's own scripts/Makefile.modinst via
  # `make modules_install`, which that sed cannot reach at all.
  #
  # THIS IS NOT A WORKAROUND. pkgs/os-specific/linux/kmod/aggregator.nix - the
  # buildEnv that refuses above - does exactly this in its own postBuild:
  #     rm -f $out/lib/modules/$kernelVersion/modules.!(builtin*|order*)
  #     depmod -b $out -C $out/etc/depmod.d -a $kernelVersion
  # It deletes and regenerates the very files that made the merge refuse. But
  # buildEnv merges BEFORE postBuild, so that cleanup is never reached. The index
  # we strip here is thrown away and rebuilt by depmod regardless, which is why
  # this carries no functional risk.
  #
  # Remove ALL of modules.*, not the aggregator's !(builtin*|order*) subset:
  # v4l2loopback also ships modules.builtin.alias.bin and modules.builtin.bin,
  # and those are in the kernel's set too, so sparing `builtin*` would leave two
  # live collisions and fail identically one file later.
  #
  # Scoped to linuxPackages_latest.extend, NOT a top-level `v4l2loopback`
  # override: pkgs.v4l2loopback DOES NOT EXIST (checked - `nix eval` on it
  # errors), so overriding that name would define a fresh attribute nothing
  # consumes and the build would fail exactly as before. Verified instead with a
  # probe marker that the extend really reaches
  # linuxPackages_latest.v4l2loopback before this was written.
  # boot.kernelPackages = pkgs.linuxPackages_latest in hosts/diana/default.nix.
  #
  # v4l2loopback is not droppable: programs.immersed.enable pulls it in, and
  # modules/apps/g9cam.nix needs devices=2 video_nr=0,9 for the Lumix G9 cam.
  # Measured 2026-10-22: it is the ONLY offender - xpadneo and the nvidia kernel
  # modules ship 0 index files each.
  #
  # THE `test -e` IS A TRIPWIRE, not a sanity check. When upstream or nixpkgs
  # stops shipping the index, it fails loudly and this overlay gets deleted
  # rather than quietly outliving its reason. Same contract as the ltrace
  # overlay above: `dif` goes red at that moment, and that is the point.
  v4l2loopbackDepmodIndexOverlay = _final: prev: {
    linuxPackages_latest = prev.linuxPackages_latest.extend (
      _lpfinal: lpprev: {
        v4l2loopback = lpprev.v4l2loopback.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            for d in "$out"/lib/modules/*/; do
              test -e "$d/modules.alias"
              rm -f "$d"/modules.*
            done
          '';
        });
      }
    );
  };
  # --- mozc: Qt 6.12's uic rejects its fully-qualified widget class --------
  #
  # Qt 6.12 made `uic` validate custom-widget class names, and a LEADING `::`
  # is no longer accepted. mozc 2.30.5544.102 uses one, so the build dies at
  #
  #   gui/dictionary_tool/dictionary_tool.ui:
  #     Invalid class name: "::mozc::gui::DictionaryContentTableWidget"
  #   File 'gui/dictionary_tool/dictionary_tool.ui' is not valid
  #
  # which cascades mozc -> fcitx5-mozc -> fcitx5-with-addons -> system-path ->
  # toplevel. That is the SECOND independent breakage in the 2026-10-22 input
  # bump; the first was v4l2loopback above. They are unrelated.
  #
  # Exactly one .ui file is affected and it names the class twice: once as the
  # widget's `class=` attribute and once in its <customwidget><class> entry.
  # Checked across every .ui in the tree - dictionary_tool.ui is the only hit.
  #
  # DROPPING THE `::` WAS NOT ASSUMED TO BE SAFE. The worry was real: if uic
  # emitted its header inside `namespace mozc::gui`, the unqualified name would
  # resolve to mozc::gui::mozc::gui::... and fail to compile, which is exactly
  # the kind of thing that looks fine in a diff. So it was built first, in a
  # throwaway expression outside this repo: exit 0, zero errors, and
  # lib/mozc/mozc_tool - the binary that hosts this very dialog - is in the
  # output. Only then was it written here.
  #
  # `--replace-fail` IS the tripwire, and it is free: substituteInPlace errors
  # when the string is gone, so the day upstream or nixpkgs fixes this the build
  # goes red and this overlay gets deleted instead of silently doing nothing.
  # That contrast is the whole lesson of the v4l2loopback block above, where
  # nixpkgs' own `sed -i '/depmod/d'` stopped matching and failed SILENTLY,
  # which is what broke the kernel module tree in the first place.
  mozcUicQualifiedClassOverlay = _final: prev: {
    mozc = prev.mozc.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/gui/dictionary_tool/dictionary_tool.ui \
          --replace-fail '"::mozc::gui::DictionaryContentTableWidget"' \
                         '"mozc::gui::DictionaryContentTableWidget"' \
          --replace-fail '<class>::mozc::gui::DictionaryContentTableWidget</class>' \
                         '<class>mozc::gui::DictionaryContentTableWidget</class>'
      '';
    });
  };
in
{
  imports = [ ./locale.nix ];

  # --- NIX SETTINGS ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = [
    ltraceCxx20FixtureOverlay
    v4l2loopbackDepmodIndexOverlay
    mozcUicQualifiedClassOverlay
  ];

  # Hard-link identical files in the store. Measured 2026-09-25: 12.7 GiB of
  # duplicates had accumulated and /nix/store/.links was empty, because this
  # defaults to false. Costs a little time on each store write; pays for itself
  # on a box that rebuilds daily. The existing backlog needs a one-off
  # `sudo nix-store --optimise` — this only stops it growing again.
  nix.settings.auto-optimise-store = true;

  # Emergency GC during a build. The weekly timer freed 34.7 / 42.6 / 18.3 /
  # 53.8 GiB on successive Sundays: that swing is larger than the free space we
  # usually carry, so a big rebuild between timers is the realistic way to hit
  # ENOSPC. When free space falls below min-free mid-build, nix collects dead
  # paths until max-free is reached, instead of failing. Only unreachable paths
  # go; gcroots and profile generations are untouched.
  nix.settings.min-free = 20 * 1024 * 1024 * 1024;
  nix.settings.max-free = 60 * 1024 * 1024 * 1024;

  # Firmware management
  hardware.enableAllFirmware = true;
  hardware.firmware = [ pkgs.linux-firmware ];

  # Garbage Collection
  #
  # 14d, not 7d, for the duration of the systemd-initrd migration.
  #
  # Generations 239-248 are the scripted-initrd fallbacks this box rolls back to
  # if the migration misbehaves (it did, twice, in May 2026 — see
  # HANDOFF-systemd-initrd-migration.md). At 7d the Monday timer would have taken
  # 235-241 on 2026-09-28, three of them fallbacks, and nix-gc does NOT rewrite
  # the boot menu: the entries survive, point at collected store paths, and fail
  # to boot exactly when you need them. 14d keeps a fortnight of rollbacks,
  # which comfortably covers a migration attempt plus a weekend.
  #
  # REVERT TO 7d once the migration is done and proven.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Core system tools
  environment.systemPackages = with pkgs; [
    # base
    vim
    wget
    curl
    lm_sensors
    binutils
    python3
    usbutils
    nvd

    # archives
    unzip
    zip
    p7zip
    unrar

    # terminal essentials
    ripgrep
    fd
    fzf
    tree
    bat
    rsync

    # nix quality-of-life
    nix-output-monitor
    nix-tree
    nh
    comma            # run any pkg once; run `nix-index` once to build its db
    nix-index

    # disk / system
    ncdu
    lsof
    psmisc           # killall, pstree, fuser
    pv

    # network debugging
    dnsutils         # dig, nslookup
    mtr
    nmap
    ethtool

    # media / graphics
    ffmpeg
    yt-dlp
    mpv            # best playback quality; strict about malformed input
    imagemagick
    flameshot

    # Playing and repairing DAMAGED media (added 2026-09-26, after recovering
    # ~16 GB of video off a failing drive). The binding constraint is error
    # RESILIENCE, not codec breadth: the recovered files are mkv/mp4/mov/mp3,
    # all mainstream, so ffmpeg-full was deliberately NOT added — it builds for
    # hours and its extra codecs are ones nothing here uses.
    vlc            # keeps playing through corruption where mpv stops. Its
                   # "plays anything" reputation is really error tolerance:
                   # truncated containers, missing indexes, bad frames.
    mkvtoolnix     # mkvmerge rebuilds a broken Matroska container:
                   #   mkvmerge -o fixed.mkv broken.mkv
    untrunc-anthwlock  # rebuilds a TRUNCATED mp4/mov using an intact file from
                   # the same camera as a template - the only thing that
                   # recovers a video whose index (moov atom) never got written:
                   #   untrunc good.mp4 truncated.mp4
    mediainfo      # says what a file actually IS when the extension lies
    mplayer        # for mencoder -forceidx: the classic AVI index rebuild, and
                   # the fallback when ffmpeg's remux cannot recover the stream
    fixavi         # batch AVI index repair, defined below

    # text / data wrangling  (added 2026-08-26 — agent sessions kept hitting these)
    bc               # the one genuinely missing tool from the reported list
    jq               # was per-user only; agents run outside the HM profile
    yq-go            # yaml/xml -> jq semantics
    xmlstarlet
    jo               # build JSON from the shell
    jc               # convert ordinary command output to JSON
    miller           # mlr: csv/tsv/json streams
    datamash
    dos2unix
    moreutils        # sponge, ts, chronic, ifne, errno, vipe

    # process / debugging
    htop             # btop is per-user only
    ltrace           # strace already present via nixos defaults
    gdb
    tcpdump
    iotop
    socat            # only reachable today via Claude Code's own wrapper — declare it
    entr             # rerun on file change
    hyperfine        # honest benchmarking instead of `time` guesswork
    parallel         # GNU parallel
    tmux

    # build basics
    gnumake
    gcc              # NOTE: no lib headers on NixOS; use a devshell for real builds
    pkg-config

    # desktop glue
    wl-clipboard     # wl-copy / wl-paste — Wayland has no xclip path
  ];
}
