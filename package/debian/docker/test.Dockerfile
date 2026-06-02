FROM debian:bookworm
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-4-1 libadwaita-1-0 libsecret-1-0 \
    && rm -rf /var/lib/apt/lists/*

COPY out/*.deb /tmp/

RUN dpkg --force-depends -i /tmp/gpgui-free_*_amd64.deb

RUN test -L /usr/bin/gpgui \
    && [ "$(readlink /usr/bin/gpgui)" = "gpgui-free" ] \
    && head -n 3 /usr/bin/gpgui-helper | grep -q 'gpgui-free: gpgui-helper disabled' \
    && /usr/bin/gpgui-free --version \
    && /usr/bin/gpgui --version

CMD ["gpgui-free", "--version"]
