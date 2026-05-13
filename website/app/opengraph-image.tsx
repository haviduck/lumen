import { ImageResponse } from "next/og";

// Routes use a file-system convention: this file produces /opengraph-image
// at build time. Next.js wires it into the page's metadata automatically
// for OG + Twitter cards.

export const alt = "Lumen — an IDE that doesn't pretend the rest of your desktop doesn't exist.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function OG() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "72px",
          // Layered: deepest bg + a halo glow + a faint grid mask
          background:
            "radial-gradient(60% 50% at 50% 0%, rgba(136,192,208,0.22), transparent 70%), linear-gradient(180deg, #14171D 0%, #191C22 100%)",
          color: "#D8DEE9",
          fontFamily: "Inter, system-ui, sans-serif",
        }}
      >
        {/* Top bar: wordmark + version pill */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            width: "100%",
          }}
        >
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 16,
            }}
          >
            <div
              style={{
                width: 48,
                height: 48,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                borderRadius: 10,
                border: "1px solid rgba(216,222,233,0.08)",
                background: "rgba(30,33,39,0.7)",
                color: "#88C0D0",
                fontSize: 28,
                fontWeight: 700,
              }}
            >
              L
            </div>
            <div style={{ fontSize: 36, fontWeight: 600, letterSpacing: "-0.01em" }}>
              Lumen
            </div>
          </div>
          <div
            style={{
              fontFamily: "ui-monospace, monospace",
              fontSize: 18,
              color: "#7B88A1",
              border: "1px solid rgba(216,222,233,0.08)",
              padding: "8px 14px",
              borderRadius: 999,
              background: "rgba(30,33,39,0.6)",
            }}
          >
            v1.0.14 · WINDOWS · OPEN SOURCE
          </div>
        </div>

        {/* Title */}
        <div style={{ display: "flex", flexDirection: "column", gap: 24, maxWidth: 980 }}>
          <div
            style={{
              display: "flex",
              fontSize: 72,
              fontWeight: 600,
              letterSpacing: "-0.025em",
              lineHeight: 1.05,
              color: "#D8DEE9",
            }}
          >
            An IDE that doesn{"\u2019"}t pretend
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 72,
              fontWeight: 600,
              letterSpacing: "-0.025em",
              lineHeight: 1.05,
              color: "#D8DEE9",
              gap: 18,
              flexWrap: "wrap",
            }}
          >
            <span style={{ display: "flex" }}>the rest of your</span>
            <span style={{ display: "flex", color: "#88C0D0" }}>desktop</span>
            <span style={{ display: "flex" }}>doesn{"\u2019"}t exist.</span>
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 28,
              color: "#7B88A1",
              lineHeight: 1.4,
              maxWidth: 900,
            }}
          >
            Editor, terminal, agent chat, SSH, Teams, and YouTube/Twitch — one
            window, everything where you left it.
          </div>
        </div>

        {/* Bottom: domain */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            width: "100%",
          }}
        >
          <div
            style={{
              display: "flex",
              gap: 10,
              fontFamily: "ui-monospace, monospace",
              fontSize: 18,
              color: "#4B5163",
            }}
          >
            <span style={{ display: "flex" }}>Ollama</span>
            <span style={{ display: "flex" }}>·</span>
            <span style={{ display: "flex" }}>Claude</span>
            <span style={{ display: "flex" }}>·</span>
            <span style={{ display: "flex" }}>Gemini</span>
            <span style={{ display: "flex" }}>·</span>
            <span style={{ display: "flex" }}>Copilot</span>
            <span style={{ display: "flex" }}>·</span>
            <span style={{ display: "flex" }}>OpenAI-compatible</span>
          </div>
          <div style={{ fontSize: 22, color: "#7B88A1" }}>lumen.dev</div>
        </div>
      </div>
    ),
    { ...size }
  );
}
