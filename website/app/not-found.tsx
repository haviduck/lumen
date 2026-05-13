import Link from "next/link";
import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";

export default function NotFound() {
  return (
    <>
      <Nav />
      <main className="page-x section-y">
        <div className="flex flex-col items-start gap-6 max-w-xl">
          <span className="pill !text-accent-purple !border-accent-purple/40">
            404 · lost panel
          </span>
          <h1 className="text-hero font-semibold text-fg">
            That panel isn{"\u2019"}t docked here.
          </h1>
          <p className="text-fg-muted text-lg">
            The page you tried to open doesn{"\u2019"}t exist. It might have
            moved, or you{"\u2019"}re following an old link from a release
            note.
          </p>
          <div className="flex flex-wrap gap-3">
            <Link href="/" className="btn-primary">
              Back to home
            </Link>
            <Link href="/docs" className="btn-ghost">
              Docs
            </Link>
          </div>
        </div>
      </main>
      <Footer />
    </>
  );
}
