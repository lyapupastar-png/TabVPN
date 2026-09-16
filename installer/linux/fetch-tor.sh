#!/bin/bash
set -euo pipefail

# fetch-tor.sh — скачивает Tor Expert Bundle для Linux и извлекает
# бинарь tor. См. PLAN-CROSSPLATFORM.md, Задача 3.
#
# В отличие от installer/macos/fetch-tor.sh (там источник — полный
# Tor Browser .dmg, т.к. отдельного macOS expert bundle на момент
# написания macOS-скрипта не проверяли), здесь источник — Tor Expert
# Bundle: обычный tar.gz с бинарём tor и зависимостями, без
# образов/установщиков — поэтому скрипт проще, монтировать ничего не
# нужно.
#
# Версию и точное имя файла не хардкодим — та же причина, что и в
# macOS-версии: Tor Project меняет их с каждым релизом.
#
# ВАЖНО: этот скрипт НЕ был запущен по-настоящему и не проверен
# реальным скачиванием — в сессии, где он написан, не было сетевого
# доступа к dist.torproject.org (упала даже сеть до google.com,
# проблема самой машины/сессии в моменте). Логика (URL, regex,
# поиск бинаря) списана по аналогии с уже работающим
# installer/macos/fetch-tor.sh и проверена только синтаксически
# (bash -n), не запуском. Перед тем как считать Задачу 3 из
# PLAN-CROSSPLATFORM.md закрытой — обязательно прогнать этот скрипт
# по-настоящему и проверить критерий готовности (реальный `tor -f
# torrc`, исходящий IP через SocksPort).
#
# Использование: ./fetch-tor.sh [output_dir] [arch]
#   arch: x86_64 (по умолчанию) или aarch64

BASE_URL="https://dist.torproject.org/torbrowser"
WORKDIR="$(mktemp -d)"
OUT_DIR="${1:-$(pwd)/build}"
ARCH="${2:-x86_64}"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Определяю последнюю стабильную версию Tor Browser..."
# Тот же приём, что в macOS-версии: листинг https://dist.torproject.org/torbrowser/
# содержит папки вида "15.0.22/" (стабильная), "16.0a11/" (альфа —
# буква 'a' отсеивает её сама; grep -v доп. подстраховка на случай
# будущих суффиксов rc/beta).
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

echo "==> Ищу файл expert bundle для linux-${ARCH}..."
BUNDLE_NAME="$(
  curl -fsSL "$VERSION_URL" \
    | grep -oE "href=\"tor-expert-bundle-linux-${ARCH}[^\"]*\.tar\.gz\"" \
    | sed -E 's/href="([^"]+)"/\1/' \
    | head -n1
)"

if [ -z "$BUNDLE_NAME" ]; then
  echo "!! Не нашёл tor-expert-bundle-linux-${ARCH}*.tar.gz в ${VERSION_URL}" >&2
  echo "   (возможно, для архитектуры ${ARCH} на этой версии бандл не публикуется — проверить листинг вручную)" >&2
  exit 1
fi
echo "==> Файл: ${BUNDLE_NAME}"

BUNDLE_PATH="${WORKDIR}/${BUNDLE_NAME}"
echo "==> Скачиваю ${VERSION_URL}${BUNDLE_NAME}..."
curl -fsSL -o "$BUNDLE_PATH" "${VERSION_URL}${BUNDLE_NAME}"

echo "==> Распаковываю..."
EXTRACT_DIR="${WORKDIR}/extracted"
mkdir -p "$EXTRACT_DIR"
tar xzf "$BUNDLE_PATH" -C "$EXTRACT_DIR"

echo "==> Ищу бинарь tor внутри распакованного архива (путь внутри архива не хардкодим — ищем по имени файла, аналогично '*/Tor/tor' в macOS-версии)..."
TOR_BINARY="$(find "$EXTRACT_DIR" -type f -name 'tor' -print -quit)"

if [ -z "$TOR_BINARY" ]; then
  echo "!! Не нашёл файл 'tor' внутри распакованного архива" >&2
  echo "   Содержимое архива для диагностики:" >&2
  find "$EXTRACT_DIR" -maxdepth 3 >&2
  exit 1
fi
echo "==> Найден: ${TOR_BINARY}"

mkdir -p "$OUT_DIR"
# Имя с суффиксом архитектуры — в отличие от macOS (один universal
# файл "tor"), на Linux сборки под x86_64/aarch64 разные бинари,
# должны сосуществовать в одной build/ директории (см. Задачу 5 плана,
# сборка native-host под обе архитектуры тем же принципом).
cp "$TOR_BINARY" "${OUT_DIR}/tor-linux-${ARCH}"
chmod +x "${OUT_DIR}/tor-linux-${ARCH}"

# tor может быть слинкован динамически на .so-зависимости, лежащие
# рядом с ним внутри бандла (аналогично .dylib на macOS) — если так,
# забираем их тоже. Если бандл содержит статический бинарь (рядом нет
# .so) — цикл просто ничего не найдёт, это нормально, не ошибка.
TOR_DIR="$(dirname "$TOR_BINARY")"
echo "==> Проверяю зависимости (.so) рядом с tor в ${TOR_DIR}..."
shopt -s nullglob
SOLIBS=("$TOR_DIR"/*.so "$TOR_DIR"/*.so.*)
shopt -u nullglob
if [ "${#SOLIBS[@]}" -eq 0 ]; then
  echo "   (рядом с tor нет .so — похоже, бинарь статически слинкован, доп. зависимости не нужны)"
else
  for solib in "${SOLIBS[@]}"; do
    cp "$solib" "${OUT_DIR}/"
    echo "   - $(basename "$solib")"
  done
fi

echo "==> Проверка бинаря (тип файла):"
file "${OUT_DIR}/tor-linux-${ARCH}" 2>/dev/null || true

echo "==> Готово: ${OUT_DIR}/tor-linux-${ARCH}"
echo "!! НАПОМИНАНИЕ: скрипт не был реально запущен на момент написания (см. комментарий вверху файла) — нужна реальная проверка перед закрытием Задачи 3." >&2
