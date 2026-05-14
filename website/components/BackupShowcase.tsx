// Backup showcase — faux backup-settings pane on the left, pitch + bullets
// on the right. Mirrors the SshShowcase / MemoryShowcase / ProcessShowcase
// template so the page's "deep dive" cadence stays consistent.
//
// What gets shown in the pane:
//   - Status pill with last/next run + "saving" pulse state
//   - The interval slider (faux) with min/max labels (5min / 24h)
//   - Two git toggles (auto-commit, auto-push) showing on/off states
//   - A small recent-archives list with timestamps + sizes
//   - An "ignored" footer hint listing a few of the always-ignored dirs
//
// Tone of the pitch: "save scares, gone". Backup as the calm safety net
// alongside Timeline. Backup = archive zip on disk; Timeline = per-file
// revision journal. Both live, both rescue you from different mistakes.

import { IconBackup } from "./Icons";

const RECENT_BACKUPS = [
  { ts: "02:34", size: "12.4 MB", label: "auto", state: "ok" as const },
  { ts: "02:04", size: "12.1 MB", label: "auto", state: "ok" as const },
  { ts: "01:34", size: "12.0 MB", label: "auto", state: "ok" as const },
  { ts: "00:48", size: "11.7 MB", label: "manual", state: "ok" as const },
];

const HARD_IGNORES = [
  "node_modules",
  ".git",
  ".dart_tool",
  "build",
  "dist",
  ".next",
  ".venv",
  "__pycache__",
  "target",
  ".gradle",
];

