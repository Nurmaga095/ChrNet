#ifndef ReleaseDir
  #error ReleaseDir is not defined. Pass /DReleaseDir=...
#endif

#ifndef VCRedistPath
  #error VCRedistPath is not defined. Pass /DVCRedistPath=...
#endif

#ifndef AppVersion
  #error AppVersion is not defined. Pass /DAppVersion from pubspec.yaml version.
#endif

#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

#define MyAppName "ChrNet"
#define MyAppPublisher "ChrNet"
#define MyAppExeName "chrnet.exe"
#define MyRuntimeExeName "xray.exe"
#define MyServiceExeName "chrnet_service.exe"
#define MyServiceName "ChrNetService"
#define MyWindowClass "FLUTTER_RUNNER_WIN32_WINDOW"

[Setup]
AppId={{D4855A14-C494-4CCC-87FE-E3C2A296D8D3}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir={#OutputDir}
OutputBaseFilename=ChrNet-Setup-{#AppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
CloseApplications=force
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile={#ReleaseDir}\app_icon.ico

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; logs\ and runtime\ appear next to the binaries when the service is run from
; the build folder for diagnostics; they must never ship.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "logs\*,runtime\*"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VCRedistPath}"; DestDir: "{tmp}"; DestName: "vc_redist.x64.exe"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"; Tasks: desktopicon

[Registry]
; Register chrnet:// URL scheme so the OS launches the app for deep links
Root: HKCR; Subkey: "chrnet"; ValueType: string; ValueName: ""; ValueData: "URL:ChrNet Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "chrnet"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCR; Subkey: "chrnet\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCR; Subkey: "chrnet\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ Runtime..."; Flags: waituntilterminated runhidden; Check: NeedVCRedist
; The service runs the VPN core, so the app itself needs no administrator
; rights. --install also updates and restarts an existing registration.
Filename: "{app}\{#MyServiceExeName}"; Parameters: "--install"; StatusMsg: "Регистрация службы ChrNet..."; Flags: waituntilterminated runhidden
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#MyServiceExeName}"; Parameters: "--uninstall"; Flags: waituntilterminated runhidden; RunOnceId: "RemoveService"
Filename: "{app}\{#MyAppExeName}"; Parameters: "--cleanup"; Flags: waituntilterminated runhidden; RunOnceId: "RestoreProxy"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\runtime"

[Code]
const
  WM_COMMAND = $0111;
  // The tray menu's "Exit": disconnects and restores the proxy settings.
  TrayCommandExit = 2002;

// Closes ChrNet the way its tray "Exit" does, so it disconnects cleanly, and
// kills it only if it does not go away in time.
procedure CloseRunningApp;
var
  Wnd: HWND;
  Attempt: Integer;
  ResultCode: Integer;
begin
  Wnd := FindWindowByClassName('{#MyWindowClass}');
  if Wnd <> 0 then
  begin
    PostMessage(Wnd, WM_COMMAND, TrayCommandExit, 0);
    for Attempt := 1 to 50 do
    begin
      Sleep(200);
      if FindWindowByClassName('{#MyWindowClass}') = 0 then
        Break;
    end;
  end;
  Exec('taskkill.exe', '/F /IM "{#MyAppExeName}"', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
end;

procedure StopService;
var
  ResultCode: Integer;
begin
  // net stop waits until the service has actually stopped.
  Exec(ExpandConstant('{sys}\net.exe'), 'stop {#MyServiceName}', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
end;

procedure StopEverything;
var
  ResultCode: Integer;
begin
  CloseRunningApp;
  StopService;
  Exec('taskkill.exe', '/F /IM "{#MyRuntimeExeName}"', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  // Only builds that ship the service understand --cleanup; an older
  // chrnet.exe would open its window instead. The new app repairs the proxy
  // settings of older versions itself on first start.
  if FileExists(ExpandConstant('{app}\{#MyServiceExeName}')) then
    Exec(ExpandConstant('{app}\{#MyAppExeName}'), '--cleanup', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopEverything;
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseRunningApp;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKEY_CURRENT_USER,
      'Software\Microsoft\Windows\CurrentVersion\Run', 'ChrNet');
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\ChrNet\ProxyBackup');
    RegDeleteKeyIncludingSubkeys(HKLM64, 'SOFTWARE\ChrNet');
  end;
end;

function NeedVCRedist: Boolean;
var
  Installed: Cardinal;
begin
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) then
    Result := Installed <> 1
  else
    Result := True;
end;
