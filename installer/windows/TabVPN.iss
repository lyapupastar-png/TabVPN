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
  TaskCmd: String;
begin
  // Task Scheduler, контекст текущего пользователя, без admin —
  // аналог LaunchAgent на macOS. /rl limited — обычные права, /f —
  // перезаписать, если задача от предыдущей установки уже есть.
  TaskCmd := Format('/create /tn "TabVPN Tor" /tr "\"%s\" -f \"%s\"" /sc onlogon /rl limited /f', [TorExePath, TorrcPath]);
  Exec(ExpandConstant('{sys}\schtasks.exe'), TaskCmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ResultCode <> 0 then
    Log('schtasks /create завершился с кодом ' + IntToStr(ResultCode) + ' — автозапуск Tor может не сработать при следующем логине');
end;

procedure StartTorNow;
var
  ResultCode: Integer;
begin
  // Запускаем сразу после установки, чтобы не ждать перелогина —
  // тот же принцип, что launchctl bootstrap в macOS postinstall.
  Exec(TorExePath, '-f "' + TorrcPath + '"', '', SW_HIDE, ewNoWait, ResultCode);
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