export function BackupShowcase() {
  return (
    <section id="backup" className="section-y hairline-t bg-bg-deeper/30">
      <div className="page-x">
        <div className="grid items-start gap-12 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
          {/* Left: faux Backup pane */}
          <BackupPaneVisual />

          {/* Right: pitch + bullets */}
          <div className="flex flex-col gap-5">
            <div className="flex items-center gap-3">
              <span className="inline-flex size-9 items-center justify-center rounded-md border border-accent-duck/25 bg-accent-duck/10 text-accent-duck">
                <IconBackup size={18} />
              </span>
              <span className="eyebrow">Backup</span>
            </div>

            <h2 className="text-h2 font-semibold text-fg">
              Save scares,{" "}
              <span className="text-fg-muted">gone.</span>
            </h2>

            <p className="text-fg-muted leading-relaxed">
              The IDE quietly snapshots your workspace to a zip on a schedule
              you set. Optional follow-through to{" "}
              <code className="icode">git add</code> +{" "}
              <code className="icode">commit</code> +{" "}
              <code className="icode">push</code> &mdash; so a forgotten
              push or a bad edit at 3am isn{"\u2019"}t a story you tell later.
            </p>

            <ul className="flex flex-col gap-3 pt-1">
              <Capability
                label="Smart ignore"
                body="Respects your .gitignore plus a hardcoded skip list (node_modules, .git, build, dist, .next, .venv, __pycache__, target, .gradle, etc). Backups stay small even on heavy projects."
                accent="cyan"
              />
              <Capability
                label="Schedulable"
                body="5 minutes to 24 hours, default 30. The timer survives restarts via PreferencesService, and re-checks the active workspace on every fire so switching projects doesn't back up the wrong one."
                accent="mint"
              />
              <Capability
                label="Git follow-through"
                body="Two opt-in toggles: auto-commit (git add . && git commit) and auto-push. Both off by default. Turn them on when you want every snapshot to also land on origin."
                accent="purple"
              />
              <Capability
                label="Local archives"
                body="Zips land in <app-support>/lumen/backups/ as <workspace>_backup_<timestamp>.zip. Easy to grep, easy to restore by unzip-and-diff."
                accent="duck"
              />
            </ul>

            <div className="mt-2 rounded-lg border border-accent-cyan/20 bg-accent-cyan/5 px-4 py-3">
              <p className="text-xs text-fg-muted leading-relaxed">
                <span className="font-mono uppercase tracking-[0.14em] text-accent-cyan">
                  Pairs with Timeline
                </span>{" "}
                &mdash; backup is the full-workspace snapshot, Timeline is
                per-file revision history. Use Timeline to undo a bad edit;
                use Backup to roll back the whole project.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// --- Faux Backup pane ------------------------------------------------------

function BackupPaneVisual() {
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
          lumen / settings / backup
        </span>
        <span className="ml-auto flex items-center gap-1.5 font-mono text-[11px] text-accent-duck">
          <span className="pulse-dot inline-block size-1.5 rounded-full bg-accent-duck text-accent-duck" />
          auto · every 30 min
        </span>
      </div>

      {/* Status strip */}
      <div className="hairline-b px-4 py-3 bg-bg-deeper/40 grid grid-cols-3 gap-3 font-mono text-[11px]">
        <div className="flex flex-col gap-0.5">
          <span className="uppercase tracking-[0.14em] text-fg-subtle text-[10px]">
            last run
          </span>
          <span className="text-fg">02:34 · ok</span>
        </div>
        <div className="flex flex-col gap-0.5">
          <span className="uppercase tracking-[0.14em] text-fg-subtle text-[10px]">
            next run
          </span>
          <span className="text-fg">03:04</span>
        </div>
        <div className="flex flex-col gap-0.5">
          <span className="uppercase tracking-[0.14em] text-fg-subtle text-[10px]">
            total saved
          </span>
          <span className="text-fg">48 archives</span>
        </div>
      </div>

      {/* Interval slider (faux) */}
      <div className="hairline-b px-4 py-4 bg-bg-deepest/30 flex flex-col gap-2">
        <div className="flex items-center justify-between gap-3 font-mono text-[11px]">
          <span className="uppercase tracking-[0.14em] text-fg-subtle text-[10px]">
            Interval
          </span>
          <span className="text-fg">30 min</span>
        </div>
        <div className="relative h-1.5 rounded-full bg-bg-raised/60">
          <span
            className="absolute inset-y-0 left-0 rounded-full bg-gradient-to-r from-accent-duck/60 to-accent-duck"
            style={{ width: "16%" }}
          />
          <span
            className="absolute -top-0.5 size-2.5 rounded-full border border-accent-duck/60 bg-bg-deepest"
            style={{ left: "calc(16% - 5px)" }}
          />
        </div>
        <div className="flex items-center justify-between font-mono text-[10px] text-fg-subtle">
          <span>5 min</span>
          <span>24 h</span>
        </div>
      </div>

      {/* Git toggles */}
      <div className="hairline-b px-4 py-3 bg-bg-deepest/30 flex flex-col gap-2">
        <ToggleRow label="git auto-commit" state="on" detail="after each archive" />
        <ToggleRow label="git auto-push" state="off" detail="manual push only" />
      </div>

      {/* Recent archives list */}
      <div className="px-4 py-3 bg-bg-deepest/40">
        <div className="flex items-center justify-between mb-2 font-mono text-[10.5px]">
          <span className="uppercase tracking-[0.14em] text-fg-subtle">
            recent archives
          </span>
          <span className="text-fg-subtle">workspace · synthetic_data</span>
        </div>
        <ul className="flex flex-col gap-1">
          {RECENT_BACKUPS.map((b) => (
            <li
              key={b.ts}
              className="flex items-center gap-3 font-mono text-[12px] hover:bg-bg-raised/40 px-2 py-1 -mx-2 rounded"
            >
              <ArchiveGlyph />
              <span className="text-fg">synthetic_data_backup_{b.ts.replace(":", "")}.zip</span>
              <span
                className={`ml-auto text-[10px] uppercase tracking-[0.14em] ${
                  b.label === "auto"
                    ? "text-accent-mint"
                    : "text-accent-purple"
                }`}
              >
                {b.label}
              </span>
              <span className="text-fg-subtle w-16 text-right">{b.size}</span>
              <span className="text-fg-subtle w-12 text-right">{b.ts}</span>
            </li>
          ))}
        </ul>
      </div>

      {/* Ignored hint */}
      <div className="hairline-t px-4 py-3 bg-bg-deeper/40 flex items-start gap-3">
        <span className="font-mono text-[10.5px] uppercase tracking-[0.14em] text-fg-subtle shrink-0 mt-0.5">
          ignored
        </span>
        <div className="flex flex-wrap gap-1.5">
          {HARD_IGNORES.map((h) => (
            <span
              key={h}
              className="font-mono text-[10.5px] text-fg-subtle bg-bg-raised/40 border border-edge-hi/40 px-1.5 py-0.5 rounded"
            >
              {h}
            </span>
          ))}
          <span className="font-mono text-[10.5px] text-fg-subtle/70 italic">
            + your .gitignore
          </span>
        </div>
      </div>
    </div>
  );
}

function ToggleRow({
  label,
  state,
  detail,
}: {
  label: string;
  state: "on" | "off";
  detail: string;
}) {
  const isOn = state === "on";
  return (
    <div className="flex items-center gap-3 font-mono text-[11px]">
      <span
        className={`relative inline-flex h-4 w-7 shrink-0 rounded-full transition-colors ${
          isOn ? "bg-accent-mint/40" : "bg-fg-subtle/20"
        }`}
      >
        <span
          className={`absolute top-0.5 size-3 rounded-full bg-bg-deepest border ${
            isOn
              ? "left-3.5 border-accent-mint/70"
              : "left-0.5 border-fg-subtle/40"
          } transition-all`}
        />
      </span>
      <span className="text-fg">{label}</span>
      <span className="text-fg-subtle/80">·</span>
      <span className="text-fg-subtle">{detail}</span>
      <span
        className={`ml-auto text-[10px] uppercase tracking-[0.14em] ${
          isOn ? "text-accent-mint" : "text-fg-subtle"
        }`}
      >
        {state}
      </span>
    </div>
  );
}

function ArchiveGlyph() {
  return (
    <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" strokeWidth="1.2" className="text-fg-subtle" aria-hidden>
      <rect x="1.5" y="3" width="10" height="2.5" rx="0.5" />
      <path d="M2.5 5.5v6h8v-6" />
      <path d="M5.5 7.5h2" />
    </svg>
  );
}

// --- Capability bullet -----------------------------------------------------

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
