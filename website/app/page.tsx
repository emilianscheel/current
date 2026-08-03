import { AnimatedAppIcon } from "./animated-app-icon";

export default function Home() {
  return (
    <main className="flex min-h-svh w-full items-center justify-center px-6 py-12 sm:px-10">
      <section
        className="flex w-full max-w-3xl flex-col items-center text-center"
        aria-labelledby="page-title"
      >
        <AnimatedAppIcon />

        <h1
          id="page-title"
          className="mt-6 text-[clamp(2.5rem,6vw,3.75rem)] font-semibold leading-none tracking-[-0.045em] text-[var(--foreground)]"
        >
          current
        </h1>

        <p className="mt-4 max-w-xl text-balance text-base leading-[1.45] font-normal tracking-[-0.012em] text-[var(--secondary-foreground)] sm:text-lg">
          private, local-first dictation utility for mac. hold fn, speak, and
          release. it works everywhere.
        </p>

        <div className="mt-8 flex items-center justify-center gap-3 sm:mt-9">
          <a
            className="inline-flex h-9 cursor-pointer items-center justify-center rounded-full border-2 border-[var(--primary-button-border)] bg-[var(--primary-button-background)] px-3 text-base font-normal text-[var(--primary-button-foreground)] transition-colors duration-200 hover:bg-[var(--primary-button-hover)] active:bg-[var(--primary-button-active)] focus-visible:outline-3 focus-visible:outline-offset-3 focus-visible:outline-[var(--focus-ring)] sm:h-10 sm:px-4 motion-reduce:transition-none"
            href="https://github.com/emilianscheel/current/releases/latest/download/Current.dmg"
            aria-label="Download Current for macOS"
          >
            Download
          </a>

          <a
            className="inline-flex h-9 cursor-pointer items-center justify-center rounded-full border border-[var(--secondary-button-border)] bg-[var(--secondary-button-background)] px-3 text-base font-normal text-[var(--secondary-button-foreground)] transition-colors duration-200 hover:bg-[var(--secondary-button-hover)] active:bg-[var(--secondary-button-active)] focus-visible:outline-3 focus-visible:outline-offset-3 focus-visible:outline-[var(--focus-ring)] sm:h-10 sm:px-4 motion-reduce:transition-none"
            href="https://github.com/emilianscheel/current"
            target="_blank"
            rel="noopener noreferrer"
          >
            GitHub
          </a>
        </div>
      </section>
    </main>
  );
}
