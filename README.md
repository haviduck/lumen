# Lumen

A desktop IDE for people who can't keep just one window open. Editor, terminal, file explorer, agent chat, SSH, Teams, and YouTube/Twitch — one window, everything where you left it.

Built with Flutter, focused on Windows desktop. Mac/Linux scaffolding is there but i don't ship binaries for them yet.

### [Grab the latest release](https://github.com/haviduck/lumen/releases)

---

## Why this exists

I kept alt-tabbing between Cursor, a terminal, an SSH session, Teams for work chat, and a YouTube/Twitch tab on the second screen. The context-switch tax got annoying enough that i wrote my own thing. Lumen is what came out — an IDE that doesn't pretend the rest of your desktop doesn't exist.

It's also the playground i use to figure out what an agentic IDE actually wants to feel like when the model is wrong half the time and you still need to ship.

## Screenshots

**Council mode** — multi-agent orchestrated work, phase strip across the top, blackboard on the right, each agent has its own card with a step counter and live transcript. Idle ↓

![Council idle](docs/screenshots/council-idle.png)

… and once it's running. Agents pull tasks, work in parallel, post to the blackboard, mention each other:

![Council running](docs/screenshots/council-running.png)

**SSH + editor + a YouTube panel on the right.** Don't pretend you don't do this.

![SSH + YouTube](docs/screenshots/ssh-youtube.png)

**Same but with Teams docked in as well.** Editor on the left, SSH and Teams in the middle column, YouTube on the right. One window.

![Teams + SSH + YouTube](docs/screenshots/teams-ssh-youtube.png)

## What's in the box

### Editor + workspace

Multi-tab editor with syntax highlighting, markdown preview, drag/drop file moves, Git ignore badges, and undo/redo across explorer operations. Files mutated by the agent get inline accept/revoke decorations so you can stage changes turn-by-turn before they hit disk-as-final. See the file timeline section below for the revision-history layer.

### Agent chat

Bring your own model. Lumen talks to:

- **Ollama** (local, no API key, free) and **Ollama Cloud**
- **Anthropic** (Claude)
- **Gemini**
- **GitHub Copilot** (uses your existing Copilot subscription via the CLI)
- Any **OpenAI-compatible** endpoint

The composer has chip-based file/folder references, image attachments + clipboard paste, prompt queueing, and per-tool approval. Tool approvals are persisted per-command so you only approve `pip install` once.

If you pick a local Ollama model and the daemon isn't running, a banner shows up above the composer with a one-click "open setup" button. No silent failures.

### Council mode

Multi-agent orchestrated deep work. You give it a brief, it builds a team (architect, researcher, tester, reviewer, etc.), assigns roles, and runs them through Discovery → Architecture → Build → Review → Polish/Ship phases with a quality gate and a one-shot adversarial critic at the end.

The visual layer is mostly theater (bobbing cards, sweep gradients, mention tethers, return packets on `done`) but the orchestration underneath is real — every agent has its own model, its own system prompt, its own tool budget, and the orchestrator routes mentions and subtasks through a shared blackboard.

Sessions are persisted and browsable after the fact.

### SSH + Remote

A proper SSH layer baked into the IDE, not a plugin.

