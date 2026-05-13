// Tangible peek at what workspace memory actually looks like.
//
// Renders a faux two-pane editor: file tree on the left, a syntax-tinted
// markdown view of .lumen/rules.md on the right. Way more inviting than
// the usual "stylised icon next to a paragraph" treatment because readers
// can read the actual content and see "oh, that's what they mean."
//
// Syntax tinting is purely cosmetic — no real highlighter dependency.
// Tokens are inline <span>s with accent colour classes.

import { IconMemory } from "./Icons";

type TreeItem =
  | { type: "folder"; name: string; depth: number; open?: boolean }
  | { type: "file"; name: string; depth: number; active?: boolean };

const TREE: TreeItem[] = [
  { type: "folder", name: ".lumen", depth: 0, open: true },
  { type: "folder", name: "skills", depth: 1 },
  { type: "file", name: "rules.md", depth: 1, active: true },
  { type: "folder", name: ".agents", depth: 0, open: true },
  { type: "file", name: "knowledgebase.md", depth: 1 },
  { type: "file", name: "conventions.md", depth: 1 },
  { type: "file", name: "design-system.md", depth: 1 },
  { type: "file", name: "landmines.md", depth: 1 },
  { type: "folder", name: "lib", depth: 0 },
  { type: "folder", name: "services", depth: 0 },
];

