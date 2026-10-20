{ pkgs, ... }:
{
  # --- TeX Live, account-wide ----------------------------------------------
  #
  # Added 2026-10-20 for the midpowerroles research seat
  # (~/agents/research/midpowerroles), whose final deliverable is a LaTeX-built
  # PDF of an economics paper plus a DOCX. Before this the machine had NO TeX at
  # all -- pdflatex, xelatex, lualatex, tectonic, latexmk, bibtex and biber were
  # every one of them absent.
  #
  # USE THE TOP-LEVEL SCHEMES, NOT `texlive.combined.*`. The first version of
  # this file said `texlive.combined.scheme-full` and nixpkgs answered with
  # "texlive.combined schemes are deprecated and will be removed from Nixpkgs
  # 27.05". Since this flake's nixpkgs gets bumped routinely (`update`/`dif`),
  # that is a build break with a date on it, not a style nit.
  #
  # SIZE, measured with `nix build --dry-run` on 2026-10-20, not guessed:
  #
  #     texliveFull     5242 paths   2.1 GiB download   4.6 GiB unpacked
  #     texliveMedium   1667 paths   600 MiB download   1.1 GiB unpacked
  #     texliveSmall     441 paths   107 MiB download   275 MiB unpacked
  #     texliveBasic     190 paths    59 MiB download   151 MiB unpacked
  #
  # texliveFull is deliberate. The consumer is an UNATTENDED pipeline that
  # typesets at the very end of a long run, so the failure mode of a smaller
  # scheme is a missing .sty discovered hours in, with nobody present to add it
  # and re-run. 3.5 GiB is a cheap premium against that. Drop to texliveMedium
  # if the disk ever gets tight, and expect round-trips for the
  # newtx / siunitx / threeparttable class of packages when you do.
  #
  # Placed in home-manager (account-wide) rather than environment.systemPackages
  # because that is what JL asked for, and because nothing outside this user
  # needs TeX. Unlike python3 (see modules/apps/cad-tools.nix) there is no
  # shadowing hazard here: TeX ships no binary that another profile also owns.
  home.packages = [ pkgs.texliveFull ];
}
