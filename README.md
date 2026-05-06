# Lumen

Lumen is a desktop IDE built with Flutter. It combines a code editor, file explorer, terminal, project tools, and an agentic chat interface in one workspace.

The project is currently focused on Windows desktop development, with Flutter platform scaffolding present for other desktop/mobile targets.
### [Grab it from releases](https://github.com/haviduck/lumen/releases)

## Features

- Multi-tab code editor with syntax highlighting, line numbers, markdown preview, word wrap, themes, and file language detection.
- File explorer with context menus, drag/drop moves, copy/cut/paste, undo/redo for explorer operations, Git ignore badges, and file timeline access.
- Integrated terminal with multiple tabs, shell fallback handling, terminal selection actions, and add-to-chat support.
- Agent chat with multiple providers, model management, image attachments, clipboard image paste, file/folder references, prompt queueing, retryable provider errors, and tool approval controls.
- Workspace skills and tools via `.lumen`, plus rules injected into agent prompts.
- File timeline/history for user saves, agent edits, filesystem events, and restore flows.
- Optional integrations for GitNexus, Syncthing, workspace backups, and media playback.





## Build Requirements

- Windows 10 or later for the primary desktop target.
- Flutter SDK with desktop support enabled.
- Visual Studio Build Tools with the Desktop development with C++ workload for Windows builds.
- Git.
- Optional: provider API keys for Anthropic, Gemini, GitHub Models, or OpenAI-compatible services.
- Optional: Ollama for local models.

## Install Flutter

1. Download Flutter from the official installation guide:
   [https://docs.flutter.dev/get-started/install/windows/desktop](https://docs.flutter.dev/get-started/install/windows/desktop)
2. Extract Flutter somewhere stable, for example `C:\src\flutter`.
3. Add `C:\src\flutter\bin` to your user `PATH`.
4. Install Visual Studio Build Tools and include the Desktop development with C++ workload.
5. Verify the setup:

```powershell
flutter doctor
```

Enable Windows desktop support if needed:

```powershell
flutter config --enable-windows-desktop
```

## Getting Started

Clone the repository and install dependencies:

```powershell
git clone https://github.com/haviduck/lumen.git
cd lumen
flutter pub get
```

Run the app on Windows:

```powershell
flutter run -d windows
```

Analyze the project:

```powershell
flutter analyze
```

Run tests:

```powershell
flutter test
```

Build a Windows release:

```powershell
flutter build windows --release
```

The release output is generated under `build\windows\x64\runner\Release`.

## Local Workspace Data

The following folders are local runtime/workspace data and should not be committed:

- `.agents/`
- `.lumen/`
- `.gitnexus/`
- `.stfolder/`
- `build/`
- `.dart_tool/`

Secrets and API keys should be configured locally through the app settings or environment-specific files. Do not commit `.env` files, credentials, generated build outputs, or provider tokens.

## Project Structure

- `lib/` contains the Flutter app code.
- `lib/providers/` contains shared app state and controllers.
- `lib/services/` contains integrations, persistence, tool execution, and workspace services.
- `lib/widgets/` contains the editor, chat, file explorer, terminal, settings, and shared UI.
- `assets/` contains bundled application assets.
- `windows/`, `linux/`, `macos/`, `android/`, and `ios/` contain Flutter platform scaffolding.

## SSH and the AI Agent — what the agent CAN and CANNOT do

Lumen ships an SSH integration (vaulted hosts, in-IDE Remote terminal pane, drag-drop SFTP upload, remote-edit-on-save). When you also use the agentic chat in Lumen, you may reasonably wonder how those two surfaces interact.

**Today, by design, the agent has no direct access to the SSH layer.** The boundary is hard, not advisory:

- The agent **cannot** read your vaulted host list, host fingerprints, passwords, key passphrases, or private key file paths. Secrets live in the OS keystore (`flutter_secure_storage` — DPAPI on Windows, Keychain on macOS, libsecret on Linux); host metadata lives in `SharedPreferences`. Neither store is exposed to any agent tool.
- The agent **cannot** open, control, or read from a live SSH session. The connections are owned by `SshController` and surfaced only to the user-facing Remote pane widget tree; the tool registry has no entry that touches `SshClientService`.
- The agent **cannot** SFTP files to a remote host, edit a remote-mirrored buffer, or trigger a host-key trust prompt. Remote-edit-on-save flows through the user's own Ctrl+S in the editor.
- The agent **cannot** see that an SSH session exists at all — `SshController` is not registered with any tool descriptor. As far as the agent is concerned, there is no SSH layer.

This is a security choice. SSH credentials and active connections give an attacker arbitrary remote command execution under your identity; routing an LLM near them — even with approval prompts — opens a class of "the model misread your intent and ran `rm -rf` on prod" failures that we don't think the convenience is worth right now.

**Tools are being designed.** A scoped set of agent-facing capabilities is on the roadmap so the agent can do useful remote work without ever holding credentials or initiating a connection itself:

- "Run command in the *currently active* SSH session" — gated by per-command approval (same `commandApprovalKey` model the local `RUN_CMD` tool already uses), session selected by the user in the Remote pane, never by the agent.
- "Read remote file via the active session's SFTP channel" — read-only, size-capped, uses the user's already-authenticated connection.
- "Write to a remote-mirror buffer the user has open" — equivalent to the agent editing a local file the user opened; goes through the same `EDIT_FILE` / `MULTI_EDIT` approval surface; the user's existing edit-on-save flow handles the remote upload.

What is explicitly NOT on the roadmap:

- Agent-initiated `connect` to a vaulted host without user action.
- Agent access to passwords, passphrases, key files, or key material of any kind.
- Agent ability to modify the vault (add / remove / re-key hosts).

If you want to give the agent remote reach today, the supported pattern is: connect manually in the Remote pane, run the commands you want manually, copy outputs into chat as you would from any other terminal. The roadmap items above will narrow that gap incrementally — each one will land behind a tool toggle in Settings → Tools, default-off, with an approval card on first invocation. Track progress in the SSH section of `.agents/knowledgebase.md`.

## Notes

This repository is private while Lumen is under active development. Some integrations require local services or API keys and will degrade gracefully when unavailable.
