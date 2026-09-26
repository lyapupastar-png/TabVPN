; TabVPN.iss — инсталлятор для Windows (Inno Setup).
;
; Сборка компилятором ISCC.exe (часть Inno Setup,
; https://jrsoftware.org/isinfo.php):
;   1. Поставь Inno Setup (jrsoftware.org)
;   2. Открой этот файл в Inno Setup Compiler и нажми Compile,
;      или из cmd: "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" TabVPN.iss
;   3. Результат — installer\windows\Output\TabVPN-Setup.exe
;
; PrivilegesRequired=lowest — установка per-user, без admin/UAC.
; Task Scheduler запускает Tor в контексте текущего пользователя без
; повышения прав (/rl limited) — аналог LaunchAgent на macOS (а не
; системного LaunchDaemon).
;
; Без code-signing сертификата — при первом запуске Windows
; SmartScreen покажет предупреждение, пользователь жмёт "Всё равно
; выполнить".

#define AppVersion "0.1.3"

[Setup]
AppId={{B4E1B4B0-8C6F-4B4B-9A2E-TABVPNWIN001}
AppName=TabVPN
AppVersion={#AppVersion}
DefaultDirName={localappdata}\TabVPN
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=TabVPN-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\bin\tor.exe

[Files]
Source: "..\..\build\tor-windows-x86_64.exe"; DestDir: "{app}\bin"; DestName: "tor.exe"; Flags: ignoreversion
Source: "..\..\build\tabvpn-native-host-windows-x64.exe"; DestDir: "{app}\bin"; DestName: "tabvpn-native-host.exe"; Flags: ignoreversion
; tor.exe статически слинкован (fetch-tor.ps1 не нашёл .dll рядом) —
; но если в будущей версии Tor Expert Bundle появятся .dll, заберём
; их тоже (skipifsourcedoesntexist — не ошибка, если файлов нет).
Source: "..\..\build\*.dll"; DestDir: "{app}\bin"; Flags: ignoreversion skipifsourcedoesntexist

[Code]
var
  AppDir, BinDir, TorDataDir, TorrcPath, ManifestPath, TorExePath, HostExePath: String;

function EscapeJsonPath(Path: String): String;
begin
  Result := Path;
  StringChangeEx(Result, '\', '\\', True);
end;

procedure KillIfRunning(ExeName: String);
var
  ResultCode: Integer;
begin
  // /F — принудительно, /IM — по имени образа. Если процесс не найден,
  // taskkill вернёт ненулевой код — это не ошибка, просто игнорируем.
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM "' + ExeName + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  // Вызывается ДО извлечения файлов — критично при апдейте/переустановке:
  // tabvpn-native-host.exe запущен Firefox как native-messaging хост и на
  // момент установки почти наверняка жив, тогда инсталлятор не может
  // перезаписать свой же исполняемый файл ("DeleteFile failed; code 5.
  // Access is denied" — именно так и было на живом тесте). Просто убить
  // сам процесс НЕДОСТАТОЧНО: проверено на живом тесте (2026-09-22) —
  // пока Firefox жив, расширение реконнектится и native-host
  // перезапускается за доли секунды, файл снова залочен ДО начала
  // извлечения. Поэтому сначала закрываем Firefox целиком (без него
  // некому респавнить хост), и только затем добиваем сам процесс —
  // порядок важен.
  KillIfRunning('firefox.exe');
  Sleep(500);
  KillIfRunning('tabvpn-native-host.exe');
  KillIfRunning('tor.exe');
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/end /tn "TabVPN Tor"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(300);
  Result := '';
end;

procedure WriteTorrc;
var
  Lines: TArrayOfString;
begin
  SetArrayLength(Lines, 4);
  Lines[0] := '# torrc для TabVPN — сгенерирован инсталлятором, см. installer/windows/TabVPN.iss';
  Lines[1] := 'SocksPort 9050';
  Lines[2] := 'ControlPort 9051';
  Lines[3] := 'CookieAuthentication 1';
  SaveStringsToFile(TorrcPath, Lines, False);
  SaveStringToFile(TorrcPath, #13#10 + 'DataDirectory ' + TorDataDir, True);
end;

procedure WriteNativeMessagingManifest;
var
  Json: String;
begin
  Json := '{' + #13#10 +
    '  "name": "com.tabvpn.host",' + #13#10 +
    '  "description": "TabVPN native messaging host",' + #13#10 +
    '  "path": "' + EscapeJsonPath(HostExePath) + '",' + #13#10 +
    '  "type": "stdio",' + #13#10 +
    '  "allowed_extensions": ["tabvpn@local"]' + #13#10 +
    '}';
  SaveStringToFile(ManifestPath, Json, False);
end;

procedure RegisterNativeMessagingHost;
begin
  // Firefox на Windows ищет native-messaging хосты через реестр —
  // значение по умолчанию под этим ключом = путь к manifest json.
  RegWriteStringValue(HKCU, 'Software\Mozilla\NativeMessagingHosts\com.tabvpn.host', '', ManifestPath);
end;

procedure RegisterTorAutostart;
var
  ResultCode: Integer;
  Lines: TArrayOfString;
  ScriptPath: String;
begin
  // РАНЬШЕ было: голый "schtasks /create ... /sc onlogon". Задача,
  // созданная так без явных настроек, получает СКРЫТЫЙ лимит
  // ExecutionTimeLimit = P3D (3 дня) — это дефолт Планировщика для
  // задач без явно заданного лимита. По истечении этого времени
  // Планировщик сам убивает процесс tor.exe, без единого уведомления.
  // Найдено 2026-09-25 на живом тесте (машина FLS): задача "TabVPN Tor"
  // и процесс Tor полностью пропали примерно через 3 суток после
  // установки/старта — при этом LastBootUpTime машины не менялся вообще
  // (ни одной перезагрузки). То есть ощущение пользователя "слетело
  // после перезагрузки" не по перезагрузке — совпадение по времени с
  // этим лимитом. schtasks.exe /create из командной строки не даёт
  // способа снять этот лимит или включить restart-on-failure — нужен
  // XML или PowerShell, поэтому регистрируем задачу через generated
  // .ps1 (не голый Exec с inline-командой — вложенные кавычки в
  // command-line для -Argument "-f \"...\"" внутри уже заэкранированной
  // PowerShell-строки быстро становятся нечитаемыми и хрупкими).
  ScriptPath := AppDir + '\register-tor-task.ps1';
  SetArrayLength(Lines, 7);
  Lines[0] := '$torExe = "' + TorExePath + '"';
  Lines[1] := '$torrc = "' + TorrcPath + '"';
  Lines[2] := '$action = New-ScheduledTaskAction -Execute $torExe -Argument (''-f "{0}"'' -f $torrc)';
  Lines[3] := '$trigger = New-ScheduledTaskTrigger -AtLogOn';
  Lines[4] := '$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew';
  Lines[5] := '$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited';
  Lines[6] := 'Register-ScheduledTask -TaskName "TabVPN Tor" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null';
  SaveStringsToFile(ScriptPath, Lines, False);

  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ResultCode <> 0 then
    Log('Register-ScheduledTask завершился с кодом ' + IntToStr(ResultCode) + ' — автозапуск Tor может не сработать при следующем логине');
end;

procedure StartTorNow;
var
  ResultCode: Integer;
  CmdLine: String;
begin
  // Запускаем сразу после установки, чтобы не ждать перелогина —
  // тот же принцип, что launchctl bootstrap в macOS postinstall.
  // Раньше ResultCode вообще не проверялся, и падение Tor проходило
  // незаметно для инсталлятора (именно так был упущен экран "tor.exe —
  // Application Error 0xc0000142" на живом тесте — узнали о нём только
  // из скриншота пользователя). Заворачиваем в cmd.exe, чтобы получить
  // stdout/stderr Tor в файл для диагностики — сам Exec() вывод не ловит.
  CmdLine := '/c ""' + TorExePath + '" -f "' + TorrcPath + '" > "' + AppDir + '\tor-start.log" 2>&1"';
  Exec(ExpandConstant('{cmd}'), CmdLine, '', SW_HIDE, ewNoWait, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    AppDir := ExpandConstant('{app}');
    BinDir := AppDir + '\bin';
    TorDataDir := AppDir + '\tor-data';
    TorrcPath := AppDir + '\torrc';
    ManifestPath := AppDir + '\native-messaging-manifest.json';
    TorExePath := BinDir + '\tor.exe';
    HostExePath := BinDir + '\tabvpn-native-host.exe';

    if not DirExists(TorDataDir) then
      CreateDir(TorDataDir);

    WriteTorrc;
    WriteNativeMessagingManifest;
    RegisterNativeMessagingHost;
    RegisterTorAutostart;
    StartTorNow;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    Exec(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn "TabVPN Tor" /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Mozilla\NativeMessagingHosts\com.tabvpn.host');
  end;
end;
