{
  pkgs,
  lib,
  ...
}: {
  projectRootFile = "flake.nix";

  settings.global.excludes = [
    "flake.lock"
    "LICENSE"
    "*.lock"
    "*.png"
    "*.svg"
    "*.ico"
    ".gitignore"
    "assets/icons/**"
  ];

  programs = {
    # Nix's standard formatters (alejandra/nixfmt) are hard-coded to
    # 2-space indent — out of treefmt's hands.
    alejandra.enable = true;
    prettier = {
      enable = true;
      settings = {
        proseWrap = "preserve";
        printWidth = 100;
        tabWidth = 4;
      };
    };
    shfmt = {
      enable = true;
      indent_size = 4;
    };
    taplo = {
      enable = true;
      settings.formatting.indent_string = "    ";
    };
  };

  # Zig isn't in treefmt-nix's catalogue; wire it manually.
  settings.formatter.zig = {
    command = lib.getExe pkgs.zig;
    options = ["fmt"];
    includes = ["*.zig"];
  };
  settings.formatter.zig-zon = {
    command = lib.getExe pkgs.zig;
    options = ["fmt"];
    includes = ["*.zon"];
  };
}
