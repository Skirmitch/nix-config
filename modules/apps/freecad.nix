{ pkgs, lib, ... }:
let
  # FreeCAD + the neka-nat "FreeCAD MCP" (github.com/neka-nat/freecad-mcp,
  # PyPI `freecad-mcp`, MIT, ~2k stars — the de-facto FreeCAD MCP).
  #
  # It is TWO halves that must never version-skew, so both are cut from ONE
  # pinned source below:
  #   addon/FreeCADMCP  — a FreeCAD workbench ("MCP Addon") that runs an
  #                       XML-RPC server on localhost:9875 INSIDE the FreeCAD
  #                       GUI process. Upstream says "copy it into ~/Mod";
  #                       we bake it in via nixpkgs' freecad.customize
  #                       (--module-path), so nothing is installed by hand and
  #                       the Addon Manager must NOT also install it (two
  #                       copies of a package literally named `rpc_server` on
  #                       sys.path would collide).
  #   src/freecad_mcp   — the stdio MCP server Claude spawns. Upstream runs it
  #                       as `uvx freecad-mcp`; here it is a plain nix
  #                       buildPythonApplication (`freecad-mcp` on PATH), which
  #                       is what ~/.claude.json and Claude Desktop point at.
  #
  # Pinned to main HEAD rather than the v0.1.22 tag on purpose: the 8 commits
  # after the tag (2026-09-05, PRs #122/#128/#129) are exactly the fixes an
  # agent driving FreeCAD needs — RPC requests handled concurrently so
  # get_rpc_status stays answerable, document queries serialized onto the GUI
  # thread, execute_code in its own namespace, parts-library path-traversal
  # fix, h11 CVE-2025-43859 bump. pyproject still says 0.1.22.
  #
  # Runtime model: FreeCAD GUI must be running with the RPC server up. The
  # addon only auto-starts it if (note FreeCAD 1.1's VERSIONED user dir)
  #   ~/.local/share/FreeCAD/v1-1/freecad_mcp_settings.json
  # has "auto_start_rpc": true — seeded once under /persist, out of band; it is
  # the addon's own "Toggle Auto Start" toolbar setting, not nix-managed, and
  # it will need re-seeding under v1-2/ when FreeCAD bumps.
  #
  # Security posture, honestly: the RPC server has NO authentication — the
  # only gate is a source-IP allowlist (rpc_server/ip_filter.py), and
  # `execute_code` is a bare exec() inside FreeCAD's process. With
  # remote_enabled=false it binds 127.0.0.1, which keeps the LAN out but is
  # not a trust boundary on the box: any local process at any UID can reach
  # it (verified 2026-09-05: a nix fixed-output builder, running as nixbld,
  # got through). So while FreeCAD is open with auto-start on, "anything on
  # this machine can run Python as skirmitch inside FreeCAD". To narrow the
  # window, flip auto_start_rpc to false and start it from the toolbar only
  # when Claude is actually driving it.
  version = "0.1.22-unstable-2026-09-05";
  src = pkgs.fetchFromGitHub {
    owner = "neka-nat";
    repo = "freecad-mcp";
    rev = "3da6db5f71a7b74d1b69d295d1ba89233ad622b5";
    hash = "sha256-eQoos3rise2yF4XzNS8+fvnt2B6oHoOlSWV9xfBs7Js=";
  };

  # The MCP server (Claude side). Talks XML-RPC to the addon; any Python is
  # fine here, it does not need to match FreeCAD's interpreter.
  freecad-mcp = pkgs.python3Packages.buildPythonApplication {
    pname = "freecad-mcp";
    inherit version src;
    pyproject = true;

    build-system = [ pkgs.python3Packages.hatchling ];

    # pyproject wants `mcp[cli]`; the cli extra (typer/python-dotenv) only
    # serves the `mcp` CLI, which our stdio server never touches, and nixpkgs'
    # runtime-deps check does not enforce extras — so it is left out.
    dependencies = with pkgs.python3Packages; [
      mcp
      validators
    ];

    # Upstream's own suite: mocks FreeCAD/FreeCADGui/PySide via sys.modules and
    # loads the addon by repo-relative path, so it runs fine in the sandbox and
    # covers BOTH halves (rpc handlers, gui dispatch, serialize, parts library).
    nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
    pythonImportsCheck = [ "freecad_mcp" ];

    meta = {
      description = "MCP server for FreeCAD (neka-nat) — lets Claude drive a running FreeCAD over XML-RPC";
      homepage = "https://github.com/neka-nat/freecad-mcp";
      license = lib.licenses.mit;
      mainProgram = "freecad-mcp";
    };
  };

  # FreeCAD with the addon baked in. `customize` wraps FreeCAD/FreeCADCmd with
  # `--module-path <dir>`; FreeCAD treats each such dir as a module itself
  # (Init.py/InitGui.py at its root — see nixpkgs' freecad/tests/modules.nix),
  # so we point straight at addon/FreeCADMCP. The .desktop file's Exec=FreeCAD
  # resolves through PATH to this wrapper, so the GNOME launcher gets it too.
  #
  # CalculiX: the MCP advertises `run_fem_analysis`, whose addon side ends in
  # femtools/ccxtools.py doing shutil.which("ccx") and raising "CalculiX binary
  # not found" otherwise. nixpkgs wires gmsh (meshing) into FreeCAD but NOT the
  # ccx solver, so without this the tool is offered to the model and fails on
  # every call. Scoped onto FreeCAD's PATH rather than system-wide; each
  # makeWrapper token is a separate list element because freecad-utils quotes
  # them individually.
  freecad-with-mcp = pkgs.freecad.customize {
    modules = [ "${src}/addon/FreeCADMCP" ];
    makeWrapperFlags = [
      "--prefix"
      "PATH"
      ":"
      "${lib.makeBinPath [ pkgs.calculix-ccx ]}"
    ];
  };
in
{
  # --- FREECAD + MCP ---
  environment.systemPackages = [
    freecad-with-mcp
    freecad-mcp
  ];
}
