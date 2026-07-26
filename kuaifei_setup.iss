[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}}
AppVersion=4.1.8
AppName=Kuaifei
AppPublisher=Kuaifei
AppPublisherURL=https://github.com/andyhz0823/Xboard
AppSupportURL=https://github.com/andyhz0823/Xboard
AppUpdatesURL=https://xz.kuaity.top/Downloads/
DefaultDirName={autopf64}\Kuaifei
DisableProgramGroupPage=yes
OutputDir=dist\4.1.8+40110
OutputBaseFilename=Kuaifei-v4.1.8-windows-x64-setup
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
Source: "windows\signing\KuaifeiSoftware.cer"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\Kuaifei"; Filename: "{app}\kuaifei.exe"
Name: "{autodesktop}\Kuaifei"; Filename: "{app}\kuaifei.exe"; Tasks: desktopicon
Name: "{userstartup}\Kuaifei"; Filename: "{app}\kuaifei.exe"; WorkingDir: "{app}"; Tasks: launchAtStartup

[Run]
Filename: "{sys}\certutil.exe"; Parameters: "-f -addstore ""Root"" ""{tmp}\KuaifeiSoftware.cer"""; Flags: runhidden waituntilterminated; StatusMsg: "Trusting the Kuaifei code-signing certificate..."
Filename: "{sys}\certutil.exe"; Parameters: "-f -addstore ""TrustedPublisher"" ""{tmp}\KuaifeiSoftware.cer"""; Flags: runhidden waituntilterminated; StatusMsg: "Trusting Kuaifei as a software publisher..."
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
