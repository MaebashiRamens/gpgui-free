# Built on Ubuntu 24.04 — glib 2.80 is required because src/app.zig
# uses g_idle_add_once (introduced in glib 2.74). The bundled glibc
# 2.39 is broadly compatible with modern distros (Ubuntu 24.04+,
# Debian 13+, Fedora 39+, Arch, recent RHEL).
FROM ubuntu:24.04 AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config curl ca-certificates xz-utils file fuse \
    libgtk-4-dev libadwaita-1-dev libsecret-1-dev libglib2.0-dev \
    libfuse2 desktop-file-utils \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.15.2
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

ARG LINUXDEPLOY_TAG=1-alpha-20251107-1
RUN curl -fsSL "https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_TAG}/linuxdeploy-x86_64.AppImage" \
        -o /usr/local/bin/linuxdeploy \
    && curl -fsSL https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh \
        -o /usr/local/bin/linuxdeploy-plugin-gtk \
    && chmod +x /usr/local/bin/linuxdeploy /usr/local/bin/linuxdeploy-plugin-gtk

# linuxdeploy AppImages need FUSE; we use --appimage-extract-and-run
# to avoid requiring FUSE inside Docker.
ENV APPIMAGE_EXTRACT_AND_RUN=1

ARG PKGVER=0.1.0
WORKDIR /build/repo
COPY . ./

RUN zig build --release=safe

WORKDIR /build
RUN mkdir -p AppDir/usr \
    && cp -r repo/zig-out/bin AppDir/usr/bin \
    && cp -r repo/zig-out/share AppDir/usr/share

RUN OUTPUT="gpgui-free-${PKGVER}-x86_64.AppImage" linuxdeploy \
        --appdir AppDir \
        --plugin gtk \
        --desktop-file AppDir/usr/share/applications/gpgui-free.desktop \
        --icon-file AppDir/usr/share/icons/hicolor/256x256/apps/gpgui-free.png \
        --output appimage

FROM scratch AS export
COPY --from=builder /build/gpgui-free-*-x86_64.AppImage /
