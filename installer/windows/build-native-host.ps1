# build-native-host.ps1 — компилирует native-host/index.js в отдельный
# бинарь под Windows x64 через Node.js SEA + postject. См.
# PLAN-CROSSPLATFORM.md, Задача 4; образец —
# installer/macos/build-native-host.sh.
#
# Написан и впервые прогнан не на Windows, а на macOS через
# PowerShell 7 (pwsh) — рабочий кроссплатформенный интерпретатор,
# см. NEXT_TASK.md. Тот же принцип, что для installer/linux/
# build-native-host.sh: postject не исполняет файл, в который
# внедряет blob (только редактирует секции PE), поэтому хост сборки
# не обязан быть Windows — официальный node-v$Version-win-x64.zip
# скачивается с nodejs.org напрямую и инъекция делается на любой ОС.
# На реальном windows-latest CI-раннере (Задача 11) этот же скрипт
# должен отработать идентично (используется тот же кроссплатформенный
# API — Invoke-WebRequest/Expand-Archive/tar — ничего Windows-
# специфичного, требующего именно Windows, здесь нет).
#
# В отличие от macOS Gatekeeper — PE-файл НЕ требует подписи для
# локального запуска, шаг codesign не нужен (см. Задачу 4 плана).
#
# Использование: .\build-native-host.ps1 [-OutDir build] [-Arch x64]

param(
    [string]$OutDir = (Join-Path (Get-Location) "build"),
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$NodeVersion = "20.18.0"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir "../..")
$Src = Join-Path $ProjectRoot "native-host/index.js"

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$localNode = Get-Command node -ErrorAction SilentlyContinue
if (-not $localNode) {
    throw "node не найден в PATH — нужен для генерации SEA-blob (--experimental-sea-config)."
}
Write-Host "==> Локальный node для генерации blob'а: $($localNode.Source) ($(node --version))"

$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tabvpn-native-host-build-" + [guid]::NewGuid().ToString())
$PostjectInstallDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tabvpn-postject-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TmpDir | Out-Null
New-Item -ItemType Directory -Path $PostjectInstallDir | Out-Null

try {
    Write-Host "==> Скачиваю официальный node v$NodeVersion win-$Arch..."
    $nodeZipName = "node-v$NodeVersion-win-$Arch.zip"
    $nodeUrl = "https://nodejs.org/dist/v$NodeVersion/$nodeZipName"
    $nodeZipPath = Join-Path $TmpDir $nodeZipName
    Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeZipPath -UseBasicParsing

    Expand-Archive -Path $nodeZipPath -DestinationPath $TmpDir
    $targetNode = Join-Path $TmpDir "node-v$NodeVersion-win-$Arch/node.exe"
    if (-not (Test-Path $targetNode)) {
        throw "Не нашёл node.exe внутри распакованного $nodeZipName"
    }
    Write-Host "==> Целевой node.exe: $targetNode"

    Write-Host "==> Генерирую SEA blob из $Src..."
    $seaConfigPath = Join-Path $TmpDir "sea-config.json"
    $seaBlobPath = Join-Path $TmpDir "sea-prep.blob"
    @{
        main = $Src
        output = $seaBlobPath
        disableExperimentalSEAWarning = $true
    } | ConvertTo-Json | Set-Content -Path $seaConfigPath
    node --experimental-sea-config $seaConfigPath

    Write-Host "==> Ставлю postject локально (версия 1.0.0-alpha.6)..."
    @{
        name = "tabvpn-native-host-build-tooling"
        private = $true
        dependencies = @{ postject = "1.0.0-alpha.6" }
    } | ConvertTo-Json | Set-Content -Path (Join-Path $PostjectInstallDir "package.json")
    Push-Location $PostjectInstallDir
    npm install --no-audit --no-fund --loglevel=error
    Pop-Location
    $postjectBin = Join-Path $PostjectInstallDir "node_modules/.bin/postject"
    if ($IsWindows) { $postjectBin = "$postjectBin.cmd" }

    $sentinel = "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"
    $outName = "tabvpn-native-host-windows-$Arch.exe"
    $outPath = Join-Path $OutDir $outName
    Copy-Item $targetNode $outPath -Force

    Write-Host "==> Внедряю SEA blob в $outName..."
    & $postjectBin $outPath NODE_SEA_BLOB $seaBlobPath --sentinel-fuse $sentinel

    Write-Host "==> Готово: $outPath"
    Write-Warning "Бинарь собран (валидный PE), но НЕ ЗАПУСКАЛСЯ на реальной Windows — синтетическую native-messaging команду проверить нельзя (см. Задачу 12)."
}
finally {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $PostjectInstallDir -ErrorAction SilentlyContinue
}
