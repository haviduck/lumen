import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Pillars } from "@/components/Pillars";
import { Features } from "@/components/Features";
import { Screenshots } from "@/components/Screenshots";
import { Download } from "@/components/Download";
import { FAQ } from "@/components/FAQ";
import { Footer } from "@/components/Footer";

export default function HomePage() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Pillars />
        <Features />
        <Screenshots />
        <Download />
        <FAQ />
      </main>
      <Footer />
    </>
  );
}
