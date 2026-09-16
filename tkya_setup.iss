[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}}
AppVersion=1.0.2
AppName=Tkya
AppPublisher=Tkya
AppPublisherURL=https://github.com/andyhz0823/Xboard
AppSupportURL=https://github.com/andyhz0823/Xboard
AppUpdatesURL=https://xz.tkya.cc.cd/Downloads/
DefaultDirName={autopf64}\Tkya
DisableProgramGroupPage=yes
OutputDir=dist\1.0.2+10002
OutputBaseFilename=tkya-1.0.2
Compression=lzma
SolidCompression=yes
SetupIconFile=windows\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=force
VersionInfoVersion=1.0.2.0
VersionInfoProductVersion=1.0.2.0
VersionInfoDescription=Tkya
VersionInfoProductName=Tkya
VersionInfoCompany=Tkya
VersionInfoOriginalFileName=tkya-1.0.2.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: checkedonce
Name: "launchAtStartup"; Description: "Auto-start at login"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Tkya"; Filename: "{app}\tkya.exe"
Name: "{autodesktop}\Tkya"; Filename: "{app}\tkya.exe"; Tasks: desktopicon
Name: "{userstartup}\Tkya"; Filename: "{app}\tkya.exe"; WorkingDir: "{app}"; Tasks: launchAtStartup

[Run]
Filename: "{app}\tkya.exe"; Description: "Launch tkya"; Flags: runascurrentuser nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\tkya"

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM hiddify.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('net', 'stop "tkyaTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'delete "tkyaTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;