- **Vault manager.** Hosts stored in a two-tier vault: labels, addresses, fingerprints, and key paths in `SharedPreferences` for fast cold reads; passwords and key passphrases in the OS keystore (DPAPI / Keychain / libsecret via `flutter_secure_storage`). Add, edit, re-key, or wipe hosts from the SSH settings pane. Nothing lives in a plaintext `.json` you'll forget about.
- **Remote pane with a real terminal.** xterm-based session, OSC-7 cwd tracking, on-connect helper install (`lumen-edit`, `lumen-grab`, OSC-7 cwd glue) so the IDE knows where you are remotely.
- **SFTP file browser.** Modal browser that walks the remote filesystem from your OSC-7 cwd (or `$HOME`, or `/`), with breadcrumb nav, hidden-file toggle, and direct-open into the editor. Replaces the old "type a path" dialog as the default entry point. The typed-path flow is still there for power users.
- **Drag-and-drop SFTP upload.** Drop a local file (or a stack of them, including virtual drags from WinRAR / 7-Zip / Gmail web) anywhere on the Remote pane. Lumen reads the file via `super_drag_and_drop`, plans the upload, prompts on conflicts, and pushes via SFTP using the active session's already-authenticated client.
- **Remote-edit-on-save.** Open a remote file via the browser, edit it locally, hit Ctrl+S. Lumen uploads the diff back over the existing SFTP channel. No re-prompt for credentials, no separate tool.

**Note on the agent + SSH boundary:** the agent has no access to your SSH layer today. It can't see your hosts, can't read keys, can't open sessions, can't run remote commands. This is intentional — letting an LLM near production credentials is the kind of decision i don't want to make casually. There's a section further down explaining what's planned and what's explicitly not.

### Teams + YouTube + Twitch (the alt-tab killers)

There's a side pane that hosts:

- **Microsoft Teams** — full webview, sign-in works, channels/chats/calls all there. You can keep work chat docked next to the editor.
- **YouTube** — embedded player with workspace-scoped tab state. Auto-routes to the chat pane when SSH or Teams is currently using the main side slot, so you can always have something playing.
- **Twitch** — same treatment.
- **GitHub** — for casual browsing without leaving the IDE.

Yes it's a chromium-on-chromium pile. No i don't care, it's faster than alt-tabbing.

### Remote control (mobile/web)

There's a PWA shipped under `assets/remote_app/` that runs on phone/tablet and connects back to Lumen over the LAN. You can read chat history, send prompts, and watch the agent work from the couch. Useful when you've kicked off a long council session and want to check in from the kitchen.

### Workspace skills + rules + knowledgebase

Every workspace gets a `.lumen/` and `.agents/` folder of LLM-facing context:

- **`.lumen/skills/`** — reusable skill files the agent can call. Skills can be auto-generated from your project's README on first run if you opt in.
- **`.lumen/rules.md`** — silently injected into every system prompt at workspace + global scope. Use it for project conventions ("always run `flutter analyze` after edits", "the API folder is in `services/`, not `lib/`"). The global rule out of the box already tells agents how the knowledgebase works, so you don't have to write that yourself.
- **`.agents/knowledgebase.md`** — the workspace knowledgebase, surfaced as a synthetic editor tab (`Knowledge Base` in the open-files row). This is the persistent memory layer for the agent: anything it learns in one chat session that future sessions should also know goes here. It's auto-injected into the system prompt on every turn and the agent is instructed (via the global rule) to keep it up to date. Auto-summarize button if it grows too large.

The trio together is what makes a long-running agent project survivable — you don't have to re-explain your codebase every chat.

### File timeline (revision history)

Every meaningful file mutation gets captured into a content-addressed blob store + append-only journal under `<app-support>/lumen/timeline/<workspace>/`. This includes:

- **Agent tool ops** — every `EDIT_FILE` / `MULTI_EDIT` / `WRITE_FILE` the agent runs, with `(sessionId, turnId, messageId)` correlation IDs.
- **Manual saves** — your Ctrl+S writes.
- **External FS writes** — files changed by other tools while Lumen is running.
- **Explorer actions** — rename, move, delete via the file tree.

The Timeline rail lets you scroll back through every version, diff against any previous one, and restore. Because every entry carries the agent correlation IDs, "go back to before the agent broke this" is one click. A future "click a chat message → restore everything since" flow is already wired structurally; the UI just isn't shipped yet.

It's deliberately foolproof — same gzip'd content blob is reused if the file hash already exists, so the journal doesn't bloat from formatter passes that re-save the same bytes.

### Auto-update

