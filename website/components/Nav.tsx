import Link from "next/link";
import { Logo } from "./Logo";
import { PRODUCT } from "@/lib/product";

const NAV = [
  { href: "/#features", label: "Features" },
  { href: "/#screenshots", label: "Screenshots" },
  { href: "/docs", label: "Docs" },
  { href: "/#download", label: "Download" },
];

export function Nav() {
  return (
    <header className="sticky top-0 z-40 hairline-b bg-bg-deepest/85 backdrop-blur-md">
      <div className="page-x flex h-16 items-center justify-between">
        <Logo />
        <nav className="hidden md:flex items-center gap-1">
          {NAV.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="px-3 py-2 text-sm text-fg-muted hover:text-fg transition-colors rounded-md hover:bg-bg-raised/60"
            >
              {item.label}
            </Link>
          ))}
        </nav>
        <div className="flex items-center gap-2">
          <Link
            href={PRODUCT.github}
            target="_blank"
            rel="noreferrer"
            className="hidden sm:inline-flex btn-ghost"
          >
            GitHub
          </Link>
          <Link href="/#download" className="btn-primary">
            Download
          </Link>
        </div>
      </div>
    </header>
  );
}
