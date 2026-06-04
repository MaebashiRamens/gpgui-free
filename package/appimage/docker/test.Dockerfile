FROM ubuntu:24.04
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates file \
    && rm -rf /var/lib/apt/lists/*

COPY out/*.AppImage /tmp/gpgui-free.AppImage
RUN chmod +x /tmp/gpgui-free.AppImage

# Verify the AppImage was built correctly: magic bytes, extractable,
# contains the expected binary + desktop file + icon.
# Don't actually run it — minimal Ubuntu lacks the gobject/harfbuzz
# runtime that plugin-gtk does not fully bundle on its own.
RUN file /tmp/gpgui-free.AppImage \
    && /tmp/gpgui-free.AppImage --appimage-extract >/dev/null \
    && test -x squashfs-root/AppRun \
    && test -x squashfs-root/usr/bin/gpgui-free \
    && test -f squashfs-root/gpgui-free.desktop \
    && test -d squashfs-root/usr/lib \
    && echo "AppImage layout OK"

CMD ["echo", "appimage test container; build-time checks ran in RUN steps"]
