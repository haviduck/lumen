// Community / help-grow section.
//
// Tone: friendly, honest, a bit vulnerable. This is a one-developer
// project trying to reach more people. The asks are concrete and
// ordered by leverage:
//
//   1. Star (1-click social signal, biggest)
//   2. Tell one person (word of mouth — the only scalable thing
//      for solo OSS)
//   3. File an issue (feedback drives priorities)
//   4. Contribute (PRs welcome, with eyes-open caveats)
//
// Visually: a soft-glow panel with four "ask" cards. Different
// silhouette from the deep-dive sections so it reads as a CTA,
// not another technical deep dive.

import { PRODUCT } from "@/lib/product";

type Ask = {
  num: string;
  title: string;
  body: string;
  cta: { label: string; href: string };
  accent: "cyan" | "mint" | "purple" | "duck";
};

const ASKS: Ask[] = [
  {
    num: "01",
    title: "Star the repo",
    body: "The cheapest thing you can do. GitHub stars are how solo projects bubble up in trending and search. One click, three seconds, real signal.",
    cta: { label: "Star on GitHub", href: PRODUCT.github },
    accent: "duck",
  },
  {
    num: "02",
    title: "Tell one person",
    body: "Word of mouth is the only thing that scales for a one-developer project. If Lumen replaced something you alt-tabbed to a lot, mention it to a friend who alt-tabs the same way.",
    cta: { label: "Share the site", href: PRODUCT.siteUrl },
    accent: "cyan",
  },
  {
    num: "03",
    title: "File an issue",
    body: "Bug, paper-cut, feature you wish existed, model that doesn't quite work, weird font kerning — all welcome. Feedback is what drives the roadmap, not a calendar.",
    cta: { label: "Open an issue", href: `${PRODUCT.issues}/new` },
    accent: "mint",
  },
  {
    num: "04",
    title: "Build with me",
    body: "PRs welcome. The codebase is modular Dart + Flutter, opinionated but commented honestly. Read the .agents/knowledgebase.md before you start — it explains the boundaries.",
    cta: { label: "Browse the source", href: PRODUCT.github },
    accent: "purple",
  },
];

const ASK_COLOR: Record<Ask["accent"], { text: string; rule: string; ring: string; dot: string; btn: string }> = {
  cyan: {
    text: "text-accent-cyan",
    rule: "bg-accent-cyan/60",
    ring: "ring-accent-cyan/30",
    dot: "bg-accent-cyan",
    btn: "border-accent-cyan/35 text-accent-cyan hover:bg-accent-cyan/10",
  },
  mint: {
    text: "text-accent-mint",
    rule: "bg-accent-mint/60",
    ring: "ring-accent-mint/30",
    dot: "bg-accent-mint",
    btn: "border-accent-mint/35 text-accent-mint hover:bg-accent-mint/10",
  },
  purple: {
    text: "text-accent-purple",
    rule: "bg-accent-purple/60",
    ring: "ring-accent-purple/30",
    dot: "bg-accent-purple",
    btn: "border-accent-purple/35 text-accent-purple hover:bg-accent-purple/10",
  },
  duck: {
    text: "text-accent-duck",
    rule: "bg-accent-duck/60",
    ring: "ring-accent-duck/30",
    dot: "bg-accent-duck",
    btn: "border-accent-duck/35 text-accent-duck hover:bg-accent-duck/10",
  },
};

export function Community() {
  return (
    <section id="community" className="section-y hairline-t relative overflow-hidden">
      {/* Soft accent halo — different silhouette than feature sections */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 -top-20 h-72 opacity-60 blur-3xl"
        style={{
          background:
            "radial-gradient(60% 100% at 50% 0%, rgba(235, 203, 139, 0.18), rgba(180, 142, 173, 0.10) 40%, transparent 70%)",
        }}
      />

      <div className="page-x relative">
        <div className="flex flex-col gap-3 max-w-2xl">
          <div className="flex items-center gap-3">
            <span className="inline-flex items-center justify-center size-9 rounded-md border border-accent-duck/25 bg-accent-duck/10 text-accent-duck">
              <HandIcon />
            </span>
            <span className="eyebrow">A small ask</span>
          </div>
          <h2 className="text-h2 font-semibold text-fg">
            Help me get more people into this.
          </h2>
          <p className="text-fg-muted leading-relaxed">
            Lumen is a one-developer project. No VC, no growth team, no
            marketing budget &mdash; just one person who got tired of
            alt-tabbing and built something better. If any of this
            resonates, here are four ways to push it further. They go from
            cheapest to most involved.
          </p>
        </div>

        <ol className="mt-12 grid gap-4 lg:grid-cols-2">
          {ASKS.map((ask) => {
            const c = ASK_COLOR[ask.accent];
            return (
              <li
                key={ask.num}
                className="group relative rounded-xl border border-edge-hi bg-bg-raised/40 p-6 transition-colors hover:bg-bg-raised/60"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className={`font-mono text-xs ${c.text}`}>{ask.num}</span>
                  <span
                    className={`inline-block size-2 rounded-full ${c.dot} ring-2 ring-inset ${c.ring}`}
                  />
                </div>
                <span
                  className={`mt-3 block h-px w-10 transition-all duration-300 group-hover:w-16 ${c.rule}`}
                  aria-hidden
                />
                <h3 className="mt-3 text-h3 font-semibold text-fg">{ask.title}</h3>
                <p className="mt-2 text-sm text-fg-muted leading-relaxed">
                  {ask.body}
                </p>
                <a
                  href={ask.cta.href}
                  target="_blank"
                  rel="noreferrer"
                  className={`mt-5 inline-flex items-center gap-2 rounded-md border px-3 py-1.5 font-mono text-[11px] uppercase tracking-[0.14em] transition-colors ${c.btn}`}
                >
                  {ask.cta.label}
                  <ArrowGlyph />
                </a>
              </li>
            );
          })}
        </ol>

        <p className="mt-10 max-w-2xl text-sm text-fg-subtle leading-relaxed">
          Built by one person in the Norwegian fjords. If you found a bug,
          built something cool on top of it, or just want to say hi &mdash;{" "}
          <a
            href={`${PRODUCT.github}/discussions`}
            className="text-fg-muted hover:text-fg underline underline-offset-4 decoration-edge-hi"
            target="_blank"
            rel="noreferrer"
          >
            GitHub Discussions
          </a>{" "}
          is open.
        </p>
      </div>
    </section>
  );
}

function HandIcon() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M7 12V5.5a1.5 1.5 0 0 1 3 0V11" />
      <path d="M10 11V4a1.5 1.5 0 0 1 3 0v7" />
      <path d="M13 11V5.5a1.5 1.5 0 0 1 3 0V13" />
      <path d="M16 13v-2.5a1.5 1.5 0 0 1 3 0V16a5 5 0 0 1-5 5h-2c-2 0-3.5-1-4.5-2.5L4 13a1.6 1.6 0 0 1 2.6-1.9L9 14" />
    </svg>
  );
}

function ArrowGlyph() {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M2 5h6" />
      <path d="m5.5 2.5 2.5 2.5-2.5 2.5" />
    </svg>
  );
}
