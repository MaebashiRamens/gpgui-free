{globalprotect-openconnect}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.gpgui-free;
  rustPkgs = pkgs.extend globalprotect-openconnect.inputs.rust-overlay.overlays.default;
  toolchain = rustPkgs.rust-bin.fromRustupToolchainFile "${globalprotect-openconnect}/rust-toolchain.toml";
  naersk = pkgs.callPackage globalprotect-openconnect.inputs.naersk {
    cargo = toolchain;
    rustc = toolchain;
  };
  backend = naersk.buildPackage {
    pname = "globalprotect-openconnect";
    version = "2.5.4";
    src = pkgs.fetchzip {
      url = "https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v2.5.4/globalprotect-openconnect-2.5.4.tar.gz";
      hash = "sha256-NS3tIZxkT9A4eqmfkcl29bHHJrrgVs/XSQBOz99cP30=";
    };
    singleStep = true;
    cargoBuildOptions = old: old ++ ["-p" "gpclient" "-p" "gpservice" "-p" "gpauth"];
    nativeBuildInputs = with pkgs; [autoconf automake libtool pkg-config autoPatchelfHook wrapGAppsHook4];
    buildInputs = with pkgs; [libxml2 zlib lz4 gnutls p11-kit nettle gmp glib gtk3 libsoup_3 webkitgtk_4_1 openssl libsecret];
    runtimeDependencies = with pkgs; [libayatana-appindicator glib-networking];
    overrideMain = _: {
      postPatch = ''
        substituteInPlace crates/openconnect/src/vpn_utils.rs \
          --replace-fail /usr/libexec/gpclient/vpnc-script $out/libexec/gpclient/vpnc-script \
          --replace-fail /usr/libexec/gpclient/hipreport.sh $out/libexec/gpclient/hipreport.sh
        substituteInPlace crates/common/src/constants.rs \
          --replace-fail /usr/bin/gpclient $out/bin/gpclient \
          --replace-fail /usr/bin/gpservice $out/bin/gpservice \
          --replace-fail /usr/bin/gpgui-helper $out/bin/gpgui-helper \
          --replace-fail /usr/bin/gpgui $out/bin/gpgui \
          --replace-fail /usr/bin/gpauth $out/bin/gpauth \
          --replace-fail /opt/homebrew/ $out/
      '';
    };
    # Install the free GUI directly; never fetch the proprietary GUI.
    postInstall = ''
      ln -s ${cfg.package}/bin/gpgui-free "$out/bin/gpgui"
      cat > "$out/bin/gpgui-helper" <<'EOF'
      #!${pkgs.runtimeShell}
      echo 'gpgui-free: GUI updates are managed by Nix; rebuild the configuration.' >&2
      exit 1
      EOF
      chmod +x "$out/bin/gpgui-helper"
      cp -r packaging/files/usr/share "$out/share"
      cp -r packaging/files/usr/lib "$out/lib"
      cp -r packaging/files/usr/libexec "$out/libexec"
      rm "$out/share/applications/gpgui.desktop"
      substituteInPlace "$out/share/polkit-1/actions/com.yuezk.gpgui.policy" \
        --replace-fail /usr/bin/gpservice "$out/bin/gpservice"
      substituteInPlace "$out/lib/NetworkManager/dispatcher.d/pre-down.d/gpclient.down" \
        --replace-fail /usr/bin/gpclient "$out/bin/gpclient"
      substituteInPlace "$out/libexec/gpclient/hipreport.sh" \
        --replace-fail /usr/bin/gpclient "$out/bin/gpclient"
      substituteInPlace "$out/libexec/gpclient/vpnc-script" \
        --replace-fail /usr/bin/resolvectl ${pkgs.systemd}/bin/resolvectl \
        --replace-fail /usr/bin/busctl ${pkgs.systemd}/bin/busctl
    '';
    preFixup = ''
      gappsWrapperArgs+=(--prefix PATH : "$out/bin:/run/wrappers/bin:${lib.makeBinPath [pkgs.coreutils pkgs.iproute2 pkgs.procps pkgs.util-linux pkgs.nettools pkgs.xdg-utils]}")
    '';
  };
in {
  options.programs.globalprotect-openconnect = {
    enable = lib.mkEnableOption "GlobalProtect-openconnect";
    package = lib.mkOption {
      type = lib.types.package;
      default = backend;
      description = "GlobalProtect-openconnect 2.5.4 with gpgui-free replacing gpgui.";
    };
  };
  options.programs.gpgui-free = {
    enable = lib.mkEnableOption "gpgui-free with GlobalProtect-openconnect";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      description = "gpgui-free package, built with the system's GTK dependencies.";
    };
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      programs.globalprotect-openconnect.enable = true;
      environment.systemPackages = [cfg.package];
    })
    (lib.mkIf config.programs.globalprotect-openconnect.enable {
      environment.systemPackages = [config.programs.globalprotect-openconnect.package];
      security.polkit.enable = true;
    })
  ];
}
