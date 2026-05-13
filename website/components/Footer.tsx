import Link from "next/link";
import { PRODUCT } from "@/lib/product";

export function Footer() {
  return (
    <footer className="hairline-t bg-bg-deeper/40">
      <div className="page-x py-12 flex flex-col gap-8 sm:flex-row sm:items-start sm:justify-between">
        <div className="max-w-sm">
          <div className="font-semibold text-fg">Lumen</div>
          <p className="mt-2 text-sm text-fg-muted">
            A solo desktop IDE built for people who keep ten panels open and
            still want one window. Honest about what's WIP.
          </p>
        </div>

        <div className="grid grid-cols-2 gap-x-12 gap-y-2 text-sm">
          <div className="flex flex-col gap-2">
            <div className="eyebrow !text-fg-subtle">Product</div>
            <Link href="/#features" className="text-fg-muted hover:text-fg">
              Features
            </Link>
            <Link href="/#download" className="text-fg-muted hover:text-fg">
              Download
            </Link>
            <Link href="/docs" className="text-fg-muted hover:text-fg">
              Docs
            </Link>
          </div>
          <div className="flex flex-col gap-2">
            <div className="eyebrow !text-fg-subtle">Source</div>
            <Link
              href={PRODUCT.github}
              target="_blank"
              rel="noreferrer"
              className="text-fg-muted hover:text-fg"
            >
              GitHub
            </Link>
            <Link
              href={PRODUCT.releases}
              target="_blank"
              rel="noreferrer"
              className="text-fg-muted hover:text-fg"
            >
              Releases
            </Link>
            <Link
              href={PRODUCT.issues}
              target="_blank"
              rel="noreferrer"
              className="text-fg-muted hover:text-fg"
            >
              Issues
            </Link>
          </div>
        </div>
      </div>
      <div className="hairline-t">
        <div className="page-x py-6 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 text-xs text-fg-subtle">
          <span>© {new Date().getFullYear()} Lumen. MIT-licensed, built solo.</span>
          <span className="font-mono">
            v{PRODUCT.LATEST_VERSION} · Windows x64
          </span>
        </div>
      </div>
    </footer>
  );
}
