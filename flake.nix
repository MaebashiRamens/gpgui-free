{
  description = "gpgui-free — open source GTK4 + libadwaita GUI for globalprotect-openconnect, written in Zig.";

  nixConfig = {
    extra-experimental-features = [
      "nix-command"
      "flakes"
      "pipe-operators"
    ];
    extra-substituters = ["https://nix-community.cachix.org"];
    extra-trusted-public-keys = ["nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
    zls,
    treefmt-nix,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        # Pinned: Zig 0.16 removed `@Type`, which zig-gobject v0.3.1
        # still emits. Bump together with zig-gobject.
        zigPkg = zig-overlay.packages.${system}."0.15.2";
        zlsPkg = zls.packages.${system}.default;
        treefmtEval = treefmt-nix.lib.evalModule (pkgs // {zig = zigPkg;}) ./treefmt.nix;

        nativeBuildInputs = with pkgs; [
          zigPkg
          zlsPkg
          pkg-config
          blueprint-compiler
          gobject-introspection
          git
          jq
          hadolint
        ];

        buildInputs = with pkgs; [
          glib
          gtk4
          libadwaita
          libsecret
          openssl
        ];

        pkgConfigPath = builtins.concatStringsSep ":" (
          map (p: "${p.dev or p}/lib/pkgconfig") buildInputs
        );
      in {
        devShells.default = pkgs.mkShell {
          inherit nativeBuildInputs buildInputs;

          shellHook = ''
            export PATH="${zigPkg}/bin:${zlsPkg}/bin:$PATH"
            hash -r 2>/dev/null || true
            export PKG_CONFIG_PATH="${pkgConfigPath}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            export XDG_DATA_DIRS="${pkgs.gtk4}/share:${pkgs.libadwaita}/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

            # User-shell rc files (notably fish's fish_user_paths) can
            # re-prepend $PATH after this hook runs; warn so a stale
            # personal zig doesn't silently shadow the pinned one.
            _gp_resolved_zig="$(command -v zig 2>/dev/null || echo none)"
            if [ "$_gp_resolved_zig" != "${zigPkg}/bin/zig" ]; then
              printf '\033[33m`zig` resolves to %s, not ${zigPkg}/bin/zig — see docs/BUILDING.md for fixes\033[0m\n' "$_gp_resolved_zig" >&2
            fi
            unset _gp_resolved_zig
          '';
        };

        packages = {
          zig = zigPkg;
          zls = zlsPkg;
        };

        formatter = treefmtEval.config.build.wrapper;
        checks.formatting = treefmtEval.config.build.check self;
      }
    );
}
