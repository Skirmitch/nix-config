{ pkgs, lib, ... }:
let
  # Python for the "arquitecto Claude" project (~/CADTests/simple_house) and
  # anything else that draws or checks 2D/3D geometry outside FreeCAD:
  #   ezdxf        — write real DXF blueprints (layers, dims, text, blocks) from
  #                  code; `ezdxf draw plano.dxf -o plano.png` renders them via
  #                  matplotlib so an agent can LOOK at what it drew.
  #   shapely      — 2D geometry checks (areas, overlaps, setbacks/distanciamientos).
  #   matplotlib   — ezdxf's render backend + quick charts (U-value tables etc.).
  #   numpy        — the arithmetic behind memorias de cálculo.
  #   ifcopenshell — read the IFC that FreeCAD exports, outside FreeCAD (so a
  #                  reviewer agent can audit walls/openings without the GUI).
  #                  Carries the boost-1.91 patch from freecad.nix's overlay.
  #   reportlab    — programmatic PDF (cuadros de superficies, anexos) when typst
  #                  is overkill.
  #
  # The block below is ALSO the machine's general-purpose python3, which is why
  # it carries packages with nothing to do with CAD:
  #   jsonschema, pyyaml   - hard deps of the midpowerroles research seat
  #   requests, bs4, lxml  - source re-fetching for that same pipeline
  #   scipy, pandas, pyarrow, numba, statsmodels, duckdb
  #                        - the paper-2 research seat (2026-10-30), successor of
  #                          midpowerroles above. Added HERE rather than as a second
  #                          env for exactly the reason this comment exists.
  #                          For the agents' DAY-TO-DAY work only: the pipeline does
  #                          not depend on this environment for reproducibility, it
  #                          ships its own pinned container. So a nixpkgs bump moving
  #                          these versions is not a reproducibility event.
  #
  # THIS MUST REMAIN THE ONLY python3.withPackages ON JL's PATH. Measured
  # 2026-10-20: /etc/profiles/per-user/skirmitch/bin (home-manager) sits at PATH
  # position 9 and /run/current-system/sw/bin at 11, so a SECOND env added
  # "account-wide" in home-manager silently SHADOWS this one and strips ezdxf,
  # shapely and ifcopenshell out of `python3` -- the architect tooling breaks
  # with no error anywhere near the change that caused it. Add packages HERE.
  #
  # hiPrio so this env's bin/python3 wins over the plain python3 that other
  # modules put on the system PATH (it is a strict superset).
  arqPython = lib.hiPrio (pkgs.python3.withPackages (ps: with ps; [
    ezdxf
    shapely
    matplotlib
    numpy
    ifcopenshell
    reportlab
    # --- not CAD: shared general-purpose deps, see the note above ---
    jsonschema
    pyyaml
    requests
    beautifulsoup4
    lxml
    # --- paper-2 research seat, see the note above ---
    scipy
    pandas
    pyarrow
    numba
    statsmodels
    duckdb
  ]));
in
{
  # --- CAD / ARCHITECTURE TOOLING (non-FreeCAD) ---
  environment.systemPackages = with pkgs; [
    arqPython
    librecad       # Qt DXF viewer/editor for JL to open what the architect draws
    typst          # EETT / memorias de cálculo → PDF, one binary, no TeX
    pandoc         # Markdown → .docx when a constructora wants Word
    poppler-utils  # pdftoppm/pdfinfo: rasterize sheets so agents can inspect them
  ];
}
