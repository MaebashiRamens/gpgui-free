{
  lib,
  stdenv,
  zig_0_15,
  pkg-config,
  wrapGAppsHook4,
  fetchurl,
  glib,
  gtk4,
  libadwaita,
  libsecret,
  openssl,
  git,
}: let
  bindings = fetchurl {
    url = "https://github.com/ianprime0509/zig-gobject/releases/download/v0.3.1/bindings-gnome49.tar.zst";
    hash = "sha256-xrAF938IIVovlj7yjZ+3Uz5CbuTmw6Rmgm5ctzEDsGY=";
  };
in
  stdenv.mkDerivation {
    pname = "gpgui-free";
    version = "0.1.0-dev";
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [../build.zig ../build.zig.zon ../src ../assets ../LICENSE ../README.md];
    };
    nativeBuildInputs = [zig_0_15 pkg-config wrapGAppsHook4 git];
    buildInputs = [glib gtk4 libadwaita libsecret openssl];
    dontConfigure = true;
    postPatch = ''
      substituteInPlace src/auth/gpauth.zig --replace-fail /usr/bin/gpauth /run/current-system/sw/bin/gpauth
      substituteInPlace assets/applications/gpgui-free.desktop --replace-fail 'Exec=gpgui-free' 'Exec=gpclient launch-gui %u'
      echo 'MimeType=x-scheme-handler/globalprotectcallback;' >> assets/applications/gpgui-free.desktop
    '';
    preBuild = ''
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
      export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
      zig fetch ${bindings}
    '';
    buildPhase = ''
      runHook preBuild
      zig build -Doptimize=ReleaseSafe --prefix "$out" -j$NIX_BUILD_CORES
      runHook postBuild
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      zig build test -j$NIX_BUILD_CORES
      runHook postCheck
    '';
    dontInstall = true;
    meta = {
      description = "Open-source GTK4 GUI for GlobalProtect-openconnect";
      homepage = "https://github.com/MaebashiRamens/gpgui-free";
      license = lib.licenses.gpl3Plus;
      platforms = lib.platforms.linux;
      mainProgram = "gpgui-free";
    };
  }
