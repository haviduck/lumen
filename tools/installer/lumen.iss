; ============================================================================
; Lumen — Inno Setup installer script
; ============================================================================
;
; Builds a per-user Windows installer for Lumen. Designed to mirror the
; install model used by VS Code / Cursor / Discord:
;
;   - Installs to %LOCALAPPDATA%\Programs\Lumen (no UAC, no admin
;     required, no SmartScreen elevation prompt).
;   - Stable AppId GUID so re-running the installer upgrades in place
;     instead of stacking a second copy.
;   - Standard ARP (Add/Remove Programs) entry for clean uninstall.
;   - Optional Start Menu group + optional desktop shortcut.
;   - "Launch Lumen" checkbox at the end of install.
;
; The flags `/SILENT /SUPPRESSMSGBOXES /RESTARTAPPLICATIONS` are what
; lib/services/update_service.dart passes when running the installer
; for an auto-update. Inno Setup's Restart Manager support (built in
; since 5.5) cleanly closes a running lumen.exe, swaps the files, then
; restarts the app — much friendlier than asking the user to kill it.
;
; To build:
;   cd tools\installer
;   .\build.ps1
;
; Or pass version directly to iscc:
;   iscc /DAppVersion=1.0.12 tools\installer\lumen.iss
;
; The script reads the staged release build from
; ..\..\build\windows\x64\runner\Release relative to this .iss file.
; Run `flutter build windows --release` first.
;
; SmartScreen note: this installer is unsigned. Until a code signing
; cert is in place, Windows will show "Windows protected your PC" on
; first download. Users have to click "More info" → "Run anyway".
; See README.md "Install" section.

#ifndef AppVersion
  #define AppVersion "1.0.12"
#endif

#define AppName        "Lumen"
#define AppPublisher   "Carl Martin Haug"
#define AppURL         "https://github.com/haviduck/lumen"
#define AppExeName     "lumen.exe"
; Stable GUID — DO NOT change this between releases. It's the AppId
; the Inno installer uses to detect an existing install (and replace
; it). Changing it means the next installer stacks a fresh copy
; instead of upgrading, leaving the old install + ARP entry behind.
#define AppId          "{{A3F8C9E2-7B41-4D5C-9E8A-1F2C3D4E5A6B}"
#define SourceDir      "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
; Per-user install. {userpf} = %LOCALAPPDATA%\Programs when
; PrivilegesRequired=lowest. No UAC prompt.
DefaultDirName={userpf}\{#AppName}
DefaultGroupName={#AppName}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Allow the installer to keep running even when Lumen is open —
; Restart Manager will shut it down, swap files, and restart it.
; The /RESTARTAPPLICATIONS flag is honored on the auto-update path.
CloseApplications=force
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=yes
; Disable the welcome page — we already know users want this app.
DisableWelcomePage=yes
; Modern wizard look.
WizardStyle=modern
; Compress for download size. lzma2/ultra produces ~3-4% smaller
; than the default, and only adds a couple seconds to ISCC.
Compression=lzma2/ultra
SolidCompression=yes
; ARP / uninstaller wiring.
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName} {#AppVersion}
; Output location and filename.
OutputDir=..\..\dist
OutputBaseFilename=Lumen-Setup-v{#AppVersion}
; Don't recommend creating a logfile — we don't read it.
SetupLogging=no
; License / info pages skipped for now.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked
Name: "quicklaunchicon"; Description: "Create a &Quick Launch icon"; GroupDescription: "Additional icons:"; Flags: unchecked; OnlyBelowVersion: 6.1

[Files]
; Main exe at install root.
Source: "{#SourceDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
; All DLLs at install root (flutter_windows.dll, plugin DLLs, etc.).
Source: "{#SourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
; data/ — flutter_assets, icudtl.dat, AOT lib (app.so), etc.
; recursesubdirs is REQUIRED — data\ has nested folders.
Source: "{#SourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Don't touch %APPDATA%\lumen or %LOCALAPPDATA%\Lumen — those carry
; user prefs, workspaces, chat history, WebView2 cache, etc. Same
; rule as VS Code uninstaller — uninstall removes the binaries; user
; data is preserved for the next install.
;
; If a user wants a clean wipe, they manually delete those folders;
; we can also expose a "Reset Lumen" command from inside the app
; later.
