FROM fedora:latest
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN dnf install -y --setopt=install_weak_deps=False \
    gtk4 libadwaita libsecret \
    && dnf clean all

COPY out/*.rpm /tmp/

RUN rpm -ivh --nodeps /tmp/gpgui-free-*.rpm

RUN test -L /usr/bin/gpgui \
    && [ "$(readlink /usr/bin/gpgui)" = "gpgui-free" ] \
    && head -n 3 /usr/bin/gpgui-helper | grep -q 'gpgui-free: gpgui-helper disabled' \
    && /usr/bin/gpgui-free --version \
    && /usr/bin/gpgui --version

CMD ["gpgui-free", "--version"]
