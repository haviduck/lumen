import type { Metadata } from "next";
import Link from "next/link";
import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";
import { PRODUCT } from "@/lib/product";

export const metadata: Metadata = {
  title: "Docs",
  description:
    "How to install Lumen, configure providers, use Council mode, set up SSH, and bring the workspace knowledgebase to life.",
};

const SECTIONS: { id: string; label: string }[] = [
  { id: "install", label: "Install" },
  { id: "first-run", label: "First run" },
  { id: "providers", label: "Providers" },
  { id: "chat", label: "Chat & tools" },
  { id: "council", label: "Council mode" },
  { id: "ssh", label: "SSH & remote" },
  { id: "side-panes", label: "Side panes" },
  { id: "knowledgebase", label: "Skills, rules, KB" },
  { id: "timeline", label: "Timeline" },
  { id: "updates", label: "Updates" },
  { id: "build", label: "Build from source" },
  { id: "support", label: "Get help" },
];

export default function DocsPage() {
  return (
    <>
      <Nav />
      <main className="page-x pt-12 pb-24">
        <header className="flex flex-col gap-3 max-w-2xl">
          <span className="eyebrow">Docs</span>
          <h1 className="text-h2 font-semibold text-fg">
            How to actually use Lumen.
          </h1>
          <p className="text-fg-muted">
            Short, opinionated, no marketing. If anything here is wrong, file
            an issue on{" "}
            <Link
              href={PRODUCT.issues}
              target="_blank"
              rel="noreferrer"
              className="text-accent-cyan underline decoration-accent-cyan/30 underline-offset-4 hover:decoration-accent-cyan"
            >
              GitHub
            </Link>
            .
          </p>
        </header>

        <div className="mt-12 grid gap-10 lg:grid-cols-[200px_minmax(0,1fr)]">
          <aside className="hidden lg:block">
            <nav className="sticky top-24 flex flex-col gap-1 text-sm">
              <span className="eyebrow mb-2">On this page</span>
              {SECTIONS.map((s) => (
                <a
                  key={s.id}
                  href={`#${s.id}`}
                  className="px-2 py-1.5 rounded-md text-fg-muted hover:text-fg hover:bg-bg-raised/60 transition-colors"
                >
                  {s.label}
                </a>
              ))}
            </nav>
          </aside>

          <article className="prose-lumen">
            <h2 id="install">Install</h2>
            <p>
              Windows is the supported platform today. Grab either build from
              the <Link href={PRODUCT.releases} target="_blank" rel="noreferrer">releases page</Link>.
            </p>
            <ol>
              <li>
                <strong>Installer (recommended).</strong> Download{" "}
                <code>Lumen-Setup-vX.Y.Z.exe</code>. SmartScreen will warn —
                Lumen isn{"\u2019"}t code-signed yet. Click{" "}
                <em>More info → Run anyway</em>. Installs per-user at{" "}
                <code>%LOCALAPPDATA%\Programs\Lumen\</code>. No admin needed,
                clean uninstall via Apps &amp; Features.
              </li>
              <li>
                <strong>Portable zip.</strong> Download{" "}
                <code>lumen-vX.Y.Z-windows-x64.zip</code>, extract, run{" "}
                <code>lumen.exe</code>. No auto-update — you grab the next zip
                manually.
              </li>
            </ol>

            <h2 id="first-run">First run</h2>
            <p>
              On first launch a wizard walks you through picking at least one
              LLM provider — Ollama if you want local and free, or any of the
              cloud ones. You can skip it and configure later from{" "}
              <em>Help → Setup Wizard…</em> or Settings.
            </p>
            <p>
              At least one provider has to be configured for chat, chat
              summaries, and skill generation to work. Everything else —
              editor, file explorer, terminal, SSH, Teams, YouTube — runs fine
              without any LLM.
            </p>

            <h2 id="providers">Providers</h2>
            <p>Lumen talks to:</p>
            <ul>
              <li>
                <strong>Ollama</strong> — local, no API key, free. If the
                daemon isn{"\u2019"}t running, a banner shows up above the
                composer with a one-click <em>open setup</em> button. No silent
                failures.
              </li>
              <li>
                <strong>Ollama Cloud</strong> — same protocol, hosted.
              </li>
              <li>
                <strong>Anthropic</strong> (Claude) — paste your API key.
              </li>
              <li>
                <strong>Gemini</strong> — Google AI Studio API key.
              </li>
              <li>
                <strong>GitHub Copilot</strong> — uses your existing
                subscription via the Copilot CLI. Sign in once.
              </li>
              <li>
                <strong>OpenAI-compatible</strong> — any endpoint matching the
                OpenAI chat-completions schema. xAI, Mistral, Together, local
                gateways, etc.
              </li>
            </ul>
            <p>
              You can have multiple providers configured simultaneously and
              switch models per-chat from the composer.
            </p>

            <h2 id="chat">Chat &amp; tools</h2>
            <p>
              The composer has chip-based file and folder references, image
              attachments (clipboard paste works), prompt queueing, and
              per-tool approval. Tool approvals are persisted per-command so
              you only approve <code>pip install</code> once.
            </p>
            <p>
              Files mutated by the agent get inline accept/revoke decorations
              in the editor — so you can stage changes turn-by-turn before
              they hit disk as final.
            </p>

            <h2 id="council">Council mode</h2>
            <p>
              Multi-agent orchestrated deep work. You give it a brief, it
              builds a team (architect, researcher, tester, reviewer, etc.),
              assigns roles, and runs them through Discovery → Architecture →
              Build → Review → Polish/Ship phases with a quality gate and a
              one-shot adversarial critic at the end.
            </p>
            <p>
              The visual layer is theatrical — bobbing cards, sweep gradients,
              mention tethers, return packets on <code>done</code> — but the
              orchestration is real. Every agent has its own model, system
              prompt, tool budget, and the orchestrator routes mentions and
              subtasks through a shared blackboard.
            </p>
            <p>
              Sessions persist. Open the Council pane → recent sessions to
              replay or branch off an earlier run.
            </p>

            <h2 id="ssh">SSH &amp; Remote</h2>
            <p>
              A proper SSH layer baked into the IDE, not a plugin.
            </p>
            <ul>
              <li>
                <strong>Vault.</strong> Hosts stored in a two-tier vault: labels,
                addresses, fingerprints, and key paths in fast cold-read
                storage; passwords and key passphrases in the OS keystore
                (DPAPI on Windows). Nothing in a plaintext <code>.json</code>{" "}
                you{"\u2019"}ll forget about.
              </li>
              <li>
                <strong>Terminal pane.</strong> xterm-based session with OSC-7
                cwd tracking. On-connect helper install drops{" "}
                <code>lumen-edit</code>, <code>lumen-grab</code>, and OSC-7 glue
                so the IDE knows where you are remotely.
              </li>
              <li>
                <strong>SFTP browser.</strong> Modal browser that walks the
                remote filesystem from your OSC-7 cwd. Breadcrumbs, hidden-file
                toggle, direct-open into the editor.
              </li>
              <li>
                <strong>Drag-and-drop upload.</strong> Drop a local file onto
                the Remote pane and it uploads via SFTP on the active session.
                Virtual drags from WinRAR, 7-Zip, and Gmail web work.
              </li>
              <li>
                <strong>Remote-edit-on-save.</strong> Open a remote file via
                the browser, edit it locally, hit <code>Ctrl+S</code>. The diff
                is pushed back over the existing SFTP channel.
              </li>
            </ul>
            <blockquote>
              By design, the agent has no access to the SSH layer. It can{"\u2019"}t
              see your hosts, read keys, open sessions, or run remote
              commands. This is a security choice. See the SSH section in the
              repo{"\u2019"}s README for what is and isn{"\u2019"}t on the
              roadmap.
            </blockquote>

            <h2 id="side-panes">Side panes (Teams / YouTube / Twitch / GitHub)</h2>
            <p>
              The right-side dock hosts webviews:
            </p>
            <ul>
              <li>
                <strong>Microsoft Teams</strong> — sign-in works, channels,
                chats, calls. Keep work chat docked next to the editor.
              </li>
              <li>
                <strong>YouTube</strong> — embedded player with workspace-scoped
                tab state. Auto-routes to the chat pane when SSH or Teams is
                using the main side slot.
              </li>
              <li>
                <strong>Twitch</strong> — same treatment.
              </li>
              <li>
                <strong>GitHub</strong> — for casual browsing without leaving
                the IDE.
              </li>
            </ul>

            <h2 id="knowledgebase">Workspace skills, rules &amp; knowledgebase</h2>
            <p>
              Every workspace gets a <code>.lumen/</code> and{" "}
              <code>.agents/</code> folder of LLM-facing context:
            </p>
            <ul>
              <li>
                <code>.lumen/skills/</code> — reusable skill files the agent can
                call. Skills can be auto-generated from your project{"\u2019"}s
                README on first run if you opt in.
              </li>
              <li>
                <code>.lumen/rules.md</code> — silently injected into every
                system prompt at workspace + global scope. Use it for project
                conventions: <em>{"\""}always run flutter analyze after edits{"\""}</em>,
                <em>{"\""}the API folder is in services/, not lib/{"\""}</em>.
              </li>
              <li>
                <code>.agents/knowledgebase.md</code> — the workspace
                knowledgebase, surfaced as a synthetic editor tab
                (<em>Knowledge Base</em> in the open-files row). Persistent
                memory between chats. Auto-injected into the system prompt on
                every turn. Auto-summarize button if it grows too large.
              </li>
            </ul>
            <p>
              The trio together is what makes a long-running agent project
              survivable — you don{"\u2019"}t have to re-explain your codebase
              every chat.
            </p>

            <h2 id="timeline">File timeline (revision history)</h2>
            <p>
              Every meaningful file mutation goes into a content-addressed blob
              store + append-only journal under{" "}
              <code>{"<app-support>"}/lumen/timeline/{"<workspace>"}/</code>. That
              includes:
            </p>
            <ul>
              <li>
                Agent tool ops — every <code>EDIT_FILE</code>,{" "}
                <code>MULTI_EDIT</code>, <code>WRITE_FILE</code>, with{" "}
                <code>(sessionId, turnId, messageId)</code> correlation IDs.
              </li>
              <li>Manual saves (your <code>Ctrl+S</code> writes).</li>
              <li>
                External FS writes (files changed by other tools while Lumen is
                running).
              </li>
              <li>Explorer actions — rename, move, delete via the file tree.</li>
            </ul>
            <p>
              Scroll the Timeline rail, diff against any past version, restore
              in one click. Because every entry carries the agent correlation
              IDs, <em>{"\""}go back to before the agent broke this{"\""}</em>{" "}
              is one click.
            </p>

            <h2 id="updates">Updates</h2>
            <p>
              Lumen polls GitHub Releases once per 12 hours, surfaces an{" "}
              <em>Update available</em> pill in the menu bar when there{"\u2019"}s
              something new. On click it downloads the next installer to{" "}
              <code>%TEMP%</code>, closes itself via Restart Manager, runs the
              silent installer, and reopens. SHA-256 verified if the release
              asset carries a digest.
            </p>
            <p>
              Force a check from <em>Help → Check for Updates</em>. The
              portable zip does not auto-update — you grab the next zip
              manually.
            </p>

            <h2 id="build">Build from source</h2>
            <p>
              Requirements: Flutter SDK, Visual Studio Build Tools with the C++
              workload, Inno Setup 6 or 7 if you want the installer.{" "}
              <code>flutter doctor</code> will tell you what{"\u2019"}s missing.
            </p>
            <pre>
              <code>{`git clone https://github.com/haviduck/lumen.git
cd lumen
flutter pub get
flutter run -d windows`}</code>
            </pre>
            <p>Release build:</p>
            <pre>
              <code>flutter build windows --release</code>
            </pre>
            <p>Installer build:</p>
            <pre>
              <code>{`.\\tools\\installer\\build.ps1`}</code>
            </pre>
            <p>
              Outputs <code>dist\Lumen-Setup-vX.Y.Z.exe</code> and{" "}
              <code>dist\lumen-vX.Y.Z-windows-x64.zip</code>. The installer name
              is regex-matched by the auto-updater — don{"\u2019"}t rename it.
            </p>

            <h2 id="support">Get help</h2>
            <p>
              Lumen is a solo project. The best path for anything broken is a
              GitHub issue with steps to reproduce — bug reports are gold.
            </p>
            <ul>
              <li>
                <Link href={PRODUCT.issues} target="_blank" rel="noreferrer">
                  File an issue
                </Link>
              </li>
              <li>
                <Link href={PRODUCT.github} target="_blank" rel="noreferrer">
                  Browse the source
                </Link>
              </li>
              <li>
                <Link href={PRODUCT.releases} target="_blank" rel="noreferrer">
                  All releases
                </Link>
              </li>
            </ul>
          </article>
        </div>
      </main>
      <Footer />
    </>
  );
}
