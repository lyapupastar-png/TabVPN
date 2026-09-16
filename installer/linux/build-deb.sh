#!/bin/bash
set -euo pipefail

# build-deb.sh — собирает TabVPN.deb из бинарей (build/) + шаблонов
# torrc/systemd-unit и postinst/postrm-скриптов из этой папки. См.
# PLAN-CROSSPLATFORM.md, Задача 10 (вариант A — .deb с sudo, решение
# принято владельцем проекта 2026-09-13, см. NEXT_TASK.md). По образцу
# installer/macos/build-pkg.sh, адаптировано под dpkg вместо
# pkgbuild/productbuild.
#
# dpkg-deb НЕ требует Linux для СБОРКИ пакета — тот же принцип, что уже
# сработал для кросс-ОС сборки native-host бинарей (см.
# installer/linux/build-native-host.sh): .deb — это просто ar-архив
# (control.tar.* + data.tar.*), dpkg-deb доступен на macOS через
# 'brew install dpkg'. УСТАНОВКА пакета (dpkg -i) естественно требует
# реальный Debian/Ubuntu — собранный .deb НЕ был протестирован реальной
# установкой на момент написания (см. Задачу 12 плана).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"

VERSION="${TABVPN_VERSION:-0.1.1}"
ARCH="amd64"
PKG_NAME="tabvpn"

TOR_BIN="${BUILD_DIR}/tor-linux-x86_64"
HOST_BIN="${BUILD_DIR}/tabvpn-native-host-linux-x64"

for f in "$TOR_BIN" "$HOST_BIN"; do
  if [ ! -f "$f" ]; then
    echo "!! Не найден $f — сначала запусти installer/linux/fetch-tor.sh и installer/linux/build-native-host.sh" >&2
    exit 1
  fi
done

PKGROOT="$(mktemp -d)"
cleanup() { rm -rf "$PKGROOT"; }
trap cleanup EXIT
# mktemp -d создаёт директорию с правами 0700 — без явного chmod это
# попадает в .deb как права корня пакета ('./' в dpkg-deb --contents),
# что не обязательно ни на что влияет при установке (dpkg не трогает
# права реального "/"), но лишняя странность в выводе ни к чему.
chmod 0755 "$PKGROOT"

echo "==> Собираю payload (/opt/tabvpn)..."
mkdir -p "${PKGROOT}/opt/tabvpn/bin" "${PKGROOT}/opt/tabvpn/share" "${PKGROOT}/DEBIAN"

cp "$TOR_BIN" "${PKGROOT}/opt/tabvpn/bin/tor"
cp "$HOST_BIN" "${PKGROOT}/opt/tabvpn/bin/tabvpn-native-host"
# Явный chmod 0755, а не просто "+x" поверх унаследованных от cp прав:
# источники (build/) могли достаться из tar/postject с более узкими
# правами (напр. только владельцу) — бинари будет запускать ОБЫЧНЫЙ
# пользователь через systemd --user, не root, поэтому нужны явные
# read+execute для "other", а не только сохранение исходных битов.
chmod 0755 "${PKGROOT}/opt/tabvpn/bin/tor" "${PKGROOT}/opt/tabvpn/bin/tabvpn-native-host"

# tor может быть слинкован динамически на .so-зависимости, лежащие
# рядом с ним в build/ (fetch-tor.sh кладёт их туда, если они есть) —
# несём их тем же payload'ом, аналогично .dylib на macOS. Tor Expert
# Bundle собирает tor с RPATH=$ORIGIN именно для этого сценария
# (портативный бандл, зависимости рядом с бинарём).
shopt -s nullglob
SOLIBS=("${BUILD_DIR}"/*.so "${BUILD_DIR}"/*.so.*)
shopt -u nullglob
if [ "${#SOLIBS[@]}" -eq 0 ]; then
  echo "   (в ${BUILD_DIR} нет .so — похоже, tor статически слинкован)"
else
  for solib in "${SOLIBS[@]}"; do
    cp "$solib" "${PKGROOT}/opt/tabvpn/bin/"
    # 0644, не 0755 — библиотекам не нужен execute-бит, но ОБЯЗАТЕЛЕН
    # read для "other": ld.so открывает их через open()/mmap() от
    # имени вызывающего процесса (обычного пользователя), в отличие
    # от execve() самого бинаря, которому execute-бита формально
    # достаточно. Без этого fix'а собранный ранее .deb ставил их с
    # правами владельца-only (700) — под обычным пользователем Tor
    # не смог бы их загрузить.
    chmod 0644 "${PKGROOT}/opt/tabvpn/bin/$(basename "$solib")"
    echo "   - $(basename "$solib")"
  done
fi

cp "${SCRIPT_DIR}/torrc" "${PKGROOT}/opt/tabvpn/share/torrc"
cp "${SCRIPT_DIR}/tabvpn-tor.service" "${PKGROOT}/opt/tabvpn/share/tabvpn-tor.service"

echo "==> Пишу DEBIAN/control..."
INSTALLED_SIZE="$(du -sk "${PKGROOT}/opt" | cut -f1)"
cat > "${PKGROOT}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${INSTALLED_SIZE}
Recommends: systemd
Maintainer: TabVPN <noreply@localhost>
Description: Локальный Tor-клиент и native-messaging host для расширения TabVPN
 Firefox-расширение TabVPN открывает выбранные ссылки в отдельном
 контейнере через локальный Tor-клиент, чтобы обходить геоблокировку
 по IP. Этот пакет ставит сам Tor-клиент и native-messaging host,
 через который расширение им управляет (исходники — installer/linux
 в репозитории проекта).
EOF

cp "${SCRIPT_DIR}/postinst" "${PKGROOT}/DEBIAN/postinst"
cp "${SCRIPT_DIR}/postrm" "${PKGROOT}/DEBIAN/postrm"
chmod 0755 "${PKGROOT}/DEBIAN/postinst" "${PKGROOT}/DEBIAN/postrm"

mkdir -p "$BUILD_DIR"
OUT_DEB="${BUILD_DIR}/tabvpn_${VERSION}_${ARCH}.deb"

echo "==> dpkg-deb --build..."
dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT_DEB"

echo "==> Проверка (dpkg-deb --info / --contents)..."
dpkg-deb --info "$OUT_DEB"
echo "---"
dpkg-deb --contents "$OUT_DEB"

echo "==> Готово: ${OUT_DEB}"
echo "!! Собран (валидный .deb, dpkg-deb это подтвердил), но НЕ УСТАНАВЛИВАЛСЯ на реальном" >&2
echo "   Debian/Ubuntu — критерий готовности Задачи 10 (реальная установка, Tor поднят," >&2
echo "   расширение видит native host) остаётся открытым до Задачи 12 (см. NEXT_TASK.md)." >&2
