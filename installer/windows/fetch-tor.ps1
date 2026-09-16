# fetch-tor.ps1 — скачивает Tor Expert Bundle для Windows и извлекает
# tor.exe.
#
# Логика (определение последней версии по листингу, поиск бинаря по
# имени файла вместо хардкода пути, копирование зависимостей рядом с
# бинарём) — прямой перенос принципов из installer/macos/fetch-tor.sh
# и installer/linux/fetch-tor.sh на PowerShell.
#
# Использование: .\fetch-tor.ps1 [-OutDir build] [-Arch x86_64]

param(
    [string]$OutDir = (Join-Path (Get-Location) "build"),
    [string]$Arch = "x86_64"
)

$ErrorActionPreference = "Stop"
$BaseUrl = "https://dist.torproject.org/torbrowser"
$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tabvpn-tor-fetch-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $WorkDir | Out-Null

try {
    Write-Host "==> Определяю последнюю стабильную версию Tor Browser..."
    # Та же логика, что в bash-версиях: версии вида "15.0.22/" —
    # стабильные, "16.0a11/" — альфа (буква после номера) отсеивается
    # регексом, версию/путь не хардкодим.
    $listing = Invoke-WebRequest -Uri "$BaseUrl/" -UseBasicParsing
    $versions = [regex]::Matches($listing.Content, 'href="([0-9]+\.[0-9]+(?:\.[0-9]+)?)/"') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -notmatch '(a|b|rc)[0-9]*$' } |
        Sort-Object { [version]$_ }
    $latestVersion = $versions | Select-Object -Last 1

    if (-not $latestVersion) {
        throw "Не удалось определить версию Tor Browser из листинга $BaseUrl/"
    }
    Write-Host "==> Последняя стабильная версия: $latestVersion"

    $versionUrl = "$BaseUrl/$latestVersion/"

    Write-Host "==> Ищу файл expert bundle для windows-$Arch..."
    $versionListing = Invoke-WebRequest -Uri $versionUrl -UseBasicParsing
    $bundleMatch = [regex]::Match(
        $versionListing.Content,
        "href=`"(tor-expert-bundle-windows-$Arch[^`"]*\.tar\.gz)`""
    )
    if (-not $bundleMatch.Success) {
        throw "Не нашёл tor-expert-bundle-windows-$Arch*.tar.gz в $versionUrl"
    }
    $bundleName = $bundleMatch.Groups[1].Value
    Write-Host "==> Файл: $bundleName"

    $bundlePath = Join-Path $WorkDir $bundleName
    Write-Host "==> Скачиваю $versionUrl$bundleName..."
    Invoke-WebRequest -Uri "$versionUrl$bundleName" -OutFile $bundlePath -UseBasicParsing

    Write-Host "==> Распаковываю..."
    $extractDir = Join-Path $WorkDir "extracted"
    New-Item -ItemType Directory -Path $extractDir | Out-Null
    # tar встроен в Windows начиная с 10 (сборка 1803+) и доступен на
    # раннере windows-latest без дополнительной установки — как и в
    # bash-версиях, не полагаемся на сторонние архиваторы (7-Zip и т.п.).
    tar -xzf $bundlePath -C $extractDir

    Write-Host "==> Ищу tor.exe внутри распакованного архива (путь внутри архива не хардкодим, как и в bash-версиях)..."
    $torExe = Get-ChildItem -Path $extractDir -Recurse -Filter "tor.exe" | Select-Object -First 1
    if (-not $torExe) {
        throw "Не нашёл tor.exe внутри распакованного архива"
    }
    Write-Host "==> Найден: $($torExe.FullName)"

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    # Имя с суффиксом архитектуры — как в installer/linux/fetch-tor.sh,
    # чтобы сборки под разные архитектуры могли сосуществовать в одной
    # build/ директории.
    $outExe = Join-Path $OutDir "tor-windows-$Arch.exe"
    Copy-Item $torExe.FullName $outExe -Force

    Write-Host "==> Копирую зависимости (.dll) рядом с tor.exe..."
    $torDir = $torExe.DirectoryName
    $dlls = Get-ChildItem -Path $torDir -Filter "*.dll"
    if ($dlls.Count -eq 0) {
        Write-Host "   (рядом с tor.exe нет .dll — похоже, статическая линковка, доп. зависимости не нужны)"
    } else {
        foreach ($dll in $dlls) {
            Copy-Item $dll.FullName (Join-Path $OutDir $dll.Name) -Force
            Write-Host "   - $($dll.Name)"
        }
    }

    Write-Host "==> Готово: $outExe"
}
finally {
    Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}
