// Process manager showcase — faux process-manager pane on the left, pitch +
// capability bullets on the right. Follows the same template as SshShowcase
// and MemoryShowcase so the page's "deep dive" cadence stays consistent.
//
// The faux pane shows:
//   - Filter chips (All, Node, Python, Java, Workspace, Lumen) with counts
//   - Search box (placeholder only)
//   - Table rows: PID, name, command line excerpt, memory, kill button
//   - One Lumen-spawned row with an expanded descendant
//   - One row in a "kill failed: Access denied" state to make the
//     OS-reason surfacing tangible

import { IconProcess } from "./Icons";

type ChipAccent = "neutral" | "cyan" | "mint" | "purple" | "duck";

type FilterChip = {
  label: string;
  count: number;
  active?: boolean;
  accent: ChipAccent;
};

const CHIPS: FilterChip[] = [
  { label: "All", count: 412, active: true, accent: "neutral" },
  { label: "Node", count: 23, accent: "mint" },
  { label: "Python", count: 9, accent: "cyan" },
  { label: "Java", count: 4, accent: "duck" },
  { label: "Workspace", count: 14, accent: "purple" },
  { label: "Lumen", count: 7, accent: "cyan" },
];

const CHIP_ACTIVE: Record<ChipAccent, string> = {
  neutral: "text-fg border-fg-muted/40 bg-bg-raised/80",
  cyan: "text-accent-cyan border-accent-cyan/40 bg-accent-cyan/10",
  mint: "text-accent-mint border-accent-mint/40 bg-accent-mint/10",
  purple: "text-accent-purple border-accent-purple/40 bg-accent-purple/10",
  duck: "text-accent-duck border-accent-duck/40 bg-accent-duck/10",
};

type ProcRow = {
  pid: number;
  name: string;
  cmd: string;
  mem: string;
  tag?: "lumen" | "workspace" | "node" | "python";
  state?: "killing" | "denied";
  indent?: number;
};

const ROWS: ProcRow[] = [
  {
    pid: 18432,
    name: "node.exe",
    cmd: "node next dev --turbo --port 3000",
    mem: "284 MB",
    tag: "lumen",
  },
  {
    pid: 18560,
    name: "node.exe",
    cmd: "node esbuild-service",
    mem: "62 MB",
    tag: "lumen",
    indent: 1,
  },
  {
    pid: 12044,
    name: "python.exe",
    cmd: "uvicorn app.api:app --reload",
    mem: "156 MB",
    tag: "workspace",
  },
  {
    pid: 9876,
    name: "java.exe",
    cmd: "java -jar gradle-launcher.jar",
    mem: "612 MB",
    state: "killing",
  },
  {
    pid: 4,
    name: "System",
    cmd: "",
    mem: "—",
    state: "denied",
  },
  {
    pid: 22188,
    name: "node.exe",
    cmd: "node vitest --watch",
    mem: "118 MB",
    tag: "node",
  },
];

