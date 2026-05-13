import type { Metadata, Viewport } from "next";
import { PRODUCT } from "@/lib/product";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://lumen.dev"),
  title: {
    default: `${PRODUCT.name} — ${PRODUCT.tagline}`,
    template: `%s · ${PRODUCT.name}`,
  },
  description: PRODUCT.shortDescription,
  applicationName: PRODUCT.name,
  authors: [{ name: "Haviduck", url: PRODUCT.github }],
  keywords: [
    "IDE",
    "agentic IDE",
    "Flutter IDE",
    "desktop editor",
    "Windows IDE",
    "SSH",
    "Ollama",
    "Claude",
    "Gemini",
    "Copilot",
    PRODUCT.name,
  ],
  openGraph: {
    title: `${PRODUCT.name} — ${PRODUCT.tagline}`,
    description: PRODUCT.shortDescription,
    url: "https://lumen.dev",
    siteName: PRODUCT.name,
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: `${PRODUCT.name} — ${PRODUCT.tagline}`,
    description: PRODUCT.shortDescription,
  },
  icons: {
    icon: [
      { url: "/favicon.png", type: "image/png" },
    ],
    apple: "/favicon.png",
  },
};

export const viewport: Viewport = {
  themeColor: "#14171D",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="bg-bg-deepest">
      <body className="min-h-screen bg-bg-deepest font-sans antialiased">
        {children}
      </body>
    </html>
  );
}
