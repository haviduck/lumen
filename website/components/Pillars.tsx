// A tight three-pillar section that sits between Hero and Features.
// Sets the "why this exists" tone before the feature grid lists what it has.
//
// Each pillar gets a number, an accent stripe, and a subtle corner mark —
// so the section reads as deliberate rather than three drifting paragraphs.

type Pillar = {
  num: string;
  label: string;
  title: string;
  body: string;
  accent: "cyan" | "purple" | "duck";
};

const PILLARS: Pillar[] = [
  {
    num: "01",
    label: "One window",
    title: "Stop alt-tabbing.",
    body: "Editor, terminal, SSH, agent chat, Teams, YouTube, Twitch — docked in the same window. Workspace-scoped tab state means closing and reopening lands you where you were.",
    accent: "cyan",
  },
  {
    num: "02",
    label: "Real BYO model",
    title: "Local or cloud, your call.",
    body: "Free Ollama on your box, or Claude / Gemini / Copilot / any OpenAI-compatible endpoint. Per-tool approvals are persisted per-command, so you approve pip install once.",
    accent: "purple",
  },
  {
    num: "03",
    label: "Persistent memory",
    title: "Six-month projects, no re-explaining.",
    body: "Workspace skills, rules, and a knowledgebase that auto-injects into every prompt. Plus a file timeline so the question \"go back to before the agent broke this\" has a one-click answer.",
    accent: "duck",
  },
];

const ACCENT: Record<Pillar["accent"], { text: string; rule: string }> = {
  cyan: { text: "text-accent-cyan", rule: "bg-accent-cyan/60" },
  purple: { text: "text-accent-purple", rule: "bg-accent-purple/60" },
  duck: { text: "text-accent-duck", rule: "bg-accent-duck/60" },
};

export function Pillars() {
  return (
    <section className="section-y hairline-t bg-bg-deeper/30">
      <div className="page-x grid gap-10 lg:grid-cols-3">
        {PILLARS.map((p) => (
          <div
            key={p.label}
            className="group relative flex flex-col gap-3 pt-6"
          >
            {/* Top accent rule — short, tinted, fades on hover */}
            <span
              className={`absolute left-0 top-0 h-px w-12 transition-all duration-300 group-hover:w-20 ${ACCENT[p.accent].rule}`}
              aria-hidden
            />

            <div className="flex items-baseline gap-3">
              <span
                className={`font-mono text-xs ${ACCENT[p.accent].text}`}
              >
                {p.num}
              </span>
              <span className="eyebrow">{p.label}</span>
            </div>

            <h3 className="text-h3 font-semibold text-fg">{p.title}</h3>
            <p className="text-fg-muted leading-relaxed">{p.body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
