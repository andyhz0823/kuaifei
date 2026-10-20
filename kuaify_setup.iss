[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}}
AppVersion=5.0.0
AppName=Kuaify
AppPublisher=Kuaify
AppPublisherURL=https://github.com/andyhz0823/Xboard
AppSupportURL=https://github.com/andyhz0823/Xboard
AppUpdatesURL=https://xz.kuaity.top/Downloads/
DefaultDirName={autopf64}\Kuaify
DisableProgramGroupPage=yes
OutputDir=dist\5.0.0+1
OutputBaseFilename=kuaify-5.0.0
Compression=lzma
SolidCompression=yes
SetupIconFile=windows\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=force
VersionInfoVersion=5.0.0.0
VersionInfoProductVersion=5.0.0.0
VersionInfoDescription=Kuaify
VersionInfoProductName=Kuaify
VersionInfoCompany=Kuaify
VersionInfoOriginalFileName=kuaify-5.0.0.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: checkedonce
Name: "launchAtStartup"; Description: "Auto-start at login"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kuaify"; Filename: "{app}\kuaify.exe"
Name: "{autodesktop}\Kuaify"; Filename: "{app}\kuaify.exe"; Tasks: desktopicon
Name: "{userstartup}\Kuaify"; Filename: "{app}\kuaify.exe"; WorkingDir: "{app}"; Tasks: launchAtStartup

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
