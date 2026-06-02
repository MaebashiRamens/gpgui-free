FROM fedora:latest AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN dnf install -y --setopt=install_weak_deps=False \
    rpm-build rpmdevtools \
    pkgconf-pkg-config gcc make tar xz curl ca-certificates \
    gtk4-devel libadwaita-devel libsecret-devel \
    systemd-rpm-macros \
    && dnf clean all

ARG ZIG_VERSION=0.15.2
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

RUN rpmdev-setuptree

ARG PKGVER=0.1.0
COPY . /tmp/repo
RUN cp -r /tmp/repo "/tmp/gpgui-free-${PKGVER}" \
    && rm -rf "/tmp/gpgui-free-${PKGVER}/zig-out" "/tmp/gpgui-free-${PKGVER}/.zig-cache" "/tmp/gpgui-free-${PKGVER}/.git" \
    && tar czf "/root/rpmbuild/SOURCES/gpgui-free-${PKGVER}.tar.gz" -C /tmp "gpgui-free-${PKGVER}" \
    && cp /tmp/repo/package/rhel/gpgui-free.spec /root/rpmbuild/SPECS/ \
    && cp /tmp/repo/package/rhel/gpgui-free-restore.path /root/rpmbuild/SOURCES/ \
    && cp /tmp/repo/package/rhel/gpgui-free-restore.service /root/rpmbuild/SOURCES/

RUN rpmbuild -ba --nodeps /root/rpmbuild/SPECS/gpgui-free.spec

FROM scratch AS export
COPY --from=builder /root/rpmbuild/RPMS/x86_64/gpgui-free-*.rpm /
