import Link from "next/link";
import { PRODUCT, downloadUrl } from "@/lib/product";

export function Download() {
  const installer = PRODUCT.installerAssetName(PRODUCT.LATEST_VERSION);
  const portable = PRODUCT.portableAssetName(PRODUCT.LATEST_VERSION);

  return (
    <section id="download" className="section-y hairline-t">
      <div className="page-x">
        <div className="flex flex-col gap-3 max-w-2xl">
          <span className="eyebrow">Download</span>
          <h2 className="text-h2 font-semibold text-fg">
            Install on Windows. Per-user, no admin.
          </h2>
          <p className="text-fg-muted">
            Windows x64 is the supported build. Mac &amp; Linux Flutter
            scaffolding compiles but isn{"\u2019"}t QA{"\u2019"}d &mdash; build
            from source if you{"\u2019"}re feeling brave.
          </p>
        </div>

        <div className="mt-12 grid gap-5 md:grid-cols-2">
          {/* Installer card */}
          <div className="glass rounded-xl p-6 flex flex-col">
            <div className="flex items-start justify-between gap-3">
              <span className="pill !text-accent-cyan !border-accent-cyan/40">
                Recommended
              </span>
              <span className="font-mono text-xs text-fg-subtle">
                v{PRODUCT.LATEST_VERSION}
              </span>
            </div>
            <h3 className="mt-4 text-h3 font-semibold text-fg">Installer</h3>
            <p className="mt-2 text-sm text-fg-muted leading-relaxed">
              Per-user install to{" "}
              <code className="icode">%LOCALAPPDATA%\Programs\Lumen\</code>. No
              admin or UAC needed. Auto-updates from the menu bar. Clean
              uninstall via Apps &amp; Features.
            </p>
            <div className="mt-5 flex flex-wrap items-center gap-3">
              <Link
                href={downloadUrl(installer)}
                className="btn-primary"
                prefetch={false}
              >
                Download .exe ({installer})
              </Link>
            </div>
            <ul className="mt-5 space-y-1.5 text-xs text-fg-subtle">
              <li>
                SmartScreen will warn &mdash; click{" "}
                <span className="text-fg-muted">More info → Run anyway</span>.
                Installer isn{"\u2019"}t code-signed yet.
              </li>
              <li>~26&nbsp;MB. Built with Inno Setup.</li>
            </ul>
          </div>

          {/* Portable card */}
          <div className="glass rounded-xl p-6 flex flex-col">
            <div className="flex items-start justify-between gap-3">
              <span className="pill">Portable</span>
              <span className="font-mono text-xs text-fg-subtle">
                v{PRODUCT.LATEST_VERSION}
              </span>
            </div>
            <h3 className="mt-4 text-h3 font-semibold text-fg">
              Zip (no installer)
            </h3>
            <p className="mt-2 text-sm text-fg-muted leading-relaxed">
              Extract anywhere, run{" "}
              <code className="icode">lumen.exe</code>. No auto-update &mdash;
              you{"\u2019"}ll grab the next zip manually. Good for thumb-drive
              installs, shared boxes, or sandboxing.
            </p>
            <div className="mt-5 flex flex-wrap items-center gap-3">
              <Link
                href={downloadUrl(portable)}
                className="btn-ghost"
                prefetch={false}
              >
                Download .zip ({portable})
              </Link>
            </div>
            <ul className="mt-5 space-y-1.5 text-xs text-fg-subtle">
              <li>Same binary as the installer, no registry entries.</li>
              <li>~30&nbsp;MB.</li>
            </ul>
          </div>
        </div>

        <div className="mt-8 flex flex-wrap items-center gap-4 text-sm text-fg-muted">
          <Link
            href={PRODUCT.releases}
            target="_blank"
            rel="noreferrer"
            className="underline decoration-fg-subtle hover:decoration-fg underline-offset-4"
          >
            See all releases on GitHub →
          </Link>
          <span className="text-fg-subtle">·</span>
          <Link
            href={`${PRODUCT.github}#build-it-yourself`}
            target="_blank"
            rel="noreferrer"
            className="underline decoration-fg-subtle hover:decoration-fg underline-offset-4"
          >
            Build from source (mac / linux)
          </Link>
        </div>
      </div>
    </section>
  );
}
