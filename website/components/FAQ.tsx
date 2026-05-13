type QA = { q: string; a: React.ReactNode };

const ITEMS: QA[] = [
  {
    q: "Is Lumen free?",
    a: (
      <>
        Yes. Free, open source, no telemetry. The only thing that costs money
        is whichever LLM provider you point it at &mdash; and you can run
        Ollama locally for nothing.
      </>
    ),
  },
  {
    q: "Which AI models does it support?",
    a: (
      <>
        Ollama (local + cloud), Anthropic Claude, Google Gemini, GitHub Copilot
        (uses your existing Copilot subscription via the CLI), and any
        OpenAI-compatible endpoint. You configure providers in a first-run
        wizard or under Settings.
      </>
    ),
  },
  {
    q: "Can the agent SSH into my servers?",
    a: (
      <>
        No, by design. The agent has zero access to the SSH layer: no host
        list, no credentials, no live sessions. SSH is yours alone. Roadmap
        adds opt-in agent reach (read remote file, run command in your active
        session) behind explicit, default-off toggles &mdash; never anything
        that can connect or unlock the vault.
      </>
    ),
  },
  {
    q: "Why does SmartScreen warn me on install?",
    a: (
      <>
        Because the installer isn{"\u2019"}t code-signed yet. Code signing
        certificates cost money and reputation builds slowly &mdash;
        contributions on this front (SignPath OSS, donated OV cert) are
        appreciated. Click <em>More info → Run anyway</em> to proceed.
      </>
    ),
  },
  {
    q: "Mac? Linux?",
    a: (
      <>
        The Flutter scaffolding compiles for both, but there are no official
        builds and no platform QA yet. If you build from source on macOS or
        Linux, file issues &mdash; PRs welcome.
      </>
    ),
  },
  {
    q: "Where does my data live?",
    a: (
      <>
        Workspace files stay on disk where you put them. SSH credentials live
        in the OS keystore (DPAPI on Windows, Keychain on macOS, libsecret on
        Linux). Per-workspace agent memory lives in{" "}
        <code className="icode">.lumen/</code> and{" "}
        <code className="icode">.agents/</code> inside your project &mdash;
        gitignore them or commit them, your call. Nothing is sent to a Lumen
        server because there is no Lumen server.
      </>
    ),
  },
];

export function FAQ() {
  return (
    <section className="section-y hairline-t bg-bg-deeper/30">
      <div className="page-x">
        <div className="flex flex-col gap-3 max-w-2xl">
          <span className="eyebrow">FAQ</span>
          <h2 className="text-h2 font-semibold text-fg">
            Honest answers, short.
          </h2>
        </div>
        <div className="mt-10 grid gap-3 max-w-4xl">
          {ITEMS.map(({ q, a }) => (
            <details
              key={q}
              className="group rounded-xl border border-edge-hi bg-bg-raised/40 px-5 py-4 transition-colors open:bg-bg-raised/60 open:border-edge-hi/80"
            >
              <summary className="list-none flex items-center justify-between gap-4 cursor-pointer">
                <span className="text-fg font-medium">{q}</span>
                <span className="size-6 inline-flex items-center justify-center rounded-md border border-edge-hi text-fg-muted transition-transform group-open:rotate-45">
                  +
                </span>
              </summary>
              <div className="mt-3 text-sm text-fg-muted leading-relaxed">
                {a}
              </div>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}
