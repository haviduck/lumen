// Architecture diagram — shows how Editor, Agent, Workspace Memory, Timeline,
// and the SSH wall fit together. Pure inline SVG, no deps.
//
// Information goals (in priority order):
//   1. The SSH layer is HARD-WALLED from the agent. Visualised as a dotted
//      barrier with a lock glyph.
//   2. Workspace memory (rules + KB + skills) FLOWS INTO every agent prompt.
//   3. Every agent file edit FLOWS INTO the Timeline. Reversible.
//   4. The user composes prompts, approves tools, owns the SSH session.
//
// Layout: 5 nodes around the central "Agent" hub. The SSH wall is on the
// right side, separated by a clearly broken connection.

const NODES = {
  user: { x: 60, y: 240, label: "You" },
  editor: { x: 240, y: 90, label: "Editor" },
  agent: { x: 420, y: 240, label: "Agent" },
  memory: { x: 240, y: 390, label: "Workspace memory" },
  timeline: { x: 600, y: 90, label: "Timeline" },
  ssh: { x: 720, y: 240, label: "SSH layer" },
  files: { x: 600, y: 390, label: "Workspace files" },
} as const;

export function ArchitectureDiagram() {
  return (
    <section className="section-y hairline-t bg-bg-deeper/30">
      <div className="page-x">
        <div className="flex flex-col gap-3 max-w-2xl">
          <span className="eyebrow">How it fits together</span>
          <h2 className="text-h2 font-semibold text-fg">
            One system, a few hard boundaries.
          </h2>
          <p className="text-fg-muted">
            The agent reaches into the editor and the timeline. It does{" "}
            <span className="text-accent-duck">not</span> reach into your SSH
            sessions or vaulted credentials. The wall is drawn at the tool
            registry, not at a prompt boundary.
          </p>
        </div>

        <div className="mt-12 glass rounded-xl overflow-hidden">
          <div className="hairline-b flex items-center gap-2 px-4 py-2.5 bg-bg-deepest/40">
            <span className="flex items-center gap-1.5">
              <span className="size-2.5 rounded-full bg-fg-subtle/40" />
              <span className="size-2.5 rounded-full bg-fg-subtle/40" />
              <span className="size-2.5 rounded-full bg-fg-subtle/40" />
            </span>
            <span className="ml-3 font-mono text-xs text-fg-subtle">
              lumen / system topology
            </span>
            <span className="ml-auto pill !text-fg-subtle">read-only</span>
          </div>

          <div className="p-6 sm:p-10 bg-bg-deepest/40">
            <svg
              viewBox="0 0 820 500"
              className="w-full h-auto max-w-full"
              role="img"
              aria-label="Lumen architecture: the user drives the editor and agent, the agent injects workspace memory into every prompt, all file edits flow to the timeline, and the SSH layer is walled off from agent reach."
            >
              <defs>
                {/* Reusable arrowheads */}
                <marker
                  id="arrow-cyan"
                  viewBox="0 0 10 10"
                  refX="9"
                  refY="5"
                  markerWidth="6"
                  markerHeight="6"
                  orient="auto"
                >
                  <path d="M0,0 L10,5 L0,10 z" fill="#88C0D0" />
                </marker>
                <marker
                  id="arrow-mint"
                  viewBox="0 0 10 10"
                  refX="9"
                  refY="5"
                  markerWidth="6"
                  markerHeight="6"
                  orient="auto"
                >
                  <path d="M0,0 L10,5 L0,10 z" fill="#8FBCBB" />
                </marker>
                <marker
                  id="arrow-purple"
                  viewBox="0 0 10 10"
                  refX="9"
                  refY="5"
                  markerWidth="6"
                  markerHeight="6"
                  orient="auto"
                >
                  <path d="M0,0 L10,5 L0,10 z" fill="#B48EAD" />
                </marker>
                <marker
                  id="arrow-fg"
                  viewBox="0 0 10 10"
                  refX="9"
                  refY="5"
                  markerWidth="6"
                  markerHeight="6"
                  orient="auto"
                >
                  <path d="M0,0 L10,5 L0,10 z" fill="#7B88A1" />
                </marker>
              </defs>

              {/* Connection paths — drawn first so nodes overlay them */}

              {/* User -> Agent (composes prompts, approves tools) */}
              <path
                d={`M ${NODES.user.x + 60} ${NODES.user.y} L ${NODES.agent.x - 60} ${NODES.agent.y}`}
                stroke="#7B88A1"
                strokeWidth="1.5"
                fill="none"
                markerEnd="url(#arrow-fg)"
              />
              <text
                x={(NODES.user.x + NODES.agent.x) / 2}
                y={NODES.user.y - 8}
                fill="#7B88A1"
                fontSize="11"
                fontFamily="ui-monospace, monospace"
                textAnchor="middle"
              >
                prompts · approvals
              </text>

              {/* User -> Editor (you also edit files directly) */}
              <path
                d={`M ${NODES.user.x + 30} ${NODES.user.y - 30} Q ${NODES.user.x + 80} ${NODES.editor.y + 40}, ${NODES.editor.x - 60} ${NODES.editor.y}`}
                stroke="#7B88A1"
                strokeWidth="1.5"
                fill="none"
                markerEnd="url(#arrow-fg)"
              />

              {/* Memory -> Agent (auto-injected on every turn) */}
              <path
                d={`M ${NODES.memory.x + 60} ${NODES.memory.y - 20} Q ${NODES.agent.x - 50} ${NODES.agent.y + 60}, ${NODES.agent.x - 30} ${NODES.agent.y + 30}`}
                stroke="#8FBCBB"
                strokeWidth="1.5"
                fill="none"
                markerEnd="url(#arrow-mint)"
              />
              <text
                x={(NODES.memory.x + NODES.agent.x) / 2}
                y={NODES.memory.y - 10}
                fill="#8FBCBB"
                fontSize="11"
                fontFamily="ui-monospace, monospace"
                textAnchor="middle"
              >
                injected each turn
              </text>

              {/* Agent -> Editor (proposes edits, decorated inline) */}
              <path
                d={`M ${NODES.agent.x - 30} ${NODES.agent.y - 30} Q ${NODES.editor.x + 80} ${NODES.editor.y + 60}, ${NODES.editor.x + 30} ${NODES.editor.y + 30}`}
                stroke="#88C0D0"
                strokeWidth="1.5"
                fill="none"
                markerEnd="url(#arrow-cyan)"
              />
              <text
                x={(NODES.agent.x + NODES.editor.x) / 2}
                y={NODES.editor.y + 90}
                fill="#88C0D0"
                fontSize="11"
                fontFamily="ui-monospace, monospace"
                textAnchor="middle"
              >
                inline diffs
              </text>

              {/* Editor -> Files (your saves + accepted agent edits) */}
              <path
                d={`M ${NODES.editor.x + 60} ${NODES.editor.y + 20} Q ${NODES.files.x - 60} ${NODES.editor.y + 80}, ${NODES.files.x - 50} ${NODES.files.y - 20}`}
                stroke="#7B88A1"
                strokeWidth="1.5"
                fill="none"
                markerEnd="url(#arrow-fg)"
              />

              {/* Files -> Timeline (every mutation captured) */}
              <path
                d={`M ${NODES.files.x} ${NODES.files.y - 40} L ${NODES.timeline.x} ${NODES.timeline.y + 40}`}
                stroke="#B48EAD"
                strokeWidth="1.5"
                fill="none"
                markerEnd="url(#arrow-purple)"
              />
              <text
                x={NODES.files.x + 64}
                y={NODES.files.y - 60}
                fill="#B48EAD"
                fontSize="11"
                fontFamily="ui-monospace, monospace"
                textAnchor="middle"
              >
                journaled
              </text>

              {/* The SSH WALL — dotted barrier */}
              <line
                x1={NODES.ssh.x - 50}
                y1="60"
                x2={NODES.ssh.x - 50}
                y2="440"
                stroke="#EBCB8B"
                strokeWidth="1.5"
                strokeDasharray="4 6"
                opacity="0.7"
              />
              {/* Broken connection from Agent to SSH */}
              <path
                d={`M ${NODES.agent.x + 30} ${NODES.agent.y} L ${NODES.ssh.x - 65} ${NODES.ssh.y}`}
                stroke="#7B88A1"
                strokeWidth="1.2"
                fill="none"
                strokeDasharray="3 3"
                opacity="0.4"
              />
              {/* Strikethrough X on the broken connection */}
              <g
                transform={`translate(${(NODES.agent.x + NODES.ssh.x - 35) / 2 - 8}, ${NODES.ssh.y - 8})`}
              >
                <circle r="9" cx="8" cy="8" fill="#14171D" stroke="#EBCB8B" strokeWidth="1.2" />
                <path
                  d="M3 3 L13 13 M13 3 L3 13"
                  stroke="#EBCB8B"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                />
              </g>
              <text
                x={NODES.ssh.x - 20}
                y={NODES.ssh.y - 60}
                fill="#EBCB8B"
                fontSize="11"
                fontFamily="ui-monospace, monospace"
                textAnchor="middle"
              >
                hard wall
              </text>

              {/* You -> SSH (you own the session, drawn through the wall by you) */}
              <path
                d={`M ${NODES.user.x} ${NODES.user.y + 40} Q ${NODES.user.x} 460, ${NODES.ssh.x} ${NODES.ssh.y + 50}`}
                stroke="#88C0D0"
                strokeWidth="1.5"
                fill="none"
                strokeDasharray="0"
                markerEnd="url(#arrow-cyan)"
              />
              <text
                x={(NODES.user.x + NODES.ssh.x) / 2}
                y={482}
                fill="#88C0D0"
                fontSize="11"
                fontFamily="ui-monospace, monospace"
                textAnchor="middle"
              >
                you connect manually
              </text>

              {/* NODES */}
              <Node node={NODES.user} variant="user" />
              <Node node={NODES.editor} variant="cyan" />
              <Node node={NODES.agent} variant="mint" emphasised />
              <Node node={NODES.memory} variant="mint" sub="rules · KB · skills" />
              <Node node={NODES.timeline} variant="purple" />
              <Node node={NODES.ssh} variant="duck" locked />
              <Node node={NODES.files} variant="neutral" />
            </svg>

            <Legend />
          </div>
        </div>
      </div>
    </section>
  );
}

