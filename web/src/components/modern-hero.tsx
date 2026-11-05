import { DocsLink } from '@/components/site-links'
import type { HomeCopy } from '@/lib/home-copy'
import { BREW_COMMAND, type Release } from '@/lib/release'

/**
 * 现代化 Hero 区域 - 参考 Google Antigravity
 */
export function ModernHero({ lang, copy, release }: { lang: string; copy: HomeCopy; release: Release }) {
  return (
    <section className="relative flex min-h-screen items-center justify-center overflow-hidden">
      <div className="hero-copy relative z-10 w-full max-w-6xl px-6 text-center">
        {/* 状态标签 */}
        <div className="mb-6 inline-flex items-center gap-2 rounded-full border border-border bg-card px-4 py-2 text-sm font-medium text-foreground shadow-sm">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full motion-safe:animate-ping rounded-full bg-brand opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-brand" />
          </span>
          v{release.version} · macOS {release.minSystem}+
        </div>

        {/* 主标题 */}
        <h1 className="mb-6 text-7xl font-bold tracking-tight text-foreground md:text-9xl">
          zshell
        </h1>

        {/* 副标题 - 更多信息 */}
        <p className="mb-4 text-2xl font-semibold text-foreground md:text-4xl">
          {copy.hero.titleBefore}{' '}
          <span className="font-bold text-foreground">
            {copy.hero.titleHighlight}
          </span>
          {copy.hero.titleAfter}
        </p>

        <p className="mx-auto mb-12 max-w-2xl text-lg leading-relaxed text-neutral-700 dark:text-neutral-300">
          {copy.hero.lede}
        </p>

        {/* 按钮 */}
        <div className="flex flex-col items-center justify-center gap-4 sm:flex-row">
          <a
            href={release.dmg}
            download
            className="inline-flex items-center gap-2 rounded-full bg-primary px-8 py-4 text-base font-medium text-primary-foreground shadow-lg transition-transform hover:scale-105"
          >
            <span className="i-mingcute-apple-fill text-xl" />
            {copy.hero.download}
            <span className="i-mingcute-arrow-right-line" />
          </a>

          <DocsLink
            lang={lang}
            className="inline-flex items-center gap-2 rounded-full border-2 border-primary bg-background px-8 py-4 text-base font-medium text-foreground transition-colors hover:bg-primary hover:text-primary-foreground"
          >
            {copy.hero.docs}
            <span className="i-mingcute-book-2-line text-xl" />
          </DocsLink>
        </div>

        {/* Homebrew 安装 */}
        <div className="mt-8 inline-flex items-stretch overflow-hidden rounded-lg border border-border bg-card shadow-sm">
          <div className="flex items-center gap-3 px-5 py-3 font-mono text-sm">
            <span className="text-muted-foreground">$</span>
            <code className="text-foreground select-all">{BREW_COMMAND}</code>
          </div>
          <button
            onClick={() => {
              navigator.clipboard.writeText(BREW_COMMAND)
            }}
            className="flex items-center justify-center border-l border-border px-4 transition-colors hover:bg-muted"
            aria-label={copy.copyAria.replace('{command}', BREW_COMMAND)}
          >
            <span className="i-mingcute-copy-2-line text-muted-foreground" />
          </button>
        </div>
      </div>

    </section>
  )
}
