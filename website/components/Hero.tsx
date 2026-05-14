import Link from "next/link";
import Image from "next/image";
import { PRODUCT, downloadUrl } from "@/lib/product";

export function Hero() {
  const installer = PRODUCT.installerAssetName(PRODUCT.LATEST_VERSION);
  return (
    <section className="relative overflow-hidden">
      {/* Backdrop layers — halo drifts slowly, grid stays anchored. */}
      <div className="pointer-events-none absolute inset-0 bg-halo-cyan opacity-80 drift-slow" aria-hidden />
      <div className="pointer-events-none absolute inset-0 grid-bg [mask-image:radial-gradient(closest-side,black,transparent_80%)]" aria-hidden />
      {/* Second halo, offset, slower, for parallax-y depth. */}
      <div
        className="pointer-events-none absolute -top-32 right-0 size-[36rem] rounded-full opacity-30 blur-3xl"
        style={{
          background:
            "radial-gradient(closest-side, rgba(180, 142, 173, 0.5), transparent 70%)",
        }}
        aria-hidden
      />

      <div className="relative page-x pt-24 pb-16 sm:pt-32 sm:pb-24">
        <div className="flex flex-col items-start gap-6">
          <span className="pill">
            <span className="pulse-dot inline-block size-1.5 rounded-full bg-accent-cyan text-accent-cyan" />
            v{PRODUCT.LATEST_VERSION} · Windows · free &amp; open source
          </span>

          <h1 className="text-hero font-semibold text-fg max-w-4xl">
            Editor, terminal, SSH, agent.{" "}
            <span className="text-accent-cyan">One window.</span>
            <span className="caret" aria-hidden />
          </h1>

          <p className="text-lg sm:text-xl text-fg-muted max-w-2xl leading-relaxed">
            Plus a file explorer, Teams, YouTube, and Twitch &mdash; all
            docked alongside. Open it tomorrow and you{"\u2019"}re back where
            you stopped.
          </p>

          <div className="mt-2 flex flex-wrap items-center gap-3">
            <Link
              href={downloadUrl(installer)}
              className="btn-primary"
              prefetch={false}
            >
              <DownloadIcon />
              Download for Windows
            </Link>
            <Link
              href={PRODUCT.github}
              target="_blank"
              rel="noreferrer"
              className="btn-ghost"
            >
              <GitHubIcon />
              View on GitHub
            </Link>
            <span className="font-mono text-xs text-fg-subtle ml-1">
              {installer}
            </span>
          </div>

          <p className="text-xs text-fg-subtle max-w-xl">
            Installer is per-user, no admin needed. Not yet code-signed &mdash;
            SmartScreen may warn on first download. Mac &amp; Linux builds
            compile but aren{"\u2019"}t QA{"\u2019"}d yet.
          </p>
        </div>

        <HeroPreview />
      </div>
    </section>
  );
}

// Hero preview — full multi-pane screenshot proving the tagline. Editor +
// terminal (with SSH plugin activation visible) + Teams + YouTube, all
// docked in one window. Framed as a fake IDE chrome so the screenshot
// doesn't float without context.
function HeroPreview() {
  return (
    <div className="mt-14 sm:mt-20 relative">
      <div className="glass rounded-xl overflow-hidden">
        {/* Faux title bar */}
        <div className="hairline-b flex items-center gap-2 px-4 py-2.5 bg-bg-deepest/50">
          <span className="flex items-center gap-1.5">
            <span className="size-2.5 rounded-full bg-fg-subtle/40" />
            <span className="size-2.5 rounded-full bg-fg-subtle/40" />
            <span className="size-2.5 rounded-full bg-fg-subtle/40" />
          </span>
          <span className="ml-3 font-mono text-xs text-fg-subtle">
            lumen — synthetic_data
          </span>
          <span className="ml-auto flex items-center gap-2">
            <span className="pill !text-accent-mint !border-accent-mint/40">
              ssh connected
            </span>
            <span className="pill !text-fg-subtle">4 panels</span>
          </span>
        </div>
        <div className="relative">
          <Image
            src="/screenshots/terminal-teams-youtube.png"
            alt="Lumen in real use — editor on the left with docker-compose.yml open, SSH terminal showing lumen-edit / lumen-grab / OSC-7 helpers active, Teams chat docked below, YouTube on the right. Single window."
            width={2400}
            height={1340}
            sizes="(min-width: 1180px) 1180px, 100vw"
            priority
            className="w-full h-auto"
          />
          <div className="pointer-events-none absolute inset-0 ring-1 ring-inset ring-edge-hi" />
        </div>
      </div>

      {/* Sub-caption */}
      <p className="mt-4 text-sm text-fg-muted max-w-2xl">
        A real session &mdash; <span className="text-fg">editor</span> on the
        left with <code className="icode">docker-compose.yml</code> open, the{" "}
        <span className="text-accent-mint">SSH terminal</span> showing the
        on-connect helpers (
        <code className="icode">lumen-edit · lumen-grab · OSC-7</code>),{" "}
        <span className="text-accent-purple">Teams</span> docked below, and{" "}
        <span className="text-accent-duck">YouTube</span> on the right.
        Nothing alt-tabbed.
      </p>
    </div>
  );
}

function DownloadIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M8 2v9" />
      <path d="m4 7 4 4 4-4" />
      <path d="M2.5 13.5h11" />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor" aria-hidden>
      <path d="M8 0C3.58 0 0 3.58 0 8a8 8 0 0 0 5.47 7.59c.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.42 7.42 0 0 1 2-.27c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
    </svg>
  );
}