Lumen polls the GitHub Releases API once per 12 hours, surfaces an "Update available" pill in the menu bar when there's something new, and on click downloads the next installer to `%TEMP%`, closes itself via Restart Manager, runs the silent installer, and reopens. SHA-256 verified if the release asset carries a digest.

You can force a check from **Help → Check for Updates**.

---

## Install (Windows)

[Releases page](https://github.com/haviduck/lumen/releases).

**Installer (recommended):**
1. Download `Lumen-Setup-vX.Y.Z.exe`.
2. SmartScreen will warn — Lumen isn't code-signed yet. Click **More info → Run anyway**. Reputation builds over time but for now this is the deal.
3. Installs per-user at `%LOCALAPPDATA%\Programs\Lumen\`. No admin / UAC needed. Clean uninstall via Apps & Features.

**Portable zip:** download `lumen-vX.Y.Z-windows-x64.zip`, extract, run `lumen.exe`. No auto-update, you grab the next zip manually.

### First run

On first launch a wizard walks you through picking at least one LLM provider — Ollama if you want local/free, or any of the cloud ones. You can skip and configure later from **Help → Setup Wizard…** or Settings.

At least one provider has to be configured for chat, chat summaries, and skill generation to work. Everything else (editor, file explorer, terminal, SSH, Teams, YouTube) runs fine without any LLM.

---

## Honesty about what's WIP

Lumen is a solo project shipped fast. A few things are exposed in the UI but not fully wired up yet:

- **Some Settings pages are scaffolds.** A handful of sections in Settings (advanced agent tuning, certain provider sub-toggles, theming knobs) render but don't persist or don't propagate to every callsite. If a setting doesn't seem to do anything, that's why. The actively-used ones (chat models, LLM providers, SSH vault, tools, rules, knowledgebase) all work; the WIP ones are mostly under "advanced".
- **macOS / Linux builds** — Flutter compiles, but i don't run platform QA on them. Expect rough edges.
- **Tablet / phone PWA remote** — works for chat read-out and prompt-send today, but it's not a full IDE remote. Editor / file-explorer / terminal aren't piped through.
- **The "restore everything since this chat message" flow** — the timeline captures the correlation IDs (`sessionId`, `turnId`, `messageId`) for every agent edit, but the one-click "revert this whole turn" UI isn't shipped yet. Today you restore per-file via the timeline rail.
- **Code signing** — installer is unsigned, SmartScreen will warn on first download.

If something behaves weird, file an issue and i'll look at it. WIP doesn't mean ignored, it means "the wiring is half-done and i haven't pushed the fix yet."

## I'd love help

Lumen is a one-person project so far and there's a lot of surface area for things to be wrong on. If you spot something, please file an issue — bug reports with steps to reproduce are gold. Feature ideas welcome too.

Specific things i'd appreciate help with:

- **Code signing.** I'd love to drop the SmartScreen warning. If you know the SignPath OSS path or have an extra OV cert lying around, get in touch.
- **macOS and Linux builds.** The Flutter scaffolding is there, i just don't have the cycles to do platform QA across all three. If you run mac or linux and want to try it, PRs welcome.
- **More provider integrations.** OpenAI-compatible covers a lot but there are edges. xAI, Mistral La Plateforme, Together, anything you'd want native handling for.
- **Workspace skills.** The `.lumen/skills/` directory is a fairly new surface, and good shared skills (linters, framework-specific helpers, project bootstrap) would make a big difference.
- **Settings finishing pass.** Half the unmarked WIP toggles in Settings need their persistence and propagation wired through. Boring grunt work but high-value.
- **PWA remote pane parity.** The mobile remote can do chat today; piping the editor / file tree / terminal through over the LAN would be a fun project.
- **Translations.** All UI strings live in `lib/l10n/strings.dart`. Currently English-only.

If you want to dig in, the `.agents/knowledgebase.md` file is the router — it points at every other doc in `.agents/` (design system, conventions, landmines, roadmap). Start there.

---

## Build it yourself

Standard Flutter Windows build:

```powershell
git clone https://github.com/haviduck/lumen.git
cd lumen
flutter pub get
flutter run -d windows
```

Release build:

```powershell
flutter build windows --release
```

Installer build (needs [Inno Setup 6 or 7](https://jrsoftware.org/isdl.php)):

```powershell
.\tools\installer\build.ps1
```

Outputs `dist\Lumen-Setup-vX.Y.Z.exe` + `dist\lumen-vX.Y.Z-windows-x64.zip`. Both get uploaded to the GitHub release — the installer name is regex-matched by the auto-updater, so don't rename it.

Requirements: Flutter SDK, Visual Studio Build Tools with the C++ workload, Inno Setup if you want the installer. `flutter doctor` will tell you what's missing.

---

## SSH + the agent — what it can and cannot do

Lumen ships an SSH integration (vaulted hosts, in-IDE Remote terminal pane, drag-drop SFTP, remote-edit-on-save). When you also use the agent chat, you reasonably want to know how the two interact.

**Today, by design, the agent has no direct access to the SSH layer.** The boundary is hard, not advisory:

- The agent **cannot** read your vaulted host list, fingerprints, passwords, key passphrases, or private key paths. Secrets live in the OS keystore (DPAPI / Keychain / libsecret via `flutter_secure_storage`); host metadata lives in `SharedPreferences`. Neither is exposed to any agent tool.
- The agent **cannot** open, control, or read a live SSH session. Connections are owned by `SshController` and only surfaced to the user-facing Remote pane.
- The agent **cannot** SFTP files, edit remote-mirrored buffers without going through the same approval flow as local edits, or trigger a host-key trust prompt.
- The agent **cannot** see that an SSH session exists. `SshController` is not in the tool registry. As far as the model is concerned, there is no SSH layer.

This is a security choice. SSH credentials and active connections give an attacker arbitrary remote command execution under your identity. Routing an LLM near them — even with approval prompts — opens a class of "the model misread your intent and ran `rm -rf` on prod" failures that i don't think the convenience is worth right now.

**What's on the roadmap** (each will land behind a Settings → Tools toggle, default-off, with an approval card on first invocation):

- "Run command in the *currently active* SSH session" — gated by per-command approval, session selected by you in the Remote pane, never by the agent.
- "Read remote file via the active session's SFTP channel" — read-only, size-capped, uses your already-authenticated connection.
- "Write to a remote-mirror buffer you have open" — equivalent to the agent editing a local file you opened; goes through the same `EDIT_FILE` approval surface.

**Explicitly NOT on the roadmap:**

- Agent-initiated `connect` to a vaulted host.
- Agent access to passwords, passphrases, or key material of any kind.
- Agent modification of the vault.

If you want agent reach over SSH today, the supported pattern is: connect manually in the Remote pane, run the commands you want manually, copy outputs into chat from the terminal. The roadmap items will narrow that gap incrementally.

---

## Project layout

- `lib/` — Flutter app code.
- `lib/providers/` — shared state and controllers.
- `lib/services/` — integrations, persistence, tool execution, workspace services.
- `lib/widgets/` — editor, chat, file explorer, terminal, settings, shared UI.
- `assets/` — bundled application assets (icons, the remote PWA, the ublock-lite extension).
- `windows/`, `linux/`, `macos/`, `android/`, `ios/` — Flutter platform scaffolding.
- `tools/installer/` — Inno Setup script + PowerShell build wrapper.
- `.agents/` — design notes, conventions, landmines, roadmap.

Local runtime data lives in `.lumen/`, `.agents/`, `.dart_tool/`, `build/` — all gitignored.

## Notes

Some integrations (Copilot CLI, Ollama, Teams sign-in) need local services or accounts. Everything degrades gracefully — if a provider isn't configured, its features are hidden, not broken.
