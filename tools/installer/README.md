# Lumen installer

Builds a per-user Windows installer for Lumen.

## Prerequisites

- Flutter SDK with Windows desktop enabled (`flutter config --enable-windows-desktop`).
- Visual Studio Build Tools with the "Desktop development with C++" workload.
- [Inno Setup 6 or 7](https://jrsoftware.org/isdl.php) installed. `build.ps1` auto-probes both major versions under `C:\Program Files\Inno Setup {6,7}\ISCC.exe` and the `(x86)` equivalents, plus `PATH`. Override with `-Iscc <full-path>` if needed.

## Build

From the repo root, in PowerShell:

```powershell
.\tools\installer\build.ps1
```

This runs `flutter build windows --release`, compiles the installer with `iscc`, and produces both artefacts in `dist\`:

- `Lumen-Setup-v<version>.exe` — the installer.
- `lumen-v<version>-windows-x64.zip` — portable zip for power users.

Pass `-SkipBuild` to reuse the existing `build\windows\x64\runner\Release` output (useful when iterating on the `.iss` script):

```powershell
.\tools\installer\build.ps1 -SkipBuild
```

Pass `-NoZip` to skip the portable zip when you only need the installer.

## What the installer does

- Installs to `%LOCALAPPDATA%\Programs\Lumen\` (per-user, no UAC).
- Adds an entry to **Apps & Features** (Add/Remove Programs).
- Creates a Start Menu shortcut. Desktop shortcut is opt-in via the wizard.
- Registers Restart Manager hooks so a running `lumen.exe` is cleanly closed and restarted during in-place upgrades.
- Preserves user data on uninstall (`%APPDATA%\lumen`, `%LOCALAPPDATA%\Lumen\WebView2 cache`, prefs, etc.).

## Auto-update integration

`lib/services/update_service.dart` polls the GitHub Releases API on app boot (debounced to once per 12 h via `update.lastCheck` pref). When a newer release is found, it downloads the asset whose name matches `^Lumen-Setup-.*\.exe` to `%TEMP%`, then runs it with:

```
Lumen-Setup-vX.Y.Z.exe /SILENT /SUPPRESSMSGBOXES /RESTARTAPPLICATIONS
```

The flags tell Inno Setup to:
- `/SILENT` — show only a small progress indicator, no wizard.
- `/SUPPRESSMSGBOXES` — accept default answers (overwrite files etc.).
- `/RESTARTAPPLICATIONS` — close the running Lumen instance via Restart Manager and relaunch it after install.

Do not rename `Lumen-Setup-v<version>.exe` when uploading to the GitHub release — the regex above won't match.

## SmartScreen / signing

The installer is currently **unsigned**. On first download, Windows will show:

> Microsoft Defender SmartScreen prevented an unrecognized app from starting.

Users have to click "More info" → "Run anyway". This is a known cost of shipping unsigned binaries; SmartScreen's reputation system gradually learns the publisher over time, but only ever for a specific signed identity.

To remove this prompt entirely, sign the installer with an EV or OV code-signing certificate. Two reasonable paths:

- Buy a commercial OV cert (~$300/year, e.g. Sectigo, DigiCert). Reputation builds up over a few hundred installs.
- Apply to the [SignPath Foundation](https://signpath.org/about) free OSS signing program (~2-3 week review). Free for qualifying open-source projects.

When signing is ready, add a signtool step between `iscc` and zip in `build.ps1`. The Inno script already declares `VersionInfoCompany` / `VersionInfoProductName` so the signed binary's metadata reads cleanly.
