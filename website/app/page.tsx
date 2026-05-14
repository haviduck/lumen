import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Pillars } from "@/components/Pillars";
import { ProviderStrip } from "@/components/ProviderStrip";
import { Features } from "@/components/Features";
import { ArchitectureDiagram } from "@/components/ArchitectureDiagram";
import { SshShowcase } from "@/components/SshShowcase";
import { MemoryShowcase } from "@/components/MemoryShowcase";
import { CouncilPhases } from "@/components/CouncilPhases";
import { ProcessShowcase } from "@/components/ProcessShowcase";
import { BackupShowcase } from "@/components/BackupShowcase";
import { Screenshots } from "@/components/Screenshots";
import { Download } from "@/components/Download";
import { FAQ } from "@/components/FAQ";
import { Community } from "@/components/Community";
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
        <SshShowcase />
        <MemoryShowcase />
        <CouncilPhases />
        <ProcessShowcase />
        <BackupShowcase />
        <Screenshots />
        <Download />
        <FAQ />
        <Community />
      </main>
      <Footer />
    </>
  );
}
