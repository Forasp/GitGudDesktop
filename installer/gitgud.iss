; Inno Setup script for the GitGud Desktop installer. package.ps1 compiles it
; from the assembled build\dist\GitGud folder; by hand:
;
;   iscc /DAppVersion=1.4.0 installer\gitgud.iss
;
; Installs under Program Files for all users by default. The first page
; offers a per-user install instead (no admin rights), and the folder is the
; user's choice. The app writes only to %APPDATA%\Gitgud, which uninstalling
; leaves alone.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\dist\GitGud"
#endif
#ifndef OutputDir
  #define OutputDir "..\build\dist"
#endif
#ifndef OutputBaseName
  #define OutputBaseName "GitGud-win64-setup"
#endif

#define AppName "GitGud Desktop"
#define AppExe "gitgud.exe"

[Setup]
; Never change AppId: upgrades and the uninstaller find the install by it.
AppId={{3DCDC712-0C9D-42CA-A13C-CA9E93DF07B1}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=GitGud Desktop
AppPublisherURL=https://github.com/Forasp/GitGudDesktop
AppSupportURL=https://github.com/Forasp/GitGudDesktop/issues
AppUpdatesURL=https://github.com/Forasp/GitGudDesktop/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\GitGud
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=no
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
ChangesEnvironment=yes
CloseApplications=yes
SetupIconFile=..\resources\icon\gitgud.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "Add gitgud to PATH (""gitgud ."" in a terminal opens that folder)"; GroupDescription: "Command line:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Updates (gitgud-patcher.exe) can add files Setup never installed, which
; its uninstall log doesn't know about: remove everything a package ships.
Type: filesandordirs; Name: "{app}\resources"
Type: filesandordirs; Name: "{app}\docs"
Type: filesandordirs; Name: "{app}\cegui-datafiles"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\gitgud*.exe"
Type: files; Name: "{app}\*.txt"
Type: files; Name: "{app}\LICENSE"

[Code]
// PATH lives in HKCU for a per-user install and HKLM for an all-users one.
// RegWriteStringValue keeps the value's existing type (REG_SZ or
// REG_EXPAND_SZ), so only the entry itself changes.
function EnvRoot: Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_LOCAL_MACHINE
  else
    Result := HKEY_CURRENT_USER;
end;

function EnvKey: String;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

// Where Dir starts in ';' + Path + ';' (its leading ';'), or 0.
function PathEntryPos(const Path, Dir: String): Integer;
begin
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';');
end;

procedure AddToPath(const Dir: String);
var
  Path: String;
begin
  if not RegQueryStringValue(EnvRoot, EnvKey, 'Path', Path) then
    Path := '';
  if PathEntryPos(Path, Dir) > 0 then
    exit;
  if (Path <> '') and (Path[Length(Path)] <> ';') then
    Path := Path + ';';
  RegWriteStringValue(EnvRoot, EnvKey, 'Path', Path + Dir);
end;

procedure RemoveFromPath(const Dir: String);
var
  Path: String;
  P: Integer;
begin
  if not RegQueryStringValue(EnvRoot, EnvKey, 'Path', Path) then
    exit;
  P := PathEntryPos(Path, Dir);
  if P = 0 then
    exit;
  // Drop ';Dir' from ';' + Path + ';', then the two added ends.
  Path := ';' + Path + ';';
  Delete(Path, P, Length(Dir) + 1);
  Path := Copy(Path, 2, Length(Path) - 2);
  RegWriteStringValue(EnvRoot, EnvKey, 'Path', Path);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddToPath(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveFromPath(ExpandConstant('{app}'));
end;
