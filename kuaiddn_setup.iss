; 版本号由 CI 注入：iscc /DMyAppVersion=5.0.0 /DMyAppBuild=3
; 这里保留兜底默认值，避免本地直接双击编译时报错。
; 🔴 不要再把版本号写死在这里：5.0.0 那次就是因为写死 5.0.1，
;    产物名变成 kuaify-5.0.1.exe，而工作流按 pubspec 找 kuaify-5.0.0.exe 才失败。
#ifndef MyAppVersion
  #define MyAppVersion "5.0.1"
#endif
#ifndef MyAppBuild
  #define MyAppBuild "2"
#endif

[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}}
AppVersion={#MyAppVersion}
AppName=Kuaiddn
AppPublisher=Kuaiddn
AppPublisherURL=https://github.com/andyhz0823/Xboard
AppSupportURL=https://github.com/andyhz0823/Xboard
AppUpdatesURL=https://xz.kuaity.top/Downloads/
DefaultDirName={autopf64}\Kuaiddn
DisableProgramGroupPage=yes
OutputDir=dist\{#MyAppVersion}+{#MyAppBuild}
OutputBaseFilename=kuaiddn-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
SetupIconFile=windows\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=force
VersionInfoVersion={#MyAppVersion}.0
VersionInfoProductVersion={#MyAppVersion}.0
VersionInfoDescription=Kuaiddn
VersionInfoProductName=Kuaiddn
VersionInfoCompany=Kuaiddn
VersionInfoOriginalFileName=kuaiddn-{#MyAppVersion}.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: checkedonce
Name: "launchAtStartup"; Description: "Auto-start at login"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kuaiddn"; Filename: "{app}\kuaify.exe"
Name: "{autodesktop}\Kuaiddn"; Filename: "{app}\kuaify.exe"; Tasks: desktopicon
Name: "{userstartup}\Kuaiddn"; Filename: "{app}\kuaify.exe"; WorkingDir: "{app}"; Tasks: launchAtStartup

[Run]
Filename: "{app}\kuaify.exe"; Description: "Launch kuaify"; Flags: runascurrentuser nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\kuaify"

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM hiddify.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('net', 'stop "kuaifyTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'delete "kuaifyTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;