// --- Node ------------------------------------------------------------------

type NodeVariant = "user" | "cyan" | "mint" | "purple" | "duck" | "neutral";

function Node({
  node,
  variant,
  emphasised,
  locked,
  sub,
}: {
  node: { x: number; y: number; label: string };
  variant: NodeVariant;
  emphasised?: boolean;
  locked?: boolean;
  sub?: string;
}) {
  const palette: Record<NodeVariant, { fill: string; stroke: string; text: string }> = {
    user: { fill: "#1E2127", stroke: "#7B88A1", text: "#D8DEE9" },
    cyan: { fill: "rgba(136, 192, 208, 0.10)", stroke: "#88C0D0", text: "#D8DEE9" },
    mint: { fill: "rgba(143, 188, 187, 0.10)", stroke: "#8FBCBB", text: "#D8DEE9" },
    purple: { fill: "rgba(180, 142, 173, 0.10)", stroke: "#B48EAD", text: "#D8DEE9" },
    duck: { fill: "rgba(235, 203, 139, 0.10)", stroke: "#EBCB8B", text: "#D8DEE9" },
    neutral: { fill: "#1E2127", stroke: "#4B5163", text: "#D8DEE9" },
  };
  const p = palette[variant];
  const w = 120;
  const h = sub ? 56 : 44;
  return (
    <g>
      <rect
        x={node.x - w / 2}
        y={node.y - h / 2}
        width={w}
        height={h}
        rx="8"
        fill={p.fill}
        stroke={p.stroke}
        strokeWidth={emphasised ? 1.8 : 1.2}
      />
      <text
        x={node.x}
        y={node.y + (sub ? -2 : 4)}
        textAnchor="middle"
        fill={p.text}
        fontSize="13"
        fontFamily="Inter, system-ui, sans-serif"
        fontWeight={emphasised ? 600 : 500}
      >
        {node.label}
      </text>
      {sub && (
        <text
          x={node.x}
          y={node.y + 16}
          textAnchor="middle"
          fill="#7B88A1"
          fontSize="10.5"
          fontFamily="ui-monospace, monospace"
        >
          {sub}
        </text>
      )}
      {locked && (
        <g transform={`translate(${node.x - w / 2 + 8}, ${node.y - h / 2 + 8})`}>
          <rect width="14" height="10" y="4" rx="1.5" fill="#EBCB8B" />
          <path d="M3 4 v-1 a4 4 0 0 1 8 0 v1" fill="none" stroke="#EBCB8B" strokeWidth="1.5" />
        </g>
      )}
    </g>
  );
}

// --- Legend ----------------------------------------------------------------

function Legend() {
  const items: { color: string; label: string }[] = [
    { color: "#7B88A1", label: "User intent" },
    { color: "#88C0D0", label: "Agent edits" },
    { color: "#8FBCBB", label: "Memory injection" },
    { color: "#B48EAD", label: "Journaled mutation" },
    { color: "#EBCB8B", label: "Hard wall / locked" },
  ];
  return (
    <ul className="mt-6 flex flex-wrap items-center justify-center gap-x-6 gap-y-2 font-mono text-[11px] uppercase tracking-[0.14em]">
      {items.map((i) => (
        <li key={i.label} className="flex items-center gap-2 text-fg-subtle">
          <span
            className="inline-block h-px w-5"
            style={{ background: i.color, boxShadow: `0 0 0 1px ${i.color}33` }}
          />
          <span>{i.label}</span>
        </li>
      ))}
    </ul>
  );
}
