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
    alejandra.enable = true;
    prettier = {
      enable = true;
      settings = {
        proseWrap = "preserve";
        printWidth = 100;
      };
    };
    shfmt = {
      enable = true;
      indent_size = 2;
    };
    taplo.enable = true;
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
