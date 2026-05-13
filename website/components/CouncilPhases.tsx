// Council phases — visualises the actual orchestration the Council runs:
// Discovery -> Architecture -> Build -> Review -> Polish/Ship.
//
// Mirrors the phase strip the IDE shows during a Council run (see the
// council-running screenshot). Matching the visual on the website primes
// users for what they'll actually see.

type Phase = {
  num: string;
  name: string;
  desc: string;
  accent: "cyan" | "purple" | "mint" | "duck";
};

const PHASES: Phase[] = [
  {
    num: "01",
    name: "Discovery",
    desc: "Research the brief, surface unknowns, draft questions.",
    accent: "cyan",
  },
  {
    num: "02",
    name: "Architecture",
    desc: "Plan the work. Slice into subtasks. Assign agents.",
    accent: "purple",
  },
  {
    num: "03",
    name: "Build",
    desc: "Agents pull tasks, work in parallel, mention each other.",
    accent: "mint",
  },
  {
    num: "04",
    name: "Review",
    desc: "Quality gate. Subagents inspect each other's output.",
    accent: "duck",
  },
  {
    num: "05",
    name: "Polish / Ship",
    desc: "Adversarial critic, final pass, deliverable handed back.",
    accent: "cyan",
  },
];

const COLOR: Record<Phase["accent"], { dot: string; text: string; rule: string; ring: string }> = {
  cyan: {
    dot: "bg-accent-cyan",
    text: "text-accent-cyan",
    rule: "bg-accent-cyan/60",
    ring: "ring-accent-cyan/30",
  },
  purple: {
    dot: "bg-accent-purple",
    text: "text-accent-purple",
    rule: "bg-accent-purple/60",
    ring: "ring-accent-purple/30",
  },
  mint: {
    dot: "bg-accent-mint",
    text: "text-accent-mint",
    rule: "bg-accent-mint/60",
    ring: "ring-accent-mint/30",
  },
  duck: {
    dot: "bg-accent-duck",
    text: "text-accent-duck",
    rule: "bg-accent-duck/60",
    ring: "ring-accent-duck/30",
  },
};

export function CouncilPhases() {
  return (
    <section className="section-y hairline-t">
      <div className="page-x">
        <div className="flex flex-col gap-3 max-w-2xl">
          <span className="eyebrow">Council mode · phases</span>
          <h2 className="text-h2 font-semibold text-fg">
            Brief in, team out.
            <br />
            <span className="text-fg-muted">Five real phases, one shared blackboard.</span>
          </h2>
          <p className="text-fg-muted">
            The phase strip you see during a Council run isn{"\u2019"}t a
            progress bar &mdash; each phase runs distinct agent roles, with
            its own quality gate before advancing.
          </p>
        </div>

        {/* Flow strip — horizontal on lg, stacked on mobile */}
        <ol className="mt-12 grid gap-4 lg:grid-cols-5 lg:gap-3">
          {PHASES.map((phase, idx) => (
            <li
              key={phase.num}
              className="group relative rounded-xl border border-edge-hi bg-bg-raised/40 p-5 transition-colors hover:bg-bg-raised/60"
            >
              {/* Phase number + accent dot */}
              <div className="flex items-center justify-between gap-2">
                <span className={`font-mono text-xs ${COLOR[phase.accent].text}`}>
                  {phase.num}
                </span>
                <span
                  className={`inline-block size-2 rounded-full ${COLOR[phase.accent].dot} ring-2 ring-inset ${COLOR[phase.accent].ring}`}
                />
              </div>

              {/* Accent rule under the number */}
              <span
                className={`mt-3 block h-px w-10 transition-all duration-300 group-hover:w-16 ${COLOR[phase.accent].rule}`}
                aria-hidden
              />

              <h3 className="mt-3 text-sm font-semibold text-fg">{phase.name}</h3>
              <p className="mt-1.5 text-xs text-fg-muted leading-relaxed">
                {phase.desc}
              </p>

              {/* Connector chevron — only between phases on lg+ */}
              {idx < PHASES.length - 1 && (
                <span
                  className="hidden lg:block absolute top-1/2 -right-3 -translate-y-1/2 text-fg-subtle/60"
                  aria-hidden
                >
                  <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                    <path
                      d="M4 2 L9 7 L4 12"
                      stroke="currentColor"
                      strokeWidth="1.5"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </span>
              )}
            </li>
          ))}
        </ol>

        <div className="mt-8 flex flex-wrap items-center justify-center gap-x-5 gap-y-2 text-xs text-fg-subtle">
          <span className="font-mono uppercase tracking-[0.14em]">
            + Adversarial critic
          </span>
          <span className="text-fg-subtle/50">·</span>
          <span className="font-mono uppercase tracking-[0.14em]">
            Per-agent model + tool budget
          </span>
          <span className="text-fg-subtle/50">·</span>
          <span className="font-mono uppercase tracking-[0.14em]">
            Sessions persisted
          </span>
        </div>
      </div>
    </section>
  );
}
