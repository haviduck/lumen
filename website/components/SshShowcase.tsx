// SSH showcase — tangible peek at the four SSH-layer surfaces:
//
//   1. Vaulted hosts (mentioned, lives in the pitch)
//   2. SFTP file browser (the big visual)
//   3. Drag-and-drop SFTP upload (overlaid on the browser)
//   4. On-connect plugin activation (lumen-edit, lumen-grab, OSC-7)
//   5. Remote-edit-on-save (horizontal flow strip below)
//
// Same visual grammar as MemoryShowcase: faux IDE pane on one side,
// pitch + capability bullets on the other. The bottom flow strip
// reuses the cadence of CouncilPhases so the page has a consistent
// "deep dive" template across Memory / SSH / Council.

import { IconSsh } from "./Icons";

type RemoteEntry = {
  type: "up" | "dir" | "file";
  name: string;
  meta?: string;
  badge?: "edited" | "uploading";
  active?: boolean;
};

const REMOTE_ENTRIES: RemoteEntry[] = [
  { type: "up", name: ".." },
  { type: "dir", name: "config/" },
  { type: "dir", name: "src/" },
  { type: "dir", name: "logs/" },
  { type: "file", name: "docker-compose.yml", meta: "2.1 KB", badge: "edited", active: true },
  { type: "file", name: "Dockerfile", meta: "0.8 KB" },
  { type: "file", name: "nginx.conf", meta: "1.4 KB" },
  { type: "file", name: "package.json", meta: "3.0 KB" },
];

const FLOW_STEPS = [
  {
    num: "01",
    title: "Browse",
    body: "Open the SFTP pane. Walks the remote tree from your OSC-7 cwd, with breadcrumbs and a hidden-file toggle.",
    accent: "cyan" as const,
  },
  {
    num: "02",
    title: "Open",
    body: "Click a file. Lumen streams the content into a local editor tab marked as remote-backed.",
    accent: "mint" as const,
  },
  {
    num: "03",
    title: "Edit · Ctrl+S",
    body: "Edit like any local file. On save, Lumen computes the diff against the remote-baseline buffer.",
    accent: "purple" as const,
  },
  {
    num: "04",
    title: "SFTP push back",
    body: "Diff goes over the existing SFTP channel — no re-prompt for credentials, no separate tool.",
    accent: "duck" as const,
  },
];

const FLOW_COLOR: Record<(typeof FLOW_STEPS)[number]["accent"], { text: string; rule: string; ring: string; dot: string }> = {
  cyan: { text: "text-accent-cyan", rule: "bg-accent-cyan/60", ring: "ring-accent-cyan/30", dot: "bg-accent-cyan" },
  mint: { text: "text-accent-mint", rule: "bg-accent-mint/60", ring: "ring-accent-mint/30", dot: "bg-accent-mint" },
  purple: { text: "text-accent-purple", rule: "bg-accent-purple/60", ring: "ring-accent-purple/30", dot: "bg-accent-purple" },
  duck: { text: "text-accent-duck", rule: "bg-accent-duck/60", ring: "ring-accent-duck/30", dot: "bg-accent-duck" },
};