export function ProcessShowcase() {
  return (
    <section id="processes" className="section-y hairline-t">
      <div className="page-x">
        <div className="grid items-start gap-12 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
          {/* Left: faux Process Manager pane */}
          <ProcessPaneVisual />

          {/* Right: pitch + bullets */}
          <div className="flex flex-col gap-5">
            <div className="flex items-center gap-3">
              <span className="inline-flex size-9 items-center justify-center rounded-md border border-accent-mint/25 bg-accent-mint/10 text-accent-mint">
                <IconProcess size={18} />
              </span>
              <span className="eyebrow">Process manager</span>
            </div>

            <h2 className="text-h2 font-semibold text-fg">
              A task manager that knows your code,{" "}
              <span className="text-fg-muted">not just the kernel.</span>
            </h2>

            <p className="text-fg-muted leading-relaxed">
              Built in, cross-platform, and aware of what Lumen itself
              spawned. When a dev server eats a port at 2am, you don{"\u2019"}t
              alt-tab to Task Manager and squint at PIDs anymore.
            </p>

            <ul className="flex flex-col gap-3 pt-1">
              <Capability
                label="Cross-platform"
                body="PowerShell + Win32_Process on Windows for PID, PPID, and command line. BSD-style ps on macOS/Linux. Same UI on top."
                accent="cyan"
              />
              <Capability
                label="Smart presets"
                body="Filter to Node / Python / Java by what's actually running (matches binaries, package managers, dev servers — node, npm, vite, uvicorn, gunicorn, javaw, mvn, the lot)."
                accent="mint"
              />
              <Capability
                label="Workspace filter"
                body="Show only processes whose command line touches your open workspace folder. Find the dev server that's blocking port 3000 in two clicks."
                accent="purple"
              />
              <Capability
                label="Lumen-spawned"
                body="Tracked accurately, not guessed by name. Every PTY shell and agent tool process Lumen owns is registered. Descendants walked via PPID."
                accent="duck"
              />
              <Capability
                label="Kill with reasons"
                body="taskkill /F on Windows, SIGKILL on Unix. OS errors (Access denied, No such process) shown inline — no silent failures."
                accent="cyan"
              />
            </ul>

            <div className="mt-2 rounded-lg border border-accent-mint/25 bg-accent-mint/5 px-4 py-3">
              <p className="text-xs text-fg-muted leading-relaxed">
                <span className="font-mono uppercase tracking-[0.14em] text-accent-mint">
                  On shutdown
                </span>{" "}
                &mdash; Lumen hard-kills every PID it tracked, so renegade{" "}
                <code className="icode">node</code> /{" "}
                <code className="icode">python</code> grandchildren can{"\u2019"}t
                squat on ports after the IDE closes.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// --- Faux Process Manager pane --------------------------------------------

function ProcessPaneVisual() {
  return (
    <div className="glass rounded-xl overflow-hidden">
      {/* Title bar */}
      <div className="hairline-b flex items-center gap-2 px-4 py-2.5 bg-bg-deepest/50">
        <span className="flex items-center gap-1.5">
          <span className="size-2.5 rounded-full bg-fg-subtle/40" />
          <span className="size-2.5 rounded-full bg-fg-subtle/40" />
          <span className="size-2.5 rounded-full bg-fg-subtle/40" />
        </span>
        <span className="ml-3 font-mono text-xs text-fg-subtle">
          lumen / processes
        </span>
        <span className="ml-auto flex items-center gap-1.5 font-mono text-[11px] text-accent-mint">
          <span className="pulse-dot inline-block size-1.5 rounded-full bg-accent-mint text-accent-mint" />
          auto-refresh · 2s
        </span>
      </div>

      {/* Filter chips + search */}
      <div className="hairline-b px-4 py-3 bg-bg-deeper/40 flex flex-wrap items-center gap-2">
        {CHIPS.map((c) => (
          <ChipBtn key={c.label} chip={c} />
        ))}
        <div className="ml-auto flex items-center gap-1.5 rounded-md border border-edge-hi bg-bg-deepest/60 px-2.5 py-1 min-w-[180px]">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.5" className="text-fg-subtle">
            <circle cx="5" cy="5" r="3.5" />
            <path d="m8 8 2.5 2.5" />
          </svg>
          <span className="font-mono text-[11px] text-fg-subtle">
            search · name, path, cmdline
          </span>
        </div>
      </div>

      {/* Table header */}
      <div className="px-4 py-2 bg-bg-deepest/30 grid grid-cols-[60px_140px_1fr_80px_60px] gap-3 font-mono text-[10.5px] uppercase tracking-[0.14em] text-fg-subtle">
        <span>PID</span>
        <span>Name</span>
        <span>Command</span>
        <span className="text-right">Memory</span>
        <span className="text-right">Kill</span>
      </div>

      {/* Rows */}
      <ul className="bg-bg-deepest/40">
        {ROWS.map((row) => (
          <ProcRowItem key={row.pid} row={row} />
        ))}
      </ul>

      {/* Footer: status strip */}
      <div className="hairline-t px-4 py-2 bg-bg-deeper/40 flex items-center gap-3 font-mono text-[10.5px]">
        <span className="text-fg-subtle">412 processes</span>
        <span className="text-fg-subtle/50">·</span>
        <span className="text-accent-mint">7 spawned by Lumen</span>
        <span className="text-fg-subtle/50">·</span>
        <span className="text-accent-purple">14 in workspace</span>
        <span className="ml-auto text-fg-subtle">last refresh · 142ms</span>
      </div>
    </div>
  );
}

function ChipBtn({ chip }: { chip: FilterChip }) {
  if (chip.active) {
    return (
      <span
        className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 font-mono text-[10.5px] ${CHIP_ACTIVE[chip.accent]}`}
      >
        {chip.label}
        <span className="text-fg-subtle">·</span>
        <span>{chip.count}</span>
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full border border-edge-hi/60 bg-bg-raised/30 px-2.5 py-0.5 font-mono text-[10.5px] text-fg-muted hover:text-fg">
      {chip.label}
      <span className="text-fg-subtle/60">·</span>
      <span className="text-fg-subtle">{chip.count}</span>
    </span>
  );
}

function ProcRowItem({ row }: { row: ProcRow }) {
  const isLumen = row.tag === "lumen";
  const isWorkspace = row.tag === "workspace";
  const isDenied = row.state === "denied";
  const isKilling = row.state === "killing";
  return (
    <li
      className={`px-4 py-1.5 grid grid-cols-[60px_140px_1fr_80px_60px] gap-3 items-center font-mono text-[12px] ${
        isLumen
          ? "bg-accent-cyan/4"
          : isWorkspace
          ? "bg-accent-purple/3"
          : ""
      } hover:bg-bg-raised/40`}
    >
      <span className="text-fg-subtle">{row.pid}</span>
      <span className={`flex items-center gap-1.5 truncate ${isDenied ? "text-fg-subtle" : "text-fg"}`}>
        {row.indent ? <span className="text-fg-subtle/50">└─</span> : null}
        {row.name}
        {isLumen && !row.indent && (
          <span className="ml-1 inline-block size-1.5 rounded-full bg-accent-cyan" title="Lumen-spawned" />
        )}
      </span>
      <span className={`truncate ${isDenied ? "text-fg-subtle italic" : "text-fg-muted"}`}>
        {row.cmd || "—"}
      </span>
      <span className="text-right text-fg-subtle">{row.mem}</span>
      <span className="text-right">
        {isKilling ? (
          <span className="inline-flex items-center gap-1 text-[10px] uppercase tracking-[0.14em] text-accent-duck">
            <span className="inline-block size-2 rounded-full border border-accent-duck/70 border-r-transparent animate-spin" />
            kill
          </span>
        ) : isDenied ? (
          <span className="text-[10px] uppercase tracking-[0.14em] text-accent-duck/90">
            denied
          </span>
        ) : (
          <span className="inline-flex items-center justify-center size-5 rounded border border-edge-hi/60 text-fg-subtle hover:text-fg-muted hover:border-edge-hi">
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1.4">
              <path d="m2 2 6 6M8 2l-6 6" strokeLinecap="round" />
            </svg>
          </span>
        )}
      </span>
    </li>
  );
}

// --- Capability bullet (mirrors SshShowcase) ------------------------------

type CapAccent = "cyan" | "mint" | "purple" | "duck";

const CAP_COLOR: Record<CapAccent, string> = {
  cyan: "text-accent-cyan border-accent-cyan/35 bg-accent-cyan/8",
  mint: "text-accent-mint border-accent-mint/35 bg-accent-mint/8",
  purple: "text-accent-purple border-accent-purple/35 bg-accent-purple/8",
  duck: "text-accent-duck border-accent-duck/35 bg-accent-duck/8",
};

function Capability({
  label,
  body,
  accent,
}: {
  label: string;
  body: string;
  accent: CapAccent;
}) {
  return (
    <li className="flex items-start gap-3">
      <span
        className={`mt-0.5 shrink-0 inline-flex items-center justify-center min-w-[110px] px-2 py-1 rounded border font-mono text-[10.5px] uppercase tracking-[0.14em] ${CAP_COLOR[accent]}`}
      >
        {label}
      </span>
      <span className="text-sm text-fg-muted leading-relaxed">{body}</span>
    </li>
  );
}
