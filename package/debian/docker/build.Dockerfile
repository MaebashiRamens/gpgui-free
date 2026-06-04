FROM debian:bookworm AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential debhelper devscripts \
    pkg-config curl ca-certificates xz-utils \
    libgtk-4-dev libadwaita-1-dev libsecret-1-dev \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.15.2
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

ARG PKGVER=0.1.0
WORKDIR /build/gpgui-free-${PKGVER}
COPY . ./

RUN cp -r package/debian ./debian \
    && chmod +x debian/postinst debian/prerm debian/postrm debian/rules

# Stamp the changelog with the requested version so dpkg-genchanges agrees.
RUN sed -i "1s/(.*)/(${PKGVER}-1)/" debian/changelog

# -d: skip dep check (globalprotect-openconnect not in Debian repos).
RUN dpkg-buildpackage -us -uc -b -d

FROM scratch AS export
COPY --from=builder /build/gpgui-free_*_amd64.deb /
