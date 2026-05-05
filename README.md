# Lumen

Lumen is a desktop IDE built with Flutter. It combines a code editor, file explorer, terminal, project tools, and an agentic chat interface in one workspace.

The project is currently focused on Windows desktop development, with Flutter platform scaffolding present for other desktop/mobile targets.

## Features

- Multi-tab code editor with syntax highlighting, line numbers, markdown preview, word wrap, themes, and file language detection.
- File explorer with context menus, drag/drop moves, copy/cut/paste, undo/redo for explorer operations, Git ignore badges, and file timeline access.
- Integrated terminal with multiple tabs, shell fallback handling, terminal selection actions, and add-to-chat support.
- Agent chat with multiple providers, model management, image attachments, clipboard image paste, file/folder references, prompt queueing, retryable provider errors, and tool approval controls.
- Workspace skills and tools via `.lumen`, plus rules injected into agent prompts.
- File timeline/history for user saves, agent edits, filesystem events, and restore flows.
- Optional integrations for GitNexus, Syncthing, workspace backups, and media playback.

## Grab it from Releases 
[https://github.com/haviduck/lumen/releases](Releases over yonder)

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

## Notes

This repository is private while Lumen is under active development. Some integrations require local services or API keys and will degrade gracefully when unavailable.
