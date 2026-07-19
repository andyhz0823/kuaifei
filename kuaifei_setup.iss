[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}}
AppVersion=4.1.5+40105
AppName=kuaifei
AppPublisher=kuaifei
AppPublisherURL=https://github.com/hiddify/hiddify-app
AppSupportURL=https://github.com/hiddify/hiddify-app
AppUpdatesURL=https://github.com/hiddify/hiddify-app
DefaultDirName={autopf64}\kuaifei
DisableProgramGroupPage=yes
OutputDir=dist\4.1.5+40105
OutputBaseFilename=kuaifei-v4.1.5-windows64-setup
Compression=lzma
SolidCompression=yes
SetupIconFile=windows\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: checkedonce
Name: "launchAtStartup"; Description: "Auto-start at login"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\kuaifei"; Filename: "{app}\kuaifei.exe"
Name: "{autodesktop}\kuaifei"; Filename: "{app}\kuaifei.exe"; Tasks: desktopicon
Name: "{userstartup}\kuaifei"; Filename: "{app}\kuaifei.exe"; WorkingDir: "{app}"; Tasks: launchAtStartup

[Run]
Filename: "{app}\kuaifei.exe"; Description: "Launch kuaifei"; Flags: runascurrentuser nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\kuaifei"

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM hiddify.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  Exec('net', 'stop "kuaifeiTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  Exec('sc.exe', 'delete "kuaifeiTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  Result := True;
end;
