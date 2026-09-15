#!/bin/bash
set -euo pipefail

# fetch-tor.sh — скачивает последнюю стабильную версию Tor Browser для
# macOS и извлекает из неё бинарь tor. Версию и точное имя .dmg НЕ
# хардкодим — Tor Project меняет их с каждым релизом, поэтому парсим
# листинг директории в момент сборки.
#
# Использование: ./fetch-tor.sh [output_dir]   (по умолчанию ./build)

BASE_URL="https://dist.torproject.org/torbrowser"
WORKDIR="$(mktemp -d)"
OUT_DIR="${1:-$(pwd)/build}"

cleanup() {
  hdiutil detach "${WORKDIR}/mnt" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Определяю последнюю стабильную версию Tor Browser..."

# Листинг https://dist.torproject.org/torbrowser/ содержит папки вида
# "15.0.22/" (стабильная), "16.0a11/" (альфа — буква 'a' не проходит
# чисто числовой шаблон ниже, альфы отсеиваются сами; grep -v — доп.
# подстраховка на случай будущих суффиксов типа rc/beta).
LATEST_VERSION="$(
  curl -fsSL "${BASE_URL}/" \
    | grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' \
    | sed -E 's/href="([^"]+)\/"/\1/' \
    | grep -vE '(a|b|rc)[0-9]*$' \
    | sort -V \
    | tail -n1
)"

if [ -z "$LATEST_VERSION" ]; then
  echo "!! Не удалось определить версию Tor Browser из листинга ${BASE_URL}/" >&2
  exit 1
fi
echo "==> Последняя стабильная версия: ${LATEST_VERSION}"

VERSION_URL="${BASE_URL}/${LATEST_VERSION}/"

echo "==> Ищу .dmg файл для macOS..."
# Актуальный Tor Browser для macOS — universal-сборка (Intel + Apple
# Silicon в одном .dmg), поэтому имя файла без суффикса архитектуры:
# tor-browser-macos-<версия>.dmg. Имя всё равно не хардкодим — берём
# из листинга, вдруг формат снова поменяется.
DMG_NAME="$(
  curl -fsSL "$VERSION_URL" \
    | grep -oE 'href="tor-browser-macos[^"]*\.dmg"' \
    | sed -E 's/href="([^"]+)"/\1/' \
    | head -n1
)"

if [ -z "$DMG_NAME" ]; then
  echo "!! Не нашёл .dmg для macOS в ${VERSION_URL}" >&2
  exit 1
fi
echo "==> Файл: ${DMG_NAME}"

DMG_PATH="${WORKDIR}/${DMG_NAME}"
echo "==> Скачиваю ${VERSION_URL}${DMG_NAME}..."
curl -fsSL -o "$DMG_PATH" "${VERSION_URL}${DMG_NAME}"

echo "==> Монтирую .dmg..."
MOUNT_POINT="${WORKDIR}/mnt"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

echo "==> Ищу бинарь tor внутри бандла (путь между версиями менялся, поэтому ищем по '*/Tor/tor', а не хардкодим полный путь)..."
# В 15.0.22 путь — Contents/MacOS/Tor/tor (раньше был
# Contents/Resources/TorBrowser/Tor/tor). Ищем по суффиксу '*/Tor/tor',
# чтобы не зависеть от того, под каким родителем лежит папка Tor —
# это переживёт очередной переезд каталога.
TOR_BINARY="$(find "$MOUNT_POINT" -path '*/Tor/tor' -type f -print -quit)"

if [ -z "$TOR_BINARY" ]; then
  echo "!! Не нашёл бинарь tor внутри смонтированного образа" >&2
  exit 1
fi
echo "==> Найден: ${TOR_BINARY}"

mkdir -p "$OUT_DIR"
cp "$TOR_BINARY" "${OUT_DIR}/tor"
chmod +x "${OUT_DIR}/tor"

# tor слинкован с зависимостями через @executable_path (см. otool -L),
# то есть в рантайме ищет их РЯДОМ с собой. Забираем все .dylib из той
# же папки бандла, что и сам бинарь, и кладём рядом с ним в OUT_DIR —
# иначе tor не запустится (dyld: Library not loaded).
TOR_DIR="$(dirname "$TOR_BINARY")"
echo "==> Копирую зависимости tor (dylib) из ${TOR_DIR}..."
shopt -s nullglob
DYLIBS=("$TOR_DIR"/*.dylib)
shopt -u nullglob
if [ "${#DYLIBS[@]}" -eq 0 ]; then
  echo "!! Рядом с tor не нашлось ни одной .dylib — если tor линкован динамически (проверь otool -L), он не запустится без них" >&2
fi
for dylib in "${DYLIBS[@]}"; do
  cp "$dylib" "${OUT_DIR}/"
  echo "   - $(basename "$dylib")"
done

echo "==> Отмонтирую образ..."
hdiutil detach "$MOUNT_POINT" -quiet

echo "==> Проверка архитектуры (должен быть universal: x86_64 + arm64):"
lipo -info "${OUT_DIR}/tor" || true

echo "==> Готово: ${OUT_DIR}/tor"