export function SshShowcase() {
  return (
    <section id="ssh" className="section-y hairline-t bg-bg-deeper/30">
      <div className="page-x">
        <div className="grid items-start gap-12 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
          {/* Left: faux Remote pane (the big visual) */}
          <RemotePaneVisual />

          {/* Right: pitch + capability bullets */}
          <div className="flex flex-col gap-5">
            <div className="flex items-center gap-3">
              <span className="inline-flex size-9 items-center justify-center rounded-md border border-accent-cyan/25 bg-accent-cyan/10 text-accent-cyan">
                <IconSsh size={18} />
              </span>
              <span className="eyebrow">SSH + Remote</span>
            </div>

            <h2 className="text-h2 font-semibold text-fg">
              SSH that lives in the IDE.
              <br />
              <span className="text-fg-muted">Not a plugin.</span>
            </h2>

            <p className="text-fg-muted leading-relaxed">
              Real terminal, real SFTP, real vault. The remote pane uses your
              already-authenticated session for everything &mdash; including
              file browsing, drag-drop uploads, and edit-on-save sync.
            </p>

            <ul className="flex flex-col gap-3 pt-1">
              <Capability
                label="Vault"
                body="Passwords & key passphrases in the OS keystore (DPAPI on Windows, Keychain on macOS, libsecret on Linux). Host metadata in fast cold storage."
                accent="cyan"
              />
              <Capability
                label="SFTP browser"
                body="Walks the remote tree from your OSC-7 cwd. Breadcrumbs, hidden-file toggle, direct-open into the editor."
                accent="mint"
              />
              <Capability
                label="Drag-and-drop"
                body="Drop files onto the Remote pane. Virtual drags from WinRAR / 7-Zip / Gmail web all work."
                accent="purple"
              />
              <Capability
                label="Plugin activation"
                body="On connect, Lumen quietly installs lumen-edit, lumen-grab, and OSC-7 cwd glue on the remote shell. The IDE knows where you are."
                accent="duck"
              />
            </ul>

            <div className="mt-2 rounded-lg border border-accent-duck/25 bg-accent-duck/5 px-4 py-3">
              <p className="text-xs text-fg-muted leading-relaxed">
                <span className="font-mono uppercase tracking-[0.14em] text-accent-duck">
                  Boundary
                </span>{" "}
                &mdash; the agent has zero access to this layer. No host
                list, no credentials, no live sessions.
              </p>
            </div>
          </div>
        </div>

        {/* Bottom: remote-edit-on-save flow */}
        <div className="mt-20 pt-12 hairline-t">
          <div className="flex flex-col gap-3 max-w-2xl">
            <span className="eyebrow">Remote-edit-on-save</span>
            <h3 className="text-h2 font-semibold text-fg">
              Edit remote files like they{"\u2019"}re local.
            </h3>
            <p className="text-fg-muted">
              The full cycle uses one authenticated SFTP channel. No second
              login, no temp files, no rsync dance.
            </p>
          </div>

          <ol className="mt-10 grid gap-4 lg:grid-cols-4 lg:gap-3">
            {FLOW_STEPS.map((step, idx) => (
              <li
                key={step.num}
                className="group relative rounded-xl border border-edge-hi bg-bg-raised/40 p-5 transition-colors hover:bg-bg-raised/60"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className={`font-mono text-xs ${FLOW_COLOR[step.accent].text}`}>
                    {step.num}
                  </span>
                  <span
                    className={`inline-block size-2 rounded-full ${FLOW_COLOR[step.accent].dot} ring-2 ring-inset ${FLOW_COLOR[step.accent].ring}`}
                  />
                </div>
                <span
                  className={`mt-3 block h-px w-10 transition-all duration-300 group-hover:w-16 ${FLOW_COLOR[step.accent].rule}`}
                  aria-hidden
                />
                <h4 className="mt-3 text-sm font-semibold text-fg">{step.title}</h4>
                <p className="mt-1.5 text-xs text-fg-muted leading-relaxed">
                  {step.body}
                </p>

                {idx < FLOW_STEPS.length - 1 && (
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
        </div>
      </div>
    </section>
  );
}

// --- Faux Remote pane ------------------------------------------------------

function RemotePaneVisual() {
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
          lumen / remote
        </span>
        <span className="ml-auto flex items-center gap-1.5 font-mono text-[11px] text-accent-cyan">
          <span className="pulse-dot inline-block size-1.5 rounded-full bg-accent-cyan text-accent-cyan" />
          ssh · dev@reports-api
        </span>
      </div>

      {/* On-connect helpers strip — proof of plugin activation */}
      <div className="hairline-b px-4 py-2.5 bg-bg-deeper/40 flex flex-wrap items-center gap-x-3 gap-y-1.5">
        <span className="font-mono text-[10.5px] uppercase tracking-[0.14em] text-fg-subtle">
          helpers installed
        </span>
        <span className="font-mono text-[11px] text-accent-mint">lumen-edit</span>
        <span className="text-fg-subtle/50">·</span>
        <span className="font-mono text-[11px] text-accent-mint">lumen-grab</span>
        <span className="text-fg-subtle/50">·</span>
        <span className="font-mono text-[11px] text-accent-mint">OSC-7 cwd</span>
      </div>

      {/* Breadcrumbs */}
      <div className="hairline-b px-4 py-2 bg-bg-deepest/30 flex items-center gap-2">
        <span className="font-mono text-[11px] text-fg-subtle">/</span>
        <BreadcrumbChip>home</BreadcrumbChip>
        <span className="text-fg-subtle">/</span>
        <BreadcrumbChip>dev</BreadcrumbChip>
        <span className="text-fg-subtle">/</span>
        <BreadcrumbChip active>reports-api</BreadcrumbChip>
        <span className="ml-auto inline-flex items-center gap-1.5 text-[10.5px] font-mono text-fg-subtle">
          <span className="inline-block size-2 rounded-sm border border-edge-hi" />
          hidden
        </span>
      </div>

      {/* Entries */}
      <ul className="bg-bg-deepest/40 py-2 text-[13px]">
        {REMOTE_ENTRIES.map((e) => (
          <RemoteRow key={e.name} entry={e} />
        ))}
      </ul>

      {/* Drag-drop overlay strip */}
      <div className="hairline-t px-4 py-3 bg-accent-purple/8 border-t border-accent-purple/25 flex items-center gap-3">
        <span className="inline-flex size-7 items-center justify-center rounded-md border border-accent-purple/40 bg-accent-purple/10 text-accent-purple">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <path d="M8 2v9" />
            <path d="m4 7 4 4 4-4" />
            <path d="M2.5 13.5h11" />
          </svg>
        </span>
        <div className="flex flex-col gap-0.5 flex-1 min-w-0">
          <span className="text-[12px] text-fg">
            Drop to upload via SFTP
          </span>
          <span className="font-mono text-[10.5px] text-fg-subtle truncate">
            virtual drags from WinRAR · 7-Zip · Gmail web all work
          </span>
        </div>
        <span className="pill !text-accent-purple !border-accent-purple/40 shrink-0">
          1 queued
        </span>
      </div>
    </div>
  );
}

function BreadcrumbChip({
  children,
  active,
}: {
  children: React.ReactNode;
  active?: boolean;
}) {
  return (
    <span
      className={`font-mono text-[11px] px-1.5 py-0.5 rounded ${
        active
          ? "text-accent-cyan bg-accent-cyan/10"
          : "text-fg-muted hover:text-fg"
      }`}
    >
      {children}
    </span>
  );
}

function RemoteRow({ entry }: { entry: RemoteEntry }) {
  const isFolder = entry.type === "dir";
  const isUp = entry.type === "up";
  return (
    <li
      className={`flex items-center gap-3 px-4 py-1.5 font-mono ${
        entry.active ? "bg-accent-cyan/8 text-accent-cyan" : "text-fg-muted hover:text-fg"
      }`}
    >
      <span className="text-fg-subtle">
        {isUp ? <UpGlyph /> : isFolder ? <FolderGlyph /> : <FileGlyph />}
      </span>
      <span className="truncate flex-1">{entry.name}</span>
      {entry.badge === "edited" && (
        <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-accent-cyan">
          remote-edited
        </span>
      )}
      {entry.badge === "uploading" && (
        <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-accent-purple">
          uploading
        </span>
      )}
      {entry.meta && (
        <span className="font-mono text-[10.5px] text-fg-subtle ml-2">
          {entry.meta}
        </span>
      )}
    </li>
  );
}

function UpGlyph() {
  return (
    <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" strokeWidth="1.3" aria-hidden>
      <path d="M6.5 9.5 v-6 m0 0 -3 3 m3 -3 3 3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function FolderGlyph() {
  return (
    <svg width="13" height="13" viewBox="0 0 13 13" aria-hidden>
      <path
        d="M1.5 3.5 L4 3.5 L5 4.5 L11.5 4.5 L11.5 10.5 L1.5 10.5 Z"
        fill="currentColor"
        opacity="0.55"
      />
    </svg>
  );
}

function FileGlyph() {
  return (
    <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" strokeWidth="1" aria-hidden>
      <path d="M3 1.5 L8 1.5 L10.5 4 L10.5 11.5 L3 11.5 Z" />
      <path d="M8 1.5 V4 H10.5" />
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
        className={`mt-0.5 shrink-0 inline-flex items-center justify-center min-w-[88px] px-2 py-1 rounded border font-mono text-[10.5px] uppercase tracking-[0.14em] ${CAP_COLOR[accent]}`}
      >
        {label}
      </span>
      <span className="text-sm text-fg-muted leading-relaxed">{body}</span>
    </li>
  );
}
