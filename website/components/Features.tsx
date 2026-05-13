type Feature = {
  title: string;
  description: string;
  tag: string;
  // Tailwind colour token; one of the Nord-y accents.
  accent: "cyan" | "mint" | "purple" | "duck";
};

const FEATURES: Feature[] = [
  {
    tag: "Editor",
    title: "Multi-tab editor with live agent diffs",
    description:
      "Syntax highlighting, markdown preview, drag/drop file moves, Git ignore badges. Files mutated by the agent get inline accept/revoke decorations so you can stage changes turn-by-turn before they hit disk.",
    accent: "cyan",
  },
  {
    tag: "Agent chat",
    title: "Bring your own model",
    description:
      "Ollama (local, free), Ollama Cloud, Anthropic, Gemini, GitHub Copilot via the CLI, and any OpenAI-compatible endpoint. Chip-based file refs, image paste, prompt queueing, per-tool approval that remembers your answer.",
    accent: "mint",
  },
  {
    tag: "Council mode",
    title: "Multi-agent orchestrated deep work",
    description:
      "Brief in, team out. Architect, researcher, tester, reviewer run through Discovery → Architecture → Build → Review → Polish/Ship phases with a quality gate and a one-shot adversarial critic at the end. Sessions are persisted and browsable.",
    accent: "purple",
  },
  {
    tag: "SSH + Remote",
    title: "Vaulted hosts, SFTP, remote-edit-on-save",
    description:
      "Real SSH layer, not a plugin. Secrets in OS keystore (DPAPI / Keychain / libsecret). xterm-based remote terminal with OSC-7 cwd tracking. Drag-drop SFTP upload from anywhere — including WinRAR / Gmail web drags. Hard-walled from the agent by default.",
    accent: "cyan",
  },
  {
    tag: "Side panes",
    title: "Teams, YouTube, Twitch, GitHub — docked",
    description:
      "Webviews for the things you'd otherwise alt-tab to. Work chat next to the editor. Workspace-scoped tab state so video keeps playing through SSH sessions. Yes it's chromium-on-chromium, no it's not slower than alt-tabbing.",
    accent: "duck",
  },
  {
    tag: "Workspace memory",
    title: "Skills, rules, and a knowledgebase",
    description:
      "Every workspace gets a .lumen/ and .agents/ folder. Skills the agent can call, project rules silently injected into every system prompt, and a knowledgebase auto-injected on every turn so a six-month project doesn't restart from zero each chat.",
    accent: "mint",
  },
  {
    tag: "Timeline",
    title: "Revision history for every file change",
    description:
      "Content-addressed blob store plus an append-only journal under <app-support>/lumen/timeline/. Captures agent edits, manual saves, external tool writes, explorer renames. Diff against any past version, restore in one click. \"Go back to before the agent broke this\" works.",
    accent: "purple",
  },
  {
    tag: "Auto-update",
    title: "Quiet, SHA-256-verified, opt-in friendly",
    description:
      "Polls GitHub Releases once per 12h, surfaces an \"Update available\" pill in the menu bar. One click downloads the next installer, closes via Restart Manager, runs silent install, reopens. Force-check from Help → Check for Updates.",
    accent: "cyan",
  },
];

const ACCENT_CLASS: Record<Feature["accent"], string> = {
  cyan: "text-accent-cyan border-accent-cyan/40",
  mint: "text-accent-mint border-accent-mint/40",
  purple: "text-accent-purple border-accent-purple/40",
  duck: "text-accent-duck border-accent-duck/40",
};

export function Features() {
  return (
    <section id="features" className="section-y hairline-t">
      <div className="page-x">
        <div className="flex flex-col gap-3 max-w-2xl">
          <span className="eyebrow">What{"\u2019"}s in the box</span>
          <h2 className="text-h2 font-semibold text-fg">
            Built for the IDE you{"\u2019"}d actually keep open all day.
          </h2>
          <p className="text-fg-muted">
            Every feature exists because alt-tabbing got annoying enough to fix.
            Nothing here is a marketing checkbox.
          </p>
        </div>

        <div className="mt-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map((f) => (
            <article
              key={f.title}
              className="group relative rounded-xl border border-edge-hi bg-bg-raised/40 p-6 hover:bg-bg-raised/60 hover:border-edge-hi/80 transition-colors"
            >
              <span
                className={`inline-flex items-center gap-1.5 rounded-full border bg-bg-deeper/60 px-2.5 py-1 font-mono text-[11px] uppercase tracking-[0.16em] ${ACCENT_CLASS[f.accent]}`}
              >
                {f.tag}
              </span>
              <h3 className="mt-4 text-h3 font-semibold text-fg">{f.title}</h3>
              <p className="mt-2 text-sm text-fg-muted leading-relaxed">
                {f.description}
              </p>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}
