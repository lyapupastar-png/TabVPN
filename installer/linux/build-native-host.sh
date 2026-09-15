#!/bin/bash
set -euo pipefail

# build-native-host.sh — компилирует native-host/index.js в отдельный
# бинарь под Linux x86_64 через Node.js SEA + postject. См.
# PLAN-CROSSPLATFORM.md, Задача 5; образец —
# installer/macos/build-native-host.sh.
#
# ОТЛИЧИЕ ОТ macOS-СКРИПТА: там системный node — universal (fat)
# Mach-O, поэтому обе архитектуры (arm64/x64) вырезаются из ОДНОГО
# локального файла через lipo. У официальных Linux-дистрибутивов
# node с nodejs.org такого "fat"-формата нет — под каждую
# архитектуру свой отдельный tar.gz. НО postject не исполняет
# файл, в который внедряет blob (только редактирует ELF-секции) —
# поэтому хост, на котором ЗАПУСКАЕТСЯ этот скрипт, не обязан быть
# Linux: можно просто СКАЧАТЬ официальный node-vX.Y.Z-linux-x64
# бинарь с nodejs.org и внедрить в него blob прямо здесь, на любой
# ОС. Тот же принцип, что уже сработал для macOS arm64 на Intel-
# хосте, просто без lipo — сразу берём нужный файл по сети.
#
# Версия Node ЗАФИКСИРОВАНА (не "последняя"), а не берётся из
# системного `node`, как на macOS — там она бралась из системного
# node ПОТОМУ ЧТО SEA blob генерируется ЛОКАЛЬНЫМ node, а тут между
# генерацией blob'а и генератором нет системной привязки: явная
# версия используется и для генерации blob'а (через npx/nvm), и для
# скачиваемого target-бинаря, чтобы оба были заведомо одной версии
# (SEA blob — V8 code cache, теоретически чувствителен к точной
# версии V8/Node; проверено на macOS только для ОДНОЙ версии между
# arm64/x64 одной ОС — кросс-ОС совместимость (тот же blob в Linux/
# Windows target) НЕ была проверена в апстриме на момент написания,
# это первая практическая проверка).

NODE_VERSION="20.18.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC="${PROJECT_ROOT}/native-host/index.js"
OUT_DIR="${1:-${PROJECT_ROOT}/build}"
ARCH="${2:-x64}"   # x64 или arm64

mkdir -p "$OUT_DIR"

LOCAL_NODE="$(command -v node || true)"
if [ -z "$LOCAL_NODE" ]; then
  echo "ОШИБКА: node не найден в PATH — нужен для генерации SEA-blob (--experimental-sea-config)." >&2
  exit 1
fi
echo "==> Локальный node для генерации blob'а: ${LOCAL_NODE} ($(node --version))"

TMP_DIR="$(mktemp -d)"
POSTJECT_INSTALL_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR" "$POSTJECT_INSTALL_DIR"
}
trap cleanup EXIT

echo "==> Скачиваю официальный node v${NODE_VERSION} linux-${ARCH}..."
NODE_TARBALL="node-v${NODE_VERSION}-linux-${ARCH}.tar.gz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
curl -fsSL -o "${TMP_DIR}/${NODE_TARBALL}" "$NODE_URL"
tar xzf "${TMP_DIR}/${NODE_TARBALL}" -C "$TMP_DIR"
TARGET_NODE="${TMP_DIR}/node-v${NODE_VERSION}-linux-${ARCH}/bin/node"
if [ ! -f "$TARGET_NODE" ]; then
  echo "ОШИБКА: не нашёл bin/node внутри распакованного ${NODE_TARBALL}" >&2
  exit 1
fi
echo "==> Целевой node: ${TARGET_NODE} ($(file "$TARGET_NODE"))"

echo "==> Генерирую SEA blob из ${SRC}..."
cat > "${TMP_DIR}/sea-config.json" <<EOF
{
  "main": "${SRC}",
  "output": "${TMP_DIR}/sea-prep.blob",
  "disableExperimentalSEAWarning": true
}
EOF
node --experimental-sea-config "${TMP_DIR}/sea-config.json"

cat > "${POSTJECT_INSTALL_DIR}/package.json" <<'EOF'
{
  "name": "tabvpn-native-host-build-tooling",
  "private": true,
  "dependencies": {
    "postject": "1.0.0-alpha.6"
  }
}
EOF
echo "==> Ставлю postject локально (версия 1.0.0-alpha.6)..."
(cd "$POSTJECT_INSTALL_DIR" && npm install --no-audit --no-fund --loglevel=error)
POSTJECT_BIN="${POSTJECT_INSTALL_DIR}/node_modules/.bin/postject"

SENTINEL="NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"

OUT_NAME="tabvpn-native-host-linux-${ARCH}"
OUT_PATH="${OUT_DIR}/${OUT_NAME}"
cp "$TARGET_NODE" "$OUT_PATH"

echo "==> Внедряю SEA blob в ${OUT_NAME}..."
"$POSTJECT_BIN" "$OUT_PATH" NODE_SEA_BLOB "${TMP_DIR}/sea-prep.blob" \
  --sentinel-fuse "$SENTINEL"
chmod +x "$OUT_PATH"

echo "==> Проверка бинаря (тип файла):"
file "$OUT_PATH" 2>/dev/null || true

echo "==> Готово: ${OUT_PATH}"
echo "!! Бинарь собран (валидный ELF), но НЕ ЗАПУСКАЛСЯ на реальном Linux — если этот скрипт" >&2
echo "   выполнялся не на Linux, синтетическую native-messaging команду проверить нельзя (см. Задачу 12)." >&2
