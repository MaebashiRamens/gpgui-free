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
# From https://ziglang.org/download/index.json — update together with ZIG_VERSION.
ARG ZIG_SHA256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && rm /tmp/zig.tar.xz \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

ARG LINUXDEPLOY_TAG=1-alpha-20251107-1
ARG LINUXDEPLOY_SHA256=c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
# The gtk plugin has no releases; pin a commit instead of `master`.
ARG PLUGIN_GTK_COMMIT=7a3fbc31a9e5075073ff8790f26effbac5f84453
ARG PLUGIN_GTK_SHA256=b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171
RUN curl -fsSL "https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_TAG}/linuxdeploy-x86_64.AppImage" \
        -o /usr/local/bin/linuxdeploy \
    && echo "${LINUXDEPLOY_SHA256}  /usr/local/bin/linuxdeploy" | sha256sum -c - \
    && curl -fsSL "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/${PLUGIN_GTK_COMMIT}/linuxdeploy-plugin-gtk.sh" \
        -o /usr/local/bin/linuxdeploy-plugin-gtk \
    && echo "${PLUGIN_GTK_SHA256}  /usr/local/bin/linuxdeploy-plugin-gtk" | sha256sum -c - \
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
