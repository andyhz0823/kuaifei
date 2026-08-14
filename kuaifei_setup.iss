[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}}
AppVersion=4.1.11
AppName=Kuaifei
AppPublisher=Kuaifei
AppPublisherURL=https://github.com/andyhz0823/Xboard
AppSupportURL=https://github.com/andyhz0823/Xboard
AppUpdatesURL=https://xz.kuaity.top/Downloads/
DefaultDirName={autopf64}\Kuaifei
DisableProgramGroupPage=yes
OutputDir=dist\4.1.11+40113
OutputBaseFilename=kuaifei-4.1.11
Compression=lzma
SolidCompression=yes
SetupIconFile=windows\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=force
VersionInfoVersion=4.1.11.0
VersionInfoProductVersion=4.1.11.0
VersionInfoDescription=Kuaifei
VersionInfoProductName=Kuaifei
VersionInfoCompany=Kuaifei
VersionInfoOriginalFileName=kuaifei-4.1.11.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: checkedonce
Name: "launchAtStartup"; Description: "Auto-start at login"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kuaifei"; Filename: "{app}\kuaifei.exe"
Name: "{autodesktop}\Kuaifei"; Filename: "{app}\kuaifei.exe"; Tasks: desktopicon
Name: "{userstartup}\Kuaifei"; Filename: "{app}\kuaifei.exe"; WorkingDir: "{app}"; Tasks: launchAtStartup

[Run]
Filename: "{app}\kuaifei.exe"; Description: "Launch kuaifei"; Flags: runascurrentuser nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\kuaifei"

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM hiddify.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('net', 'stop "kuaifeiTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'delete "kuaifeiTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;
