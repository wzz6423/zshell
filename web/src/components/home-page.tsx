import { useEffect, useRef, type ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { DocsLink, HomeLink } from '@/components/site-links'
import type { HomeCopy, Row } from '@/lib/home-copy'
import { LanguageSelect } from '@/components/language-select'
import { BREW_COMMAND, dmgUrl, GITHUB_URL, RELEASE_ARCHITECTURES, type Release } from '@/lib/release'
import { cn, withBase } from '@/lib/utils'
import { ModernHero } from '@/components/modern-hero'
import { MinimalSection } from '@/components/minimal-components'
import { ThemeToggle } from '@/components/theme-toggle'
import { LaunchVideo } from '@/components/launch-video'

/** The landing page, rendered once per language from `homeCopy`. */
export function HomePage({ lang, release, copy }: { lang: string; release: Release; copy: HomeCopy }) {
  // The landing page always opens at the top
  useEffect(() => {
    if (window.location.hash) return
    const html = document.documentElement
    const previous = html.style.scrollBehavior
    html.style.scrollBehavior = 'auto'
    window.scrollTo(0, 0)
    const raf = requestAnimationFrame(() => {
      window.scrollTo(0, 0)
      html.style.scrollBehavior = previous
    })
    return () => cancelAnimationFrame(raf)
  }, [])

  return (
    <div className="home-page min-h-screen font-sans text-base leading-relaxed">
      <MinimalHeader lang={lang} copy={copy} release={release} />

      <main id="main">
        <ModernHero lang={lang} copy={copy} release={release} />
        <Features lang={lang} copy={copy} />
        <DownloadSection copy={copy} release={release} />
        <Faq copy={copy} />
        <LaunchVideo copy={copy.video} />
      </main>

      <MinimalFooter lang={lang} copy={copy} />
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Header                                                              */
/* ------------------------------------------------------------------ */

function MinimalHeader({ lang, copy, release }: { lang: string; copy: HomeCopy; release: Release }) {
  return (
    <header className="fixed top-0 z-50 w-full border-b border-border bg-background/80 backdrop-blur-xl">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-3 px-4 sm:px-6">
        <HomeLink lang={lang} className="flex shrink-0 items-center gap-2 text-lg font-medium text-foreground">
          <img
            src={withBase('/zshell-icon.png')}
            alt=""
            width={24}
            height={24}
            className="rounded"
          />
          zshell
        </HomeLink>

        <div className="flex items-center gap-3 sm:gap-6">
          <DocsLink lang={lang} className="hidden text-sm text-muted-foreground transition-colors hover:text-foreground md:block">
            {copy.nav.docs}
          </DocsLink>
          <Link to="/changelog" className="hidden text-sm text-muted-foreground transition-colors hover:text-foreground md:block">
            {copy.footerChangelog}
          </Link>
          <ThemeToggle lang={lang} />
          <LanguageSelect lang={lang} />
        </div>
      </div>
    </header>
  )
}

/* ------------------------------------------------------------------ */
/* Download                                                            */
/* ------------------------------------------------------------------ */

function DownloadSection({ copy, release }: { copy: HomeCopy; release: Release }) {
  return (
    <MinimalSection className="border-t border-border">
      <div className="text-center">
        <h2 className="mb-6 text-4xl font-light text-foreground">{copy.download.title}</h2>
        <p className="mb-8 text-lg text-muted-foreground">
          v{release.version} · macOS {release.minSystem}+
        </p>

        <div className="flex flex-col items-center gap-4">
          <a
            href={release.dmg}
            download
            className="inline-flex items-center gap-2 rounded-full bg-primary px-8 py-3 text-base font-medium text-primary-foreground transition-all hover:bg-primary/90"
          >
            {copy.download.dmg}
          </a>

          <div className="mt-4 inline-flex max-w-xl items-stretch overflow-hidden rounded-lg border border-border bg-card shadow-sm">
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
        {release.architecturePackages && <div className="mt-4 space-y-2 font-mono text-xs text-muted-foreground">
          {(['github', 'gitee'] as const).map((host) => (
            <div key={host} className="flex flex-wrap items-center justify-center gap-x-4 gap-y-2">
              <span>{host === 'github' ? 'GitHub' : copy.download.mirror}</span>
              {RELEASE_ARCHITECTURES.filter((arch) => host === 'gitee' || arch !== 'universal').map((arch) => (
                <a
                  key={arch}
                  href={dmgUrl(release.version, arch, host)}
                  className="text-brand transition-opacity hover:opacity-75"
                >
                  {arch === 'arm64' ? 'Apple Silicon' : arch === 'x86_64' ? 'Intel' : 'Universal'}
                </a>
              ))}
            </div>
          ))}
        </div>}
      </div>
    </MinimalSection>
  )
}

/* ------------------------------------------------------------------ */
/* Footer                                                              */
/* ------------------------------------------------------------------ */

function MinimalFooter({ lang, copy }: { lang: string; copy: HomeCopy }) {
  return (
    <footer className="border-t border-border">
      <div className="mx-auto max-w-6xl px-6 py-12">
        <div className="flex flex-col items-center justify-between gap-4 text-sm text-muted-foreground sm:flex-row">
          <div className="flex items-center gap-2">
            <img
              src={withBase('/zshell-icon.png')}
              alt=""
              width={20}
              height={20}
              className="rounded"
            />
            <span>zshell</span>
          </div>

          <div className="flex items-center gap-6">
            <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="hover:text-foreground">
              GitHub
            </a>
            <DocsLink lang={lang} className="hover:text-foreground">
              {copy.footerDocs}
            </DocsLink>
            <Link to="/changelog" className="hover:text-foreground">
              {copy.footerChangelog}
            </Link>
          </div>
        </div>
      </div>
    </footer>
  )
}

/* ------------------------------------------------------------------ */
/* Reveal                                                              */
/* ------------------------------------------------------------------ */

function Reveal({
  children,
  className,
  delay = 0,
}: {
  children: ReactNode
  className?: string
  delay?: number
}) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    // Already on screen at mount (or motion is off): show, don't animate in.
    if (el.getBoundingClientRect().top < window.innerHeight - 40) {
      el.classList.add('is-visible')
      return
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-visible')
            io.unobserve(entry.target)
          }
        }
      },
      { threshold: 0.08, rootMargin: '0px 0px -48px 0px' },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])

  return (
    <div ref={ref} className={cn('reveal', className)} style={delay ? { transitionDelay: `${delay}ms` } : undefined}>
      {children}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Sections                                                            */
/* ------------------------------------------------------------------ */

function SectionHeading({ title, action }: { title: string; action?: ReactNode }) {
  return (
    <Reveal>
      <div className="flex flex-wrap items-center gap-x-5 gap-y-2">
        <h2 className="home-section-title">{title}</h2>
        {action}
      </div>
    </Reveal>
  )
}

function Features({ lang, copy }: { lang: string; copy: HomeCopy }) {
  return (
    <section id="features" className="home-section home-features">
      <div className="mx-auto max-w-6xl px-4 sm:px-6">
        <SectionHeading title={copy.features.title} />
        <div className="mt-12 grid gap-y-16">
          {copy.features.groups.map((group) => (
            <Reveal key={group.name} delay={60}>
              <div className="border-t border-border pt-8">
                <div className="mb-8 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-3">
                  <h3 className="text-balance text-xl font-semibold tracking-tight sm:text-2xl">{group.name}</h3>
                  <DocsLink lang={lang} slug={group.slug} className="home-text-link text-xs">{copy.features.docsLink}<span aria-hidden>↗</span></DocsLink>
                </div>
                <ul className="grid list-none gap-x-16 gap-y-10 p-0 sm:grid-cols-2">
                  {group.rows.map((row) => (
                    <DefinitionRow key={row.name} {...row} />
                  ))}
                </ul>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  )
}

function Faq({ copy }: { copy: HomeCopy }) {
  return (
    <section id="faq" className="home-section">
      <div className="home-container">
        <SectionHeading title={copy.faq.title} />
        <div className="mt-4">
          {copy.faq.items.map((item, i) => (
            <Reveal key={item.q} delay={(i % 2) * 60}>
              <details className="group border-b border-border">
                <summary className="flex cursor-pointer list-none items-baseline gap-3 py-4 font-semibold transition-colors hover:text-brand [&::-webkit-details-marker]:hidden">
                  <span
                    aria-hidden
                    className="flex-none font-mono text-muted-foreground before:content-['+'] group-open:before:content-['–']"
                  />
                  {item.q}
                </summary>
                <p className="mb-4 ms-6 text-[13.5px] leading-relaxed text-muted-foreground">{item.a}</p>
              </details>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  )
}

/** A feature's name and what it does — the page's one repeating unit. */
function DefinitionRow({ name, detail }: Row) {
  return (
    <li className="min-w-0">
      <span className="block text-balance text-base font-semibold text-foreground">
        {name}
      </span>
      <span className="mt-3 block text-pretty text-base leading-7 text-muted-foreground">{detail}</span>
    </li>
  )
}
