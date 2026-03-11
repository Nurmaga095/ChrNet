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

[Setup]
AppId={{D4855A14-C494-4CCC-87FE-E3C2A296D8D3}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
AppMutex=ChrNetSingleInstanceMutex
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
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
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
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function NeedVCRedist: Boolean;
var
  Installed: Cardinal;
begin
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) then
    Result := Installed <> 1
  else
    Result := True;
end;
