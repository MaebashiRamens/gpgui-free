FROM archlinux:latest
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN pacman -Syu --noconfirm \
    gtk4 libadwaita libsecret glib2 \
    && pacman -Scc --noconfirm

COPY out/*.pkg.tar.zst /tmp/

RUN pacman -U --noconfirm --nodeps /tmp/gpgui-free-*.pkg.tar.zst

RUN test -L /usr/bin/gpgui \
    && [ "$(readlink /usr/bin/gpgui)" = "gpgui-free" ] \
    && head -n 3 /usr/bin/gpgui-helper | grep -q 'gpgui-free: gpgui-helper disabled' \
    && /usr/bin/gpgui-free --version \
    && /usr/bin/gpgui --version

CMD ["gpgui-free", "--version"]
