; Inno Setup script for the Windows release installer.
; Built by .github/workflows/windows-release.yml:
;   ISCC /DAppVersion=<version> /DBuildDir=<Release dir> /DOutputDir=<dir> /DOutputBaseName=<name> aicove.iss
; Installs per user (no admin). AppId must never change: running a newer
; installer upgrades the existing install in place. User data lives outside
; {app}, so upgrading or uninstalling never touches it.

#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildDir
  #error BuildDir is required
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputBaseName
  #define OutputBaseName "AIcove-" + AppVersion + "-windows-x64-setup"
#endif

#define AppExe "aicove_flutter.exe"

[Setup]
AppId={{05D08189-21BC-4842-8078-8B354A5BF5FF}
AppName=AIcove
AppVersion={#AppVersion}
AppVerName=AIcove {#AppVersion}
AppPublisher=AIcove
AppPublisherURL=https://github.com/kuobibulaien/AIcove
AppUpdatesURL=https://github.com/kuobibulaien/AIcove/releases
DefaultDirName={autopf}\AIcove
DefaultGroupName=AIcove
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=AIcove
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Drop files of the previous version so removed assets do not linger.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\AIcove"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\AIcove"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,AIcove}"; Flags: nowait postinstall skipifsilent
