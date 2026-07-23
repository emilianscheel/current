import Image from "next/image";

export default function Home() {
  return (
    <main className="flex min-h-svh w-full items-center justify-center px-6 py-12 sm:px-10">
      <section
        className="flex w-full max-w-3xl flex-col items-center text-center"
        aria-labelledby="page-title"
      >
        <Image
          className="h-auto w-26 sm:w-30 md:w-32"
          src="/current-icon.png"
          alt="current app icon"
          width={128}
          height={128}
          priority
        />

        <h1
          id="page-title"
          className="mt-6 text-[clamp(2.5rem,6vw,3.75rem)] font-semibold leading-none tracking-[-0.045em] text-black"
        >
          current
        </h1>

        <p className="mt-4 max-w-xl text-balance text-base leading-[1.45] font-normal tracking-[-0.012em] text-[#6e6e73] sm:text-lg">
          private, local-first dictation utility for mac. hold fn, speak, and
          release. it works everywhere.
        </p>

        <div className="mt-8 flex items-center justify-center gap-3 sm:mt-9">
          <button
            type="button"
            className="inline-flex h-9 cursor-pointer items-center justify-center rounded-full border-2 border-black bg-black px-3 text-base font-normal text-white sm:h-10 sm:px-4"
            aria-disabled="true"
            disabled
          >
            Download
          </button>

          <a
            className="inline-flex h-9 cursor-pointer items-center justify-center rounded-full border border-black bg-white px-3 text-base font-normal text-black transition-colors duration-200 hover:bg-black/[0.06] active:bg-black/[0.11] focus-visible:outline-3 focus-visible:outline-offset-3 focus-visible:outline-black sm:h-10 sm:px-4 motion-reduce:transition-none"
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
