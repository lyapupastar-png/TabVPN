#!/bin/bash
set -euo pipefail

# build-pkg.sh — собирает TabVPN.pkg из бинарей, собранных
# fetch-tor.sh и build-native-host.sh (лежат в build/), плюс шаблонов
# torrc/plist и postinstall-скрипта из этой же папки.
#
# Без подписи Apple Developer ID (осознанное решение, см. NEXT_TASK.md)
# — .pkg будет блокироваться Gatekeeper при первом запуске, пользователь
# один раз нажимает "Открыть всё равно".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"

IDENTIFIER="com.tabvpn.installer"
VERSION="${TABVPN_VERSION:-0.1.0}"
INSTALL_LOCATION="/Library/Application Support/TabVPN-staging"

for f in "${BUILD_DIR}/tor" "${BUILD_DIR}/tabvpn-native-host-arm64" "${BUILD_DIR}/tabvpn-native-host-x64"; do
  if [ ! -f "$f" ]; then
    echo "!! Не найден $f — сначала запусти fetch-tor.sh и build-native-host.sh" >&2
    exit 1
  fi
done

echo "==> Собираю payload-корень (install-location: ${INSTALL_LOCATION})..."
PKGROOT="$(mktemp -d)"
cp "${BUILD_DIR}/tor" "$PKGROOT/"
cp "${BUILD_DIR}/tabvpn-native-host-arm64" "$PKGROOT/"
cp "${BUILD_DIR}/tabvpn-native-host-x64" "$PKGROOT/"
cp "${SCRIPT_DIR}/torrc" "$PKGROOT/"
cp "${SCRIPT_DIR}/com.tabvpn.tor.plist" "$PKGROOT/"
chmod +x "$PKGROOT"/tor "$PKGROOT"/tabvpn-native-host-*

# tor слинкован через @executable_path на свои .dylib (fetch-tor.sh
# кладёт их рядом с tor в build/) — без них tor не запустится в
# финальной директории. Несём их тем же payload'ом.
shopt -s nullglob
DYLIBS=("${BUILD_DIR}"/*.dylib)
shopt -u nullglob
if [ "${#DYLIBS[@]}" -eq 0 ]; then
  echo "!! В ${BUILD_DIR} нет .dylib — если tor линкован динамически, он не запустится после установки" >&2
fi
for dylib in "${DYLIBS[@]}"; do
  cp "$dylib" "$PKGROOT/"
done

echo "==> Готовлю папку со скриптами..."
SCRIPTS_DIR="$(mktemp -d)"
cp "${SCRIPT_DIR}/postinstall" "$SCRIPTS_DIR/postinstall"
chmod +x "${SCRIPTS_DIR}/postinstall"

cleanup() {
  rm -rf "$PKGROOT" "$SCRIPTS_DIR"
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR"
COMPONENT_PKG="${BUILD_DIR}/TabVPN-component.pkg"
FINAL_PKG="${BUILD_DIR}/TabVPN.pkg"

echo "==> pkgbuild..."
pkgbuild \
  --root "$PKGROOT" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "$INSTALL_LOCATION" \
  --scripts "$SCRIPTS_DIR" \
  --ownership recommended \
  "$COMPONENT_PKG"

echo "==> productbuild..."
productbuild \
  --package "$COMPONENT_PKG" \
  --identifier "${IDENTIFIER}.dist" \
  --version "$VERSION" \
  "$FINAL_PKG"

echo "==> Готово: ${FINAL_PKG}"
