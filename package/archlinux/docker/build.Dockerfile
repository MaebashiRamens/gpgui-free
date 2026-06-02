FROM archlinux:latest AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN pacman -Syu --noconfirm \
    base-devel git pkgconf sudo curl xz \
    glib2 gtk4 libadwaita libsecret \
    && pacman -Scc --noconfirm

ARG ZIG_VERSION=0.15.2
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

RUN useradd -m builder \
    && echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder/build

ARG PKGVER=0.1.0
COPY --chown=builder:builder . /home/builder/repo
RUN cp -r /home/builder/repo "/tmp/gpgui-free-${PKGVER}" \
    && rm -rf "/tmp/gpgui-free-${PKGVER}/zig-out" "/tmp/gpgui-free-${PKGVER}/.zig-cache" "/tmp/gpgui-free-${PKGVER}/.git" \
    && tar czf "/home/builder/build/gpgui-free-${PKGVER}.tar.gz" -C /tmp "gpgui-free-${PKGVER}"

COPY --chown=builder:builder package/archlinux/PKGBUILD ./
COPY --chown=builder:builder package/archlinux/gpgui-free.install ./

# PKGBUILD source= fetches from GitHub; redirect to the local tarball.
RUN sed -i 's|https://github.com/MaebashiRamens/\$pkgname/archive/v\$pkgver.tar.gz|file:///home/builder/build/gpgui-free-0.1.0.tar.gz|' PKGBUILD

RUN makepkg --noconfirm --skipchecksums --nodeps

FROM scratch AS export
COPY --from=builder /home/builder/build/gpgui-free-*.pkg.tar.zst /
