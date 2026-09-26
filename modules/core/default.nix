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
in
{
  imports = [ ./locale.nix ];

  # --- NIX SETTINGS ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

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
