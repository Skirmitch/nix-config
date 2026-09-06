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
  #   reportlab    — programmatic PDF (cuadros de superficies, anexos) when typst
  #                  is overkill.
  # hiPrio so this env's bin/python3 wins over the plain python3 that other
  # modules put on the system PATH (it is a strict superset).
  arqPython = lib.hiPrio (pkgs.python3.withPackages (ps: with ps; [
    ezdxf
    shapely
    matplotlib
    numpy
    ifcopenshell
    reportlab
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
