import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Pillars } from "@/components/Pillars";
import { ProviderStrip } from "@/components/ProviderStrip";
import { Features } from "@/components/Features";
import { ArchitectureDiagram } from "@/components/ArchitectureDiagram";
import { MemoryShowcase } from "@/components/MemoryShowcase";
import { CouncilPhases } from "@/components/CouncilPhases";
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
        <ProviderStrip />
        <Features />
        <ArchitectureDiagram />
        <MemoryShowcase />
        <CouncilPhases />
        <Screenshots />
        <Download />
        <FAQ />
      </main>
      <Footer />
    </>
  );
}
