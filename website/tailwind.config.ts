import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        // Lumen palette — mirrors lib/theme/duck_colors.dart so the site
        // and IDE feel like one product.
        bg: {
          deepest: "#14171D",
          deeper: "#191C22",
          raised: "#1E2127",
          raisedHi: "#272C36",
        },
        fg: {
          DEFAULT: "#D8DEE9",
          muted: "#7B88A1",
          subtle: "#4B5163",
        },
        accent: {
          cyan: "#88C0D0",
          mint: "#8FBCBB",
          purple: "#B48EAD",
          duck: "#EBCB8B",
        },
        edge: {
          hi: "rgba(216, 222, 233, 0.08)",
          lo: "rgba(216, 222, 233, 0.04)",
          seam: "rgba(216, 222, 233, 0.07)",
        },
      },
      fontFamily: {
        sans: [
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "sans-serif",
        ],
        mono: [
          "JetBrains Mono",
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "Consolas",
          "monospace",
        ],
      },
      fontSize: {
        // Tightened scale, less marketing-y than defaults.
        hero: ["clamp(2.5rem, 6vw, 4.5rem)", { lineHeight: "1.05", letterSpacing: "-0.02em" }],
        h2: ["clamp(1.75rem, 3vw, 2.5rem)", { lineHeight: "1.15", letterSpacing: "-0.015em" }],
        h3: ["1.25rem", { lineHeight: "1.3", letterSpacing: "-0.005em" }],
      },
      maxWidth: {
        page: "1180px",
        prose: "68ch",
      },
      backgroundImage: {
        "grid-faint":
          "linear-gradient(rgba(216, 222, 233, 0.035) 1px, transparent 1px), linear-gradient(90deg, rgba(216, 222, 233, 0.035) 1px, transparent 1px)",
        "halo-cyan":
          "radial-gradient(60% 50% at 50% 0%, rgba(136, 192, 208, 0.18), transparent 70%)",
      },
      boxShadow: {
        glass: "0 1px 0 0 rgba(216, 222, 233, 0.08) inset, 0 10px 40px -20px rgba(0, 0, 0, 0.6)",
      },
    },
  },
  plugins: [],
};

export default config;