export function MemoryShowcase() {
  return (
    <section className="section-y hairline-t">
      <div className="page-x">
        <div className="grid items-center gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.3fr)]">
          {/* Left: the pitch */}
          <div className="flex flex-col gap-5">
            <div className="flex items-center gap-3">
              <span className="inline-flex size-9 items-center justify-center rounded-md border border-accent-mint/25 bg-accent-mint/10 text-accent-mint">
                <IconMemory size={18} />
              </span>
              <span className="eyebrow">Workspace memory</span>
            </div>
            <h2 className="text-h2 font-semibold text-fg">
              Your agents remember the project.
              <br />
              <span className="text-fg-muted">Not just this chat.</span>
            </h2>
            <p className="text-fg-muted leading-relaxed">
              Every workspace gets a{" "}
              <code className="icode">.lumen/</code> and{" "}
              <code className="icode">.agents/</code> folder. Skills the
              agent can call, project rules silently injected into every
              system prompt, a knowledgebase auto-injected on every turn.
            </p>
            <p className="text-fg-muted leading-relaxed">
              A six-month project doesn{"\u2019"}t restart from zero on each
              new chat &mdash; the agent reads what previous sessions
              learned, and is told to keep it current.
            </p>
            <div className="flex flex-wrap gap-2 pt-2">
              <span className="pill !text-accent-mint !border-accent-mint/40">
                Rules
              </span>
              <span className="pill !text-accent-cyan !border-accent-cyan/40">
                Skills
              </span>
              <span className="pill !text-accent-purple !border-accent-purple/40">
                Knowledgebase
              </span>
              <span className="pill !text-accent-duck !border-accent-duck/40">
                Timeline
              </span>
            </div>
          </div>

          {/* Right: faux editor pane */}
          <div className="glass rounded-xl overflow-hidden">
            {/* Title bar */}
            <div className="hairline-b flex items-center gap-2 px-4 py-2.5 bg-bg-deepest/50">
              <span className="flex items-center gap-1.5">
                <span className="size-2.5 rounded-full bg-fg-subtle/40" />
                <span className="size-2.5 rounded-full bg-fg-subtle/40" />
                <span className="size-2.5 rounded-full bg-fg-subtle/40" />
              </span>
              <span className="ml-3 font-mono text-xs text-fg-subtle">
                lumen — workspace
              </span>
              <span className="ml-auto font-mono text-[11px] text-fg-subtle">
                .lumen/rules.md
              </span>
            </div>

            <div className="grid grid-cols-[170px_minmax(0,1fr)] min-h-[340px]">
              {/* File tree */}
              <div className="hairline-b border-r border-edge-hi bg-bg-deeper/60 py-3 text-[12.5px]">
                {TREE.map((node, idx) => (
                  <TreeRow key={idx} node={node} />
                ))}
              </div>

              {/* Editor body — fake markdown with light syntax tinting */}
              <div className="relative bg-bg-deepest/40 font-mono text-[12.5px] leading-relaxed">
                {/* Gutter */}
                <div className="absolute inset-y-0 left-0 w-10 border-r border-edge-hi bg-bg-deeper/30 text-right text-fg-subtle/70 select-none">
                  {Array.from({ length: 14 }, (_, i) => (
                    <div key={i} className="pr-2 pt-[2px]">
                      {i + 1}
                    </div>
                  ))}
                </div>
                <div className="pl-14 pr-4 py-2 text-fg/85">
                  <Line>
                    <Heading>## Project conventions</Heading>
                  </Line>
                  <Line />
                  <Line>
                    Always run{" "}
                    <Code>flutter analyze</Code> after agent edits.
                  </Line>
                  <Line>
                    UI strings live in{" "}
                    <Path>lib/l10n/strings.dart</Path> — never inline.
                  </Line>
                  <Line>
                    Don{"\u2019"}t use emojis in user-visible copy.
                  </Line>
                  <Line />
                  <Line>
                    <Heading>## Knowledgebase</Heading>
                  </Line>
                  <Line />
                  <Line>
                    <Comment>
                      &lt;!-- Auto-injected into every system prompt. --&gt;
                    </Comment>
                  </Line>
                  <Line>
                    Read{" "}
                    <Path>.agents/knowledgebase.md</Path> at chat start.
                  </Line>
                  <Line>
                    Update it after non-trivial work so the next session
                    starts informed.
                  </Line>
                  <Line />
                  <Line>
                    <Heading>## Landmines</Heading>
                  </Line>
                  <Line>
                    Don{"\u2019"}t re-introduce <Code>showMenu</Code>{" "}
                    pickers for chat models{" "}
                    <Comment>
                      // collapses past ~10 models
                    </Comment>
                  </Line>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// Tree row — renders folder/file with depth-based indent.
function TreeRow({ node }: { node: TreeItem }) {
  const indent = 10 + node.depth * 14;
  const isActive = node.type === "file" && node.active;
  return (
    <div
      className={`flex items-center gap-1.5 px-2 py-[3px] font-mono ${
        isActive
          ? "bg-accent-mint/10 text-accent-mint"
          : "text-fg-muted hover:text-fg"
      }`}
      style={{ paddingLeft: indent }}
    >
      {node.type === "folder" ? (
        <FolderGlyph open={node.open ?? false} />
      ) : (
        <FileGlyph />
      )}
      <span className="truncate">{node.name}</span>
    </div>
  );
}

function FolderGlyph({ open }: { open: boolean }) {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" className="text-fg-subtle" aria-hidden>
      {open ? (
        <path
          d="M1.5 3 L4 3 L5 4 L10.5 4 L10.5 9.5 L1.5 9.5 Z"
          fill="currentColor"
          opacity="0.55"
        />
      ) : (
        <path
          d="M1.5 3 L4 3 L5 4 L10.5 4 L10.5 9.5 L1.5 9.5 Z"
          stroke="currentColor"
          fill="none"
          strokeWidth="1"
        />
      )}
    </svg>
  );
}

function FileGlyph() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" className="text-fg-subtle" aria-hidden>
      <path
        d="M3 1.5 L7.5 1.5 L9.5 3.5 L9.5 10.5 L3 10.5 Z"
        stroke="currentColor"
        fill="none"
        strokeWidth="1"
      />
      <path d="M7.5 1.5 L7.5 3.5 L9.5 3.5" stroke="currentColor" fill="none" strokeWidth="1" />
    </svg>
  );
}

// Inline token spans. Pure cosmetic syntax tint.
function Line({ children }: { children?: React.ReactNode }) {
  return <div className="min-h-[1.5em]">{children}</div>;
}
function Heading({ children }: { children: React.ReactNode }) {
  return <span className="text-accent-cyan">{children}</span>;
}
function Code({ children }: { children: React.ReactNode }) {
  return (
    <span className="text-accent-mint bg-accent-mint/10 px-1 rounded">
      {children}
    </span>
  );
}
function Path({ children }: { children: React.ReactNode }) {
  return <span className="text-accent-purple">{children}</span>;
}
function Comment({ children }: { children: React.ReactNode }) {
  return <span className="text-fg-subtle italic">{children}</span>;
}
