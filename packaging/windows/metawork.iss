#ifndef AppVersion
  #error AppVersion must be supplied by the package driver
#endif
#ifndef AppDisplayName
  #error AppDisplayName must be supplied by the package driver
#endif
#ifndef AppBundleId
  #error AppBundleId must be supplied by the package driver
#endif
#ifndef AppExecutableName
  #error AppExecutableName must be supplied by the package driver
#endif
#ifndef AppFileVersion
  #error AppFileVersion must be supplied by the package driver
#endif
#ifndef AppArchitecture
  #error AppArchitecture must be supplied by the package driver
#endif
#ifndef RuntimeStage
  #error RuntimeStage must be supplied by the package driver
#endif

[Setup]
AppId={{D91F0757-EE64-4D3C-9CA0-686FE2C12CF4}
AppName={#AppDisplayName}
AppVersion={#AppVersion}
AppPublisher=Metask
DefaultDirName={localappdata}\Programs\{#AppDisplayName}
DefaultGroupName={#AppDisplayName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#AppArchitecture}
ArchitecturesInstallIn64BitMode={#AppArchitecture}
SetupIconFile={#RuntimeStage}\app-icon.ico
UninstallDisplayIcon={app}\app-icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; A tray-resident Host can outlive Restart Manager's normal shutdown request.
; Let Restart Manager terminate it after its shutdown timeout before replacement.
CloseApplications=force
RestartApplications=no
UsePreviousAppDir=yes
OutputBaseFilename=metawork
VersionInfoCompany=Metask
VersionInfoDescription={#AppDisplayName} Installer
VersionInfoProductName={#AppDisplayName}
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppFileVersion}
#ifdef AppSignTool
SignTool={#AppSignTool}
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#RuntimeStage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppDisplayName}"; Filename: "{app}\bin\{#AppExecutableName}.exe"; WorkingDir: "{app}"; IconFilename: "{app}\app-icon.ico"
Name: "{autodesktop}\{#AppDisplayName}"; Filename: "{app}\bin\{#AppExecutableName}.exe"; WorkingDir: "{app}"; IconFilename: "{app}\app-icon.ico"; Tasks: desktopicon

[Registry]
; The app's notification identity (the display name, icon and toast activator
; Windows reads to attribute a toast) lives under this key. The Native SDK
; runtime writes it on the first notification and owns every value in it, so
; the installer writes nothing here and only takes the key away with the app:
; that is what dontcreatekey is for. A value written here would make the
; installer a second owner of an identity that a development run, which has no
; installer at all, already gets right without one.
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\{#AppBundleId}"; Flags: dontcreatekey uninsdeletekey

[Run]
Filename: "{app}\bin\{#AppExecutableName}.exe"; Description: "{cm:LaunchProgram,{#StringChange(AppDisplayName, '&', '&&')}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
