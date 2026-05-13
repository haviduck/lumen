// Visual lineup of LLM providers Lumen talks to. Each badge uses the
// provider's actual brand letter + a tinted plate in a consistent color
// scheme that matches DuckColors' agent-letter palette (used in the
// model picker popover — see .agents/knowledgebase.md).

import { PRODUCT } from "@/lib/product";

type Provider = {
  label: string;
  mark: string; // 1-2 chars for the badge
  note: string;
  accent: "purple" | "duck" | "cyan" | "mint" | "neutral";
};

// Marks/notes match how the IDE labels providers internally.
const PROVIDERS: Provider[] = [
  { label: "Ollama", mark: "O", note: "Local · free", accent: "purple" },
  { label: "Claude", mark: "C", note: "Anthropic", accent: "duck" },
  { label: "Gemini", mark: "G", note: "Google", accent: "cyan" },
  { label: "Copilot", mark: "gh", note: "GitHub CLI", accent: "mint" },
  { label: "OpenAI-compatible", mark: "AI", note: "any endpoint", accent: "neutral" },
];

const ACCENT: Record<
  Provider["accent"],
  { plate: string; mark: string; ring: string }
> = {
  purple: {
    plate: "bg-accent-purple/12 border-accent-purple/30",
    mark: "text-accent-purple",
    ring: "ring-accent-purple/30",
  },
  duck: {
    plate: "bg-accent-duck/12 border-accent-duck/30",
    mark: "text-accent-duck",
    ring: "ring-accent-duck/30",
  },
  cyan: {
    plate: "bg-accent-cyan/12 border-accent-cyan/30",
    mark: "text-accent-cyan",
    ring: "ring-accent-cyan/30",
  },
  mint: {
    plate: "bg-accent-mint/12 border-accent-mint/30",
    mark: "text-accent-mint",
    ring: "ring-accent-mint/30",
  },
  neutral: {
    plate: "bg-bg-raisedHi/60 border-edge-hi",
    mark: "text-fg",
    ring: "ring-edge-hi",
  },
};

export function ProviderStrip() {
  return (
    <section className="section-y hairline-t">
      <div className="page-x">
        <div className="flex flex-col items-center text-center gap-3">
          <span className="eyebrow">Bring your own model</span>
          <h2 className="text-h2 font-semibold text-fg max-w-2xl">
            Pick a model{" "}
            <span className="text-accent-cyan">you</span> trust.{" "}
            <span className="text-fg-muted">Switch per chat.</span>
          </h2>
          <p className="text-fg-muted max-w-xl">
            Local Ollama with no API key, the major cloud providers, or any
            OpenAI-compatible endpoint &mdash; including self-hosted gateways.
          </p>
        </div>

        <ul className="mt-12 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          {PROVIDERS.map((p) => (
            <li
              key={p.label}
              className={`group flex flex-col items-center gap-3 rounded-xl border bg-bg-raised/40 px-4 py-5 transition-colors hover:bg-bg-raised/60 ${ACCENT[p.accent].plate.replace("bg-", "hover:bg-").split(" ")[0]} hover:border-edge-hi/80`}
            >
              <span
                className={`inline-flex size-12 items-center justify-center rounded-full border ${ACCENT[p.accent].plate} ring-1 ring-inset ${ACCENT[p.accent].ring} font-mono text-lg font-semibold ${ACCENT[p.accent].mark}`}
              >
                {p.mark}
              </span>
              <div className="flex flex-col items-center gap-1">
                <span className="text-sm font-medium text-fg">{p.label}</span>
                <span className="font-mono text-[10.5px] uppercase tracking-[0.14em] text-fg-subtle">
                  {p.note}
                </span>
              </div>
            </li>
          ))}
        </ul>

        <p className="mt-8 text-center text-xs text-fg-subtle font-mono">
          v{PRODUCT.LATEST_VERSION} ships with all five. Configure as many as
          you want.
        </p>
      </div>
    </section>
  );
}
