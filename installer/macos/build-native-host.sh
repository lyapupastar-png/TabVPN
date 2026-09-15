#!/bin/bash
set -euo pipefail

# build-native-host.sh — компилирует native-host/index.js в отдельные
# бинари под Apple Silicon и Intel, чтобы у пользователя не требовался
# установленный Node.js. Зависимостей у index.js нет (только встроенные
# модули net/fs/path), поэтому сборка простая.
#
# Используем Node.js SEA (Single Executable Applications, встроено в
# сам Node.js начиная с v20) вместо стороннего @yao-pkg/pkg — см.
# NEXT_TASK.md за историей отказа от pkg (into-stream ESM/CJS баг
# апстрима + pkg-fetch не может собрать Node из исходников под arm64
# на Intel-хосте: падает на OpenSSL arm_arch.h при кросс-компиляции).
#
# КЛЮЧЕВОЕ ОТКРЫТИЕ (меняет план из NEXT_TASK.md, проверено запуском):
# системный `node` на macOS (Homebrew/nodejs.org) — universal (fat)
# Mach-O с ОБЕИМИ архитектурами (x86_64 + arm64) в одном файле. SEA не
# компилирует бинарь заново — просто внедряет blob байткода в КОПИЮ
# существующего node-бинаря через postject. postject не исполняет
# файл, а только редактирует Mach-O секции, поэтому архитектура хоста
# не имеет значения — можно вырезать (`lipo -thin`) любой срез из
# universal node и внедрить blob в него. Практический вывод: ОБА
# бинаря (arm64 и x64) собираются на этом Intel-хосте прямо сейчас,
# отдельная Apple Silicon машина или матрица раннеров в CI не нужны.
#
# Внедрять blob в universal-бинарь НАПРЯМУЮ нельзя: postject ищет
# sentinel-строку по всему файлу и падает с "Multiple occurences of
# sentinel ... found in the binary" — строка встречается по разу в
# каждом из двух срезов. Отсюда обязательный шаг `lipo -thin` перед
# инъекцией.
#
# Ad-hoc подпись (codesign --sign -) обязательна после инъекции — на
# macOS неподписанный исполняемый файл убивается ядром при запуске.
# Подписывать нужно ПОСЛЕ postject, не до (инъекция меняет содержимое
# файла и разрушает любую более раннюю подпись).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC="${PROJECT_ROOT}/native-host/index.js"
OUT_DIR="${1:-${PROJECT_ROOT}/build}"
SYSTEM_NODE="$(command -v node || true)"

mkdir -p "$OUT_DIR"

if [ -z "$SYSTEM_NODE" ]; then
  echo "ОШИБКА: node не найден в PATH — нужен системный Node.js (v20+)" >&2
  echo "для генерации SEA-blob." >&2
  exit 1
fi

echo "==> Системный node: ${SYSTEM_NODE} ($(node --version))"
LIPO_INFO="$(lipo -info "$SYSTEM_NODE" 2>&1)"
echo "==> ${LIPO_INFO}"

TMP_DIR="$(mktemp -d)"
POSTJECT_INSTALL_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR" "$POSTJECT_INSTALL_DIR"
}
trap cleanup EXIT

# --- 1. Генерируем SEA preparation blob (общий для обеих архитектур —
#    это байткод + метаданные, архитектурно-независимые) ---
cat > "${TMP_DIR}/sea-config.json" <<EOF
{
  "main": "${SRC}",
  "output": "${TMP_DIR}/sea-prep.blob",
  "disableExperimentalSEAWarning": true
}
EOF

echo "==> Генерирую SEA blob из ${SRC}..."
node --experimental-sea-config "${TMP_DIR}/sea-config.json"

# --- 2. Ставим postject локально с зафиксированной версией
#    (изолированная temp-папка — как раньше для pkg: не зависим от
#    package.json проекта, не ловим сюрприз от обновления пакета) ---
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

# Фиксированная константа Node.js core, одинаковая для всех версий —
# не привязана к version SEA-blob'а.
SENTINEL="NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"

# --- 3. Для каждой архитектуры: вырезать срез из universal-бинаря
#    (или взять как есть, если node на хосте уже single-arch), снять
#    подпись, внедрить blob, подписать заново ---
build_target() {
  local lipo_arch="$1"   # имя архитектуры для lipo (arm64 / x86_64)
  local out_name="$2"    # имя выходного файла
  local out_path="${OUT_DIR}/${out_name}"

  if echo "$LIPO_INFO" | grep -q "fat file:.*\b${lipo_arch}\b"; then
    echo "==> Вырезаю срез ${lipo_arch} из universal ${SYSTEM_NODE}..."
    lipo "$SYSTEM_NODE" -thin "$lipo_arch" -output "$out_path"
  elif echo "$LIPO_INFO" | grep -q "architecture: ${lipo_arch}"; then
    echo "==> ${SYSTEM_NODE} уже single-arch (${lipo_arch}), копирую как есть..."
    cp "$SYSTEM_NODE" "$out_path"
  else
    echo "ПРЕДУПРЕЖДЕНИЕ: срез ${lipo_arch} недоступен в ${SYSTEM_NODE} —" >&2
    echo "  пропускаю ${out_name}. Нужен universal node с обеими" >&2
    echo "  архитектурами (официальный .pkg с nodejs.org или" >&2
    echo "  'brew reinstall node' обычно дают universal-сборку)." >&2
    return 1
  fi

  echo "==> Снимаю существующую подпись..."
  codesign --remove-signature "$out_path"

  echo "==> Внедряю SEA blob в ${out_name}..."
  "$POSTJECT_BIN" "$out_path" NODE_SEA_BLOB "${TMP_DIR}/sea-prep.blob" \
    --sentinel-fuse "$SENTINEL" \
    --macho-segment-name NODE_SEA

  echo "==> Ad-hoc подпись ${out_name} (обязательна, иначе ядро убьёт процесс)..."
  codesign --sign - --force "$out_path"
  chmod +x "$out_path"
}

built_count=0
build_target "arm64" "tabvpn-native-host-arm64" && built_count=$((built_count + 1)) || true
build_target "x86_64" "tabvpn-native-host-x64" && built_count=$((built_count + 1)) || true

echo "==> Готовые бинари:"
ls -la "${OUT_DIR}"/tabvpn-native-host-* 2>/dev/null || true

if [ "$built_count" -eq 0 ]; then
  echo "ОШИБКА: ни один бинарь не собран, см. предупреждения выше." >&2
  exit 1
fi
