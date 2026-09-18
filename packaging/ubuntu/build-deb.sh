#!/usr/bin/env bash
# Build the VoidFM host .deb for Ubuntu.
#   packaging/ubuntu/build-deb.sh [version]   ->  dist/voidfm-host_<version>_all.deb
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/packaging/ubuntu"
VERSION="${1:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$ROOT/app/pubspec.yaml")}"
VERSION="${VERSION#v}"
PKG=voidfm-host
MAINTAINER="${DEB_MAINTAINER:-CoB12426 <CoB12426@users.noreply.github.com>}"
OUT="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Application code -> /opt/voidfm/host (user config.toml and tests are not shipped)
install -d "$STAGE/opt/voidfm/host"
tar -C "$ROOT/host" \
  --exclude=config.toml --exclude=tests --exclude=__pycache__ --exclude='*.pyc' \
  -cf - . | tar -C "$STAGE/opt/voidfm/host" -xf -
chmod -R u=rwX,go=rX "$STAGE/opt"
chmod 755 "$STAGE" "$STAGE/opt/voidfm/host/bin/voidfm" "$STAGE/opt/voidfm/host/bin/voidfm-tray"

install -d "$STAGE/usr/bin"
ln -s /opt/voidfm/host/bin/voidfm "$STAGE/usr/bin/voidfm"
ln -s /opt/voidfm/host/bin/voidfm-tray "$STAGE/usr/bin/voidfm-tray"
# Panel icon: app launcher + login autostart
install -Dm644 "$ROOT/app/assets/icon.png" "$STAGE/usr/share/pixmaps/voidfm.png"
install -Dm644 "$HERE/voidfm-tray.desktop" "$STAGE/usr/share/applications/voidfm-tray.desktop"
install -Dm644 "$HERE/voidfm-tray.desktop" "$STAGE/etc/xdg/autostart/voidfm-tray.desktop"
install -Dm644 "$HERE/voidfm.service" "$STAGE/usr/lib/systemd/user/voidfm.service"
install -Dm644 "$ROOT/LICENSE" "$STAGE/usr/share/doc/$PKG/copyright"
install -Dm644 "$ROOT/NOTICE" "$STAGE/usr/share/doc/$PKG/NOTICE"

install -d "$STAGE/DEBIAN"
install -m755 "$HERE/postinst" "$HERE/postrm" "$STAGE/DEBIAN/"
echo /etc/xdg/autostart/voidfm-tray.desktop >"$STAGE/DEBIAN/conffiles"
cat >"$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: sound
Priority: optional
Architecture: all
Depends: python3 (>= 3.10), python3-venv, ca-certificates
Recommends: curl, python3-gi, gir1.2-gtk-3.0, gir1.2-ayatanaappindicator3-0.1, libnotify-bin
Installed-Size: $(du -sk "$STAGE" | cut -f1)
Maintainer: $MAINTAINER
Homepage: https://github.com/CoB12426/voidfm
Description: VoidFM host - AI DJ talk server for the VoidFM Android app
 Generates DJ talk between songs with an LLM (Ollama, llama.cpp, OpenAI
 or any OpenAI-compatible API) and Chatterbox TTS, and serves it to the
 VoidFM Android app over HTTP. Run "voidfm start" as a normal user; the
 first run installs the Python dependencies into ~/.local/share/voidfm.
 A panel icon (voidfm-tray) starts at login to start/stop the host and
 open its settings from the desktop.
CONTROL

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "$OUT/${PKG}_${VERSION}_all.deb"
