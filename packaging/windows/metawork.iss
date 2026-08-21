#ifndef AppVersion
  #error AppVersion must be supplied by the package driver
#endif
#ifndef AppDisplayName
  #error AppDisplayName must be supplied by the package driver
#endif
#ifndef AppExecutableName
  #error AppExecutableName must be supplied by the package driver
#endif
#ifndef AppFileVersion
  #error AppFileVersion must be supplied by the package driver
#endif

#define RuntimeStage "..\..\zig-out\package\windows-runtime-x64"

[Setup]
AppId={{D91F0757-EE64-4D3C-9CA0-686FE2C12CF4}
AppName={#AppDisplayName}
AppVersion={#AppVersion}
AppPublisher=Metask
DefaultDirName={localappdata}\Programs\{#AppDisplayName}
DefaultGroupName={#AppDisplayName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile={#RuntimeStage}\app-icon.ico
UninstallDisplayIcon={app}\app-icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes
OutputBaseFilename=metawork-setup
VersionInfoCompany=Metask
VersionInfoDescription={#AppDisplayName} Installer
VersionInfoProductName={#AppDisplayName}
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppFileVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#RuntimeStage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppDisplayName}"; Filename: "{app}\bin\{#AppExecutableName}.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppDisplayName}"; Filename: "{app}\bin\{#AppExecutableName}.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\bin\{#AppExecutableName}.exe"; Description: "{cm:LaunchProgram,{#StringChange(AppDisplayName, '&', '&&')}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
