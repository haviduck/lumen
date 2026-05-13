// Hand-crafted feature icons.
//
// Consistent grammar:
// - 24px viewBox
// - stroke-based, not fill
// - strokeWidth 1.5 (matches Lumen's hairline edges)
// - strokeLinecap=round, strokeLinejoin=round
// - currentColor only (the parent card sets the tint)
//
// Each icon visually describes its feature; none are generic "code"/"box"
// icons. Keep that bar if you add new ones.

import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Base({ size = 24, children, ...rest }: IconProps & { children: React.ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
      {...rest}
    >
      {children}
    </svg>
  );
}

// Editor: stacked tabs with a diff slash mark on the active doc
export function IconEditor(p: IconProps) {
  return (
    <Base {...p}>
      <path d="M4 7h6l1.5 1.5H20v11H4z" />
      <path d="M4 7V5h4l1.5 1.5H20" />
      <path d="m9 13 6-3" />
      <path d="m9 16 6-3" />
    </Base>
  );
}

// Agent chat: speech bubble with a sparkle cursor inside
export function IconChat(p: IconProps) {
  return (
    <Base {...p}>
      <path d="M4 6h16v10H10l-4 4v-4H4z" />
      <path d="M11.5 11h2" />
      <path d="M12.5 10v2" />
      <path d="M15.5 12.5 17 14" />
      <path d="m9 9.5-1-1" />
    </Base>
  );
}

// Council: three nodes connected in a triangle, with a center hub (the blackboard)
export function IconCouncil(p: IconProps) {
  return (
    <Base {...p}>
      <circle cx="5" cy="6" r="2" />
      <circle cx="19" cy="6" r="2" />
      <circle cx="12" cy="19" r="2" />
      <circle cx="12" cy="12" r="1.25" />
      <path d="M6.5 7.2 10.8 11" />
      <path d="M17.5 7.2 13.2 11" />
      <path d="M12 13.25V17" />
    </Base>
  );
}

// SSH: terminal box with a lock hanging on its corner
export function IconSsh(p: IconProps) {
  return (
    <Base {...p}>
      <rect x="3" y="5" width="14" height="11" rx="1" />
      <path d="m6 9 2 2-2 2" />
      <path d="M10 13h3" />
      <rect x="15" y="14" width="6" height="5" rx="1" />
      <path d="M16.5 14v-1.5a1.5 1.5 0 1 1 3 0V14" />
    </Base>
  );
}

// Side panes: grid of windows, one highlighted
export function IconPanes(p: IconProps) {
  return (
    <Base {...p}>
      <rect x="3" y="4" width="8" height="7" rx="1" />
      <rect x="13" y="4" width="8" height="7" rx="1" />
      <rect x="3" y="13" width="8" height="7" rx="1" />
      <rect x="13" y="13" width="8" height="7" rx="1" strokeWidth={2.25} />
    </Base>
  );
}

// Workspace memory: a brain-ish folded card with a bookmark
export function IconMemory(p: IconProps) {
  return (
    <Base {...p}>
      <path d="M5 4h11l3 3v13H5z" />
      <path d="M16 4v3h3" />
      <path d="M9 11h6" />
      <path d="M9 14h6" />
      <path d="M9 17h3" />
    </Base>
  );
}

// Timeline: clock with a backward arrow (revision history)
export function IconTimeline(p: IconProps) {
  return (
    <Base {...p}>
      <circle cx="12" cy="13" r="7" />
      <path d="M12 9.5V13l2.5 1.5" />
      <path d="M5 6V3h3" />
      <path d="M8 3a8.5 8.5 0 0 1 7 3" />
    </Base>
  );
}

// Auto-update: download cloud with a refresh arc
export function IconUpdate(p: IconProps) {
  return (
    <Base {...p}>
      <path d="M7 14a4 4 0 0 1 .4-7.95A6 6 0 0 1 19 8a3.5 3.5 0 0 1-1 6.84" />
      <path d="M12 11v6" />
      <path d="m9.5 14.5 2.5 2.5 2.5-2.5" />
    </Base>
  );
}
