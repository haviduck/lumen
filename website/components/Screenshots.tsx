import Image from "next/image";

type Shot = {
  src: string;
  alt: string;
  caption: string;
  title: string;
  width: number;
  height: number;
};

const SHOTS: Shot[] = [
  {
    src: "/screenshots/terminal-teams-youtube.png",
    title: "Editor + SSH + Teams + YouTube",
    alt:
      "Real Lumen session — code editor on the left with docker-compose.yml open, SSH terminal in the middle with lumen-edit / lumen-grab / OSC-7 helpers active, Teams docked below, YouTube on the right.",
    caption:
      "Editor open on a docker-compose file, SSH terminal showing the on-connect helpers (lumen-edit, lumen-grab, OSC-7 cwd), Teams chat docked below, YouTube on the right. One window.",
    width: 2400,
    height: 1340,
  },
  {
    src: "/screenshots/council-idle.png",
    title: "Council, idle",
    alt:
      "Council mode at rest — phase strip across the top, blackboard on the right, each agent has its own card with a step counter.",
    caption:
      "Phase strip across the top, blackboard on the right, agent cards with step counters waiting for a brief.",
    width: 2400,
    height: 1500,
  },
  {
    src: "/screenshots/council-running.png",
    title: "Council, running",
    alt:
      "Council mode running — agents pulling tasks in parallel, mentioning each other, posting to the shared blackboard.",
    caption:
      "Agents pulling tasks in parallel, mentioning each other, posting to the shared blackboard.",
    width: 2400,
    height: 1500,
  },
  {
    src: "/screenshots/ssh-youtube.png",
    title: "SSH + editor + YouTube",
    alt:
      "Editor on the left, SSH terminal in the middle, a YouTube panel on the right. One window.",
    caption:
      "Editor on the left, SSH in the middle, YouTube docked on the right. Don't pretend you don't do this.",
    width: 2400,
    height: 1500,
  },
  {
    src: "/screenshots/teams-ssh-youtube.png",
    title: "Editor + SSH + Teams + YouTube",
    alt:
      "Editor on the left, SSH and Teams in the middle column, YouTube on the right.",
    caption:
      "Editor, SSH, Teams chat, and YouTube — all docked in one window, no taskbar dance.",
    width: 2400,
    height: 1500,
  },
];

export function Screenshots() {
  return (
    <section id="screenshots" className="section-y hairline-t bg-bg-deeper/30">
      <div className="page-x">
        <div className="flex flex-col gap-3 max-w-2xl">
          <span className="eyebrow">Screenshots</span>
          <h2 className="text-h2 font-semibold text-fg">
            One window. Everything where you left it.
          </h2>
          <p className="text-fg-muted">
            Real screenshots, not mock-ups. Same Nord-flavoured dark theme that
            ships in the IDE.
          </p>
        </div>

        <div className="mt-12 grid gap-6 lg:grid-cols-2">
          {SHOTS.map((shot) => (
            <figure
              key={shot.src}
              className="glass rounded-xl overflow-hidden flex flex-col"
            >
              <div className="hairline-b px-4 py-2.5 bg-bg-deepest/40 flex items-center gap-2">
                <span className="flex items-center gap-1.5">
                  <span className="size-2 rounded-full bg-fg-subtle/40" />
                  <span className="size-2 rounded-full bg-fg-subtle/40" />
                  <span className="size-2 rounded-full bg-fg-subtle/40" />
                </span>
                <span className="ml-2 font-mono text-xs text-fg-subtle">
                  {shot.title}
                </span>
              </div>
              <div className="relative">
                <Image
                  src={shot.src}
                  alt={shot.alt}
                  width={shot.width}
                  height={shot.height}
                  sizes="(min-width: 1024px) 560px, 100vw"
                  className="w-full h-auto"
                />
              </div>
              <figcaption className="px-5 py-4 hairline-t text-sm text-fg-muted bg-bg-deepest/30">
                {shot.caption}
              </figcaption>
            </figure>
          ))}
        </div>
      </div>
    </section>
  );
}
