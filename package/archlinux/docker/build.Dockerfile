FROM archlinux:latest AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN pacman -Syu --noconfirm \
    base-devel git pkgconf sudo curl xz \
    glib2 gtk4 libadwaita libsecret \
    && pacman -Scc --noconfirm

ARG ZIG_VERSION=0.15.2
# From https://ziglang.org/download/index.json — update together with ZIG_VERSION.
ARG ZIG_SHA256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && rm /tmp/zig.tar.xz \
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

# Override pkgver, redirect source= to the local tarball, and pin its
# hash so makepkg's checksum path stays exercised.
RUN sed -i "s/^pkgver=.*/pkgver=${PKGVER}/" PKGBUILD \
    && sed -i "s|https://github.com/MaebashiRamens/\$pkgname/archive/v\$pkgver.tar.gz|file:///home/builder/build/gpgui-free-${PKGVER}.tar.gz|" PKGBUILD \
    && sed -i "s/^sha256sums=.*/sha256sums=('$(sha256sum "/home/builder/build/gpgui-free-${PKGVER}.tar.gz" | cut -d' ' -f1)')/" PKGBUILD

RUN makepkg --noconfirm --nodeps

FROM scratch AS export
COPY --from=builder /home/builder/build/gpgui-free-*.pkg.tar.zst /
