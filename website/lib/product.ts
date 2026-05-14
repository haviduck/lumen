// Single source of truth for product-level constants.
// Update LATEST_VERSION when you cut a new release; the home page,
// download cards, and meta tags all read from here.

export const PRODUCT = {
  name: "Lumen",
  tagline: "Editor, terminal, SSH, agent. One window.",
  shortDescription:
    "Lumen docks editor, terminal, SSH, agent chat, file explorer, Teams, YouTube and Twitch in one window — and remembers where you were when you reopen it.",
  // Public production URL. Update here when you move to a custom domain.
  // Used by metadataBase + OG card absolute URLs.
  siteUrl: "https://lumen-mu-seven.vercel.app",
  github: "https://github.com/haviduck/lumen",
  releases: "https://github.com/haviduck/lumen/releases",
  issues: "https://github.com/haviduck/lumen/issues",
  latest: "https://github.com/haviduck/lumen/releases/latest",
  // Latest shipped version. Bump when you tag.
  LATEST_VERSION: "1.0.15",
  // Asset names follow the installer-build script — auto-updater regex
  // matches these so don't rename without updating tools/installer/build.ps1.
  installerAssetName: (v: string) => `Lumen-Setup-v${v}.exe`,
  portableAssetName: (v: string) => `lumen-v${v}-windows-x64.zip`,
};

export function downloadUrl(filename: string) {
  return `${PRODUCT.releases}/latest/download/${filename}`;
}
