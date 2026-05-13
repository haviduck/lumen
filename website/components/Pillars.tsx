// A tight three-pillar section that sits between Hero and Features.
// Sets the "why this exists" tone before the feature grid lists what it has.

const PILLARS = [
  {
    label: "One window",
    title: "Stop alt-tabbing.",
    body:
      "Editor, terminal, SSH, agent chat, Teams, YouTube, Twitch — docked in the same window. Workspace-scoped tab state means closing and reopening lands you where you were.",
  },
  {
    label: "Real BYO model",
    title: "Local or cloud, your call.",
    body:
      "Free Ollama on your box, or Claude / Gemini / Copilot / any OpenAI-compatible endpoint. Per-tool approvals are persisted per-command, so you approve pip install once.",
  },
  {
    label: "Persistent memory",
    title: "Six-month projects, no re-explaining.",
    body:
      "Workspace skills, rules, and a knowledgebase that auto-injects into every prompt. Plus a file timeline so the question \"go back to before the agent broke this\" has a one-click answer.",
  },
];

export function Pillars() {
  return (
    <section className="section-y hairline-t bg-bg-deeper/30">
      <div className="page-x grid gap-10 lg:grid-cols-3">
        {PILLARS.map((p) => (
          <div key={p.label} className="flex flex-col gap-3">
            <span className="eyebrow">{p.label}</span>
            <h3 className="text-h3 font-semibold text-fg">{p.title}</h3>
            <p className="text-fg-muted leading-relaxed">{p.body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
