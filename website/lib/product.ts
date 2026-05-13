// Single source of truth for product-level constants.
// Update LATEST_VERSION when you cut a new release; the home page,
// download cards, and meta tags all read from here.

export const PRODUCT = {
  name: "Lumen",
  tagline:
    "An IDE that doesn't pretend the rest of your desktop doesn't exist.",
  shortDescription:
    "Editor, terminal, file explorer, agent chat, SSH, Teams, and YouTube/Twitch — one window, everything where you left it.",
  github: "https://github.com/haviduck/lumen",
  releases: "https://github.com/haviduck/lumen/releases",
  issues: "https://github.com/haviduck/lumen/issues",
  latest: "https://github.com/haviduck/lumen/releases/latest",
  // Latest shipped version. Bump when you tag.
  LATEST_VERSION: "1.0.14",
  // Asset names follow the installer-build script — auto-updater regex
  // matches these so don't rename without updating tools/installer/build.ps1.
  installerAssetName: (v: string) => `Lumen-Setup-v${v}.exe`,
  portableAssetName: (v: string) => `lumen-v${v}-windows-x64.zip`,
};

export function downloadUrl(filename: string) {
  return `${PRODUCT.releases}/latest/download/${filename}`;
}
