import Image from "next/image";
import Link from "next/link";

// Wordmark + falcon mark. Uses the >=48px line-art logo from the IDE.
// See .agents/design-system.md for why the icon variant is different.
export function Logo({ size = 28 }: { size?: number }) {
  return (
    <Link
      href="/"
      className="group inline-flex items-center gap-2.5 outline-none"
      aria-label="Lumen — home"
    >
      <span
        className="relative inline-flex items-center justify-center rounded-md border border-edge-hi bg-bg-raised/70 shadow-glass"
        style={{ width: size + 8, height: size + 8 }}
      >
        <Image
          src="/lumen-mark.png"
          alt=""
          width={size}
          height={size}
          priority
          className="opacity-90 group-hover:opacity-100 transition-opacity"
        />
      </span>
      <span className="font-semibold text-fg tracking-tight">Lumen</span>
    </Link>
  );
}
