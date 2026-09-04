import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { Link } from '@tanstack/react-router'
import { DocsLink, HomeLink } from '@/components/site-links'
import { formatCopy, homeCopy, type HomeCopy, type Row } from '@/lib/home-copy'
import { DEFAULT_LANGUAGE, i18n } from '@/lib/i18n'
import { BREW_COMMAND, GITHUB_URL, type Release } from '@/lib/release'
import { cn } from '@/lib/utils'

/** The landing page, rendered once per language from `homeCopy`. */
export function HomePage({ lang, release }: { lang: string; release: Release }) {
  const copy = homeCopy(lang)
  const progressRef = useRef<HTMLDivElement>(null)
  useRevealMotion()
  useScrollProgress(progressRef)

  return (
    <div className="min-h-screen bg-background font-sans text-[15px] leading-relaxed text-foreground">
      <div aria-hidden className="scroll-progress" ref={progressRef} />
      <Header lang={lang} copy={copy} release={release} />

      <main>
        <Hero lang={lang} copy={copy} release={release} />
        <ProofBand copy={copy} />
        <Features copy={copy} />
        <Flow copy={copy} />
        <Shortcuts lang={lang} copy={copy} />
        <Download copy={copy} release={release} />
        <Faq copy={copy} />
      </main>

      <Footer lang={lang} copy={copy} />
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Chrome                                                              */
/* ------------------------------------------------------------------ */

/** Tracks page scroll with a thin brand bar, like zisla's reader-style progress. */
function useScrollProgress(progressRef: React.RefObject<HTMLDivElement | null>) {
  useEffect(() => {
    const bar = progressRef.current
    if (!bar) return
    const update = () => {
      const scrollable = document.documentElement.scrollHeight - window.innerHeight
      const progress = scrollable > 0 ? window.scrollY / scrollable : 0
      bar.style.transform = `scaleX(${Math.min(1, Math.max(0, progress))})`
    }
    update()
    window.addEventListener('scroll', update, { passive: true })
    window.addEventListener('resize', update)
    return () => {
      window.removeEventListener('scroll', update)
      window.removeEventListener('resize', update)
    }
  }, [])
}

/**
 * Gates the hidden initial state of `.reveal` elements behind JS + motion
 * preference: SSR HTML and reduced-motion users always see the full page.
 */
function useRevealMotion() {
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    document.documentElement.classList.add('reveal-ready')
    return () => document.documentElement.classList.remove('reveal-ready')
  }, [])
}

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
/* Header                                                              */
/* ------------------------------------------------------------------ */

function Header({ lang, copy, release }: { lang: string; copy: HomeCopy; release: Release }) {
  const [open, setOpen] = useState(false)
  const anchors = [
    { href: '#features', label: copy.nav.features },
    { href: '#how', label: copy.nav.how },
    { href: '#shortcuts', label: copy.nav.shortcuts },
    { href: '#faq', label: copy.nav.faq },
  ]
  const others = i18n.languages.filter((code) => code !== lang)

  return (
    <header className="sticky top-0 z-50 border-b border-border/60 bg-background/80 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-6 px-6">
        <HomeLink lang={lang} className="flex items-center gap-2.5 font-bold tracking-tight">
          <img
            src="/zshell-icon.png"
            alt=""
            width={1024}
            height={1024}
            className="size-7 rounded-[7px]"
          />
          zshell
        </HomeLink>

        <nav className="hidden items-center gap-7 font-mono text-[12px] text-muted-foreground md:flex">
          {anchors.map((a) => (
            <a key={a.href} href={a.href} className="transition-colors hover:text-foreground">
              {a.label}
            </a>
          ))}
          <DocsLink lang={lang} className="transition-colors hover:text-foreground">
            {copy.nav.docs}
          </DocsLink>
        </nav>

        <div className="flex items-center gap-3">
          {others.map((code) => (
            <HomeLink
              key={code}
              lang={code}
              className="hidden font-mono text-[12px] text-muted-foreground transition-colors hover:text-foreground sm:block"
            >
              {homeCopy(code).languageName}
            </HomeLink>
          ))}
          <a
            href={release.dmg}
            download
            className="hidden items-center gap-1.5 rounded-md bg-brand px-3.5 py-1.5 text-[13px] font-semibold text-brand-foreground transition-transform hover:-translate-y-px sm:inline-flex"
          >
            <span aria-hidden className="i-mingcute-apple-fill size-3.5" />
            {copy.nav.download}
          </a>
          <button
            type="button"
            aria-expanded={open}
            aria-label={open ? copy.nav.menuClose : copy.nav.menuOpen}
            onClick={() => setOpen(!open)}
            className="flex size-9 items-center justify-center rounded-md border border-border text-muted-foreground md:hidden"
          >
            <span aria-hidden className={cn('size-4', open ? 'i-mingcute-close-line' : 'i-mingcute-menu-line')} />
          </button>
        </div>
      </div>

      {open && (
        <nav className="flex flex-col gap-1 border-t border-border/60 bg-background px-6 py-3 font-mono text-[13px] md:hidden">
          {anchors.map((a) => (
            <a
              key={a.href}
              href={a.href}
              onClick={() => setOpen(false)}
              className="rounded-md px-2 py-2 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            >
              {a.label}
            </a>
          ))}
          <DocsLink
            lang={lang}
            className="rounded-md px-2 py-2 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          >
            {copy.nav.docs}
          </DocsLink>
          <a
            href={release.dmg}
            download
            onClick={() => setOpen(false)}
            className="mt-1 inline-flex items-center justify-center gap-1.5 rounded-md bg-brand px-3.5 py-2 font-sans text-[13px] font-semibold text-brand-foreground"
          >
            <span aria-hidden className="i-mingcute-apple-fill size-3.5" />
            {copy.nav.download}
          </a>
        </nav>
      )}
    </header>
  )
}

/* ------------------------------------------------------------------ */
/* Hero                                                                */
/* ------------------------------------------------------------------ */

function Hero({ lang, copy, release }: { lang: string; copy: HomeCopy; release: Release }) {
  return (
    <section className="relative overflow-hidden">
      {/* Faint terminal grid backdrop */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 [background-image:linear-gradient(to_right,var(--border)_1px,transparent_1px),linear-gradient(to_bottom,var(--border)_1px,transparent_1px)] [background-size:56px_56px] opacity-40 [mask-image:radial-gradient(ellipse_70%_60%_at_50%_0%,black,transparent)]"
      />
      <div className="relative mx-auto grid max-w-6xl items-center gap-14 px-6 pt-20 pb-16 lg:grid-cols-[1.02fr_0.98fr] lg:pt-28 lg:pb-24">
        <div className="max-w-xl">
          <Reveal>
            <p className="font-mono text-[12px] font-semibold tracking-[0.14em] text-brand uppercase">
              {copy.hero.eyebrow}
            </p>
          </Reveal>
          <Reveal delay={90}>
            <h1 className="mt-5 text-[clamp(2.3rem,4.6vw,3.6rem)] leading-[1.08] font-bold tracking-tight text-balance">
              {copy.hero.titleBefore}
              <span className="text-brand">{copy.hero.titleHighlight}</span>
              {copy.hero.titleAfter}
            </h1>
          </Reveal>
          <Reveal delay={180}>
            <p className="mt-5 text-[16px] leading-relaxed text-pretty text-muted-foreground">
              {copy.hero.lede}
              <br />
              {copy.hero.ledeFree}
            </p>
          </Reveal>
          <Reveal delay={260}>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <a
                href={release.dmg}
                download
                className="inline-flex items-center gap-2 rounded-md bg-brand px-5 py-2.5 font-semibold text-brand-foreground transition-transform hover:-translate-y-px"
              >
                <span aria-hidden className="i-mingcute-apple-fill size-4" />
                {copy.hero.download}
              </a>
              <DocsLink
                lang={lang}
                className="inline-flex items-center gap-2 rounded-md border border-border px-5 py-2.5 font-semibold transition-colors hover:border-brand hover:text-brand"
              >
                <span aria-hidden className="i-mingcute-book-2-line size-4" />
                {copy.hero.docs}
              </DocsLink>
            </div>
          </Reveal>
          <Reveal delay={340}>
            <ul className="mt-8 flex list-none flex-wrap gap-x-6 gap-y-2 p-0 text-[13px] text-muted-foreground">
              {copy.hero.hints.map((hint) => (
                <li key={hint} className="flex items-center gap-1.5">
                  <span aria-hidden className="i-mingcute-check-line size-3.5 text-success" />
                  {hint}
                </li>
              ))}
            </ul>
          </Reveal>
        </div>

        <Reveal delay={200} className="max-lg:mx-auto max-lg:w-full max-lg:max-w-xl">
          <TerminalWindow />
        </Reveal>
      </div>
    </section>
  )
}

/**
 * The hero's centerpiece: the app itself, rebuilt in CSS so it stays sharp at
 * every density and costs no network. Left to right — projects sidebar, a live
 * terminal with an OSC 9;4 progress bar, and the git panel mid-review.
 */
function TerminalWindow() {
  return (
    <div className="window-float overflow-hidden rounded-xl border border-border bg-card shadow-[0_32px_80px_-24px_rgba(0,0,0,0.55)]">
      {/* Title bar */}
      <div className="flex items-center border-b border-border px-4 py-2.5">
        <span className="flex gap-1.5">
          <i className="size-2.5 rounded-full bg-[#ff5f57]" />
          <i className="size-2.5 rounded-full bg-[#febc2e]" />
          <i className="size-2.5 rounded-full bg-[#28c840]" />
        </span>
        <span className="ml-3 font-mono text-[11px] text-muted-foreground">zshell — ~/code/zshell</span>
      </div>

      <div className="grid h-[290px] grid-cols-[104px_1fr] font-mono text-[10.5px] leading-[1.7] sm:grid-cols-[110px_1fr_148px]">
        {/* Projects sidebar */}
        <div className="border-r border-border bg-muted/40 px-3 py-3">
          <p className="text-[9px] tracking-[0.12em] text-muted-foreground/70">PROJECTS</p>
          <ul className="mt-1.5 space-y-1">
            <li className="-mx-1 rounded bg-brand/15 px-1 text-brand">▸ zshell</li>
            <li className="px-1 text-muted-foreground">▸ zisla</li>
            <li className="px-1 text-muted-foreground">▸ dotfiles</li>
          </ul>
          <p className="mt-4 text-[9px] tracking-[0.12em] text-muted-foreground/70">AGENTS</p>
          <ul className="mt-1.5 space-y-1">
            <li className="flex items-center gap-1.5 px-1 text-muted-foreground">
              <i className="size-1.5 rounded-full bg-success" />
              claude
            </li>
            <li className="flex items-center gap-1.5 px-1 text-muted-foreground">
              <i className="size-1.5 animate-caret rounded-full bg-[#febc2e]" />
              codex
            </li>
          </ul>
        </div>

        {/* Terminal pane */}
        <div className="relative bg-[#0b0e14] px-3.5 py-3">
          <div className="demo-progress absolute inset-x-0 top-0 h-[2px] bg-brand" />
          <p className="text-muted-foreground/60">~/code/zshell · main*</p>
          <p className="mt-2">
            <span className="text-success">❯</span> <span className="text-foreground">git status</span>
          </p>
          <p className="text-muted-foreground">
            on main, <span className="text-[#e3b341]">3 files changed</span>
          </p>
          <p className="mt-2">
            <span className="text-success">❯</span> <span className="text-foreground">make run</span>
          </p>
          <p className="text-muted-foreground">building zshell…</p>
          <p>
            <span className="text-success">✓</span> <span className="text-muted-foreground">build succeeded in 4.2s</span>
          </p>
          <p className="mt-2">
            <span className="text-success">❯</span>
            <span aria-hidden className="ml-1.5 inline-block h-[12px] w-[6px] animate-caret bg-brand align-[-1px]" />
          </p>
        </div>

        {/* Git panel */}
        <div className="hidden border-l border-border px-3 py-3 sm:block">
          <p className="text-[9px] tracking-[0.12em] text-muted-foreground/70">
            <span className="text-foreground">GIT</span> · FILES · INFO
          </p>
          <p className="mt-2 text-muted-foreground/70">Changes (3)</p>
          <ul className="mt-1 space-y-1">
            <li>
              <span className="text-[#e3b341]">M</span> <span className="text-muted-foreground">main.swift</span>
            </li>
            <li>
              <span className="text-success">+</span> <span className="text-muted-foreground">pane.swift</span>
            </li>
            <li>
              <span className="text-destructive">−</span> <span className="text-muted-foreground">legacy.swift</span>
            </li>
          </ul>
          <div className="mt-3 rounded border border-border bg-muted/50 px-2 py-1.5 text-muted-foreground">
            feat: split panes
          </div>
          <div className="mt-2 rounded bg-brand px-2 py-1 text-center font-semibold text-brand-foreground">
            Commit ▸
          </div>
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Proof band                                                          */
/* ------------------------------------------------------------------ */

function ProofBand({ copy }: { copy: HomeCopy }) {
  return (
    <section className="border-y border-border bg-muted/30">
      <div className="mx-auto grid max-w-6xl grid-cols-2 gap-px lg:grid-cols-4">
        {copy.proof.map((item, i) => (
          <Reveal key={item.title} delay={i * 70} className="border-border max-lg:odd:border-r lg:not-last:border-r">
            <div className="px-6 py-7">
              <p className="font-mono text-[15px] font-bold text-foreground">
                {formatCopy(item.title, { count: copy.shortcuts.rows.length })}
              </p>
              <p className="mt-1.5 text-[13px] leading-relaxed text-muted-foreground">{item.desc}</p>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/* Sections                                                            */
/* ------------------------------------------------------------------ */

function SectionHeading({
  eyebrow,
  title,
  lede,
}: {
  eyebrow: string
  title: ReactNode
  lede: string
}) {
  return (
    <Reveal>
      <div className="flex items-end justify-between gap-12 max-md:flex-col max-md:items-start max-md:gap-4">
        <div className="max-w-2xl">
          <p className="font-mono text-[12px] font-semibold tracking-[0.14em] text-brand uppercase">{eyebrow}</p>
          <h2 className="mt-4 text-[clamp(1.7rem,3.2vw,2.5rem)] leading-[1.12] font-bold tracking-tight text-balance">
            {title}
          </h2>
        </div>
        <p className="max-w-xs text-[14px] leading-relaxed text-pretty text-muted-foreground">{lede}</p>
      </div>
    </Reveal>
  )
}

function Features({ copy }: { copy: HomeCopy }) {
  return (
    <section id="features" className="scroll-mt-20 py-24">
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading
          eyebrow={copy.features.eyebrow}
          title={
            <>
              {copy.features.titleBefore}
              <span className="text-muted-foreground">{copy.features.titleMuted}</span>
            </>
          }
          lede={copy.features.lede}
        />
        <div className="mt-14 flex flex-col gap-14">
          {copy.features.groups.map((group, i) => (
            <Reveal key={group.name} delay={60}>
              <div className="grid gap-6 border-t border-border pt-8 lg:grid-cols-[280px_1fr] lg:gap-12">
                <div>
                  <p className="font-mono text-[12px] text-muted-foreground/70">{String(i + 1).padStart(2, '0')}</p>
                  <h3 className="mt-2 font-mono text-[15px] font-semibold text-foreground">{group.name}</h3>
                  <p className="mt-2 text-[13px] leading-relaxed text-muted-foreground">{group.lede}</p>
                </div>
                <ul className="grid list-none gap-x-10 gap-y-3 p-0 sm:grid-cols-2">
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

function Flow({ copy }: { copy: HomeCopy }) {
  return (
    <section id="how" className="scroll-mt-20 border-y border-border bg-muted/30 py-24">
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading eyebrow={copy.flow.eyebrow} title={copy.flow.title} lede={copy.flow.lede} />
        <ol className="mt-14 grid list-none gap-10 p-0 md:grid-cols-3">
          {copy.flow.steps.map((step, i) => (
            <Reveal key={step.phase} delay={i * 90}>
              <li className="relative border-l-2 border-brand/40 pl-5">
                <p className="font-mono text-[11px] tracking-[0.1em] text-brand uppercase">{step.phase}</p>
                <h3 className="mt-2 text-[17px] font-bold">{step.title}</h3>
                <p className="mt-2 text-[13.5px] leading-relaxed text-muted-foreground">{step.desc}</p>
              </li>
            </Reveal>
          ))}
        </ol>
      </div>
    </section>
  )
}

function Shortcuts({ lang, copy }: { lang: string; copy: HomeCopy }) {
  return (
    <section id="shortcuts" className="scroll-mt-20 py-24">
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading eyebrow={copy.shortcuts.eyebrow} title={copy.shortcuts.title} lede={copy.shortcuts.lede} />
        <Reveal delay={80}>
          <ul className="mt-12 grid list-none gap-x-8 gap-y-4 p-0 sm:grid-cols-2 lg:grid-cols-3">
            {copy.shortcuts.rows.map((row) => (
              <li key={row.name} className="flex items-center gap-3">
                <span className="keycap">{row.name}</span>
                <span className="text-[13px] text-muted-foreground">{row.detail}</span>
              </li>
            ))}
          </ul>
        </Reveal>
        <Reveal delay={120}>
          <DocsLink
            lang={lang}
            className="mt-8 inline-flex items-center gap-1.5 font-mono text-[13px] text-brand transition-opacity hover:opacity-75"
          >
            {copy.shortcuts.docsLink}
            <span aria-hidden className="i-mingcute-arrow-right-line size-3.5" />
          </DocsLink>
        </Reveal>
      </div>
    </section>
  )
}

function Download({ copy, release }: { copy: HomeCopy; release: Release }) {
  return (
    <section id="download" className="scroll-mt-20 border-y border-border bg-muted/30 py-24">
      <div className="mx-auto max-w-6xl px-6">
        <div className="grid items-center gap-12 lg:grid-cols-[1fr_360px]">
          <Reveal>
            <div>
              <p className="font-mono text-[12px] font-semibold tracking-[0.14em] text-brand uppercase">
                {copy.download.eyebrow}
              </p>
              <h2 className="mt-4 text-[clamp(1.7rem,3.2vw,2.5rem)] leading-[1.12] font-bold tracking-tight text-balance">
                {copy.download.title}
              </h2>
              <p className="mt-4 max-w-md text-[15px] leading-relaxed text-pretty text-muted-foreground">
                {formatCopy(copy.download.copy, { minSystem: release.minSystem })}
              </p>
              <div className="mt-8 flex flex-wrap items-center gap-3">
                <a
                  href={release.dmg}
                  download
                  className="inline-flex items-center gap-2 rounded-md bg-brand px-5 py-2.5 font-semibold text-brand-foreground transition-transform hover:-translate-y-px"
                >
                  <span aria-hidden className="i-mingcute-apple-fill size-4" />
                  {copy.download.dmg}
                </a>
                <CopyCommand command={BREW_COMMAND} label={copy.copy} copiedLabel={copy.copied} aria={copy.copyAria(BREW_COMMAND)} />
              </div>
            </div>
          </Reveal>
          <Reveal delay={120}>
            <dl className="grid gap-px overflow-hidden rounded-lg border border-border bg-border font-mono text-[12.5px]">
              <div className="flex items-center justify-between bg-card px-4 py-3">
                <dt className="text-muted-foreground">{copy.download.notes.version}</dt>
                <dd className="font-semibold text-brand">v{release.version}</dd>
              </div>
              <div className="flex items-center justify-between bg-card px-4 py-3">
                <dt className="text-muted-foreground">{copy.download.notes.system}</dt>
                <dd>macOS {release.minSystem}+</dd>
              </div>
              <div className="flex items-center justify-between bg-card px-4 py-3">
                <dt className="text-muted-foreground">{copy.download.notes.license}</dt>
                <dd>{copy.download.notes.licenseValue}</dd>
              </div>
              <Link
                to="/changelog"
                className="flex items-center justify-between bg-card px-4 py-3 text-brand transition-colors hover:bg-muted"
              >
                {copy.download.changelog}
                <span aria-hidden className="i-mingcute-arrow-right-line size-3.5" />
              </Link>
            </dl>
          </Reveal>
        </div>
      </div>
    </section>
  )
}

function Faq({ copy }: { copy: HomeCopy }) {
  return (
    <section id="faq" className="scroll-mt-20 py-24">
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading eyebrow={copy.faq.eyebrow} title={copy.faq.title} lede={copy.faq.lede} />
        <div className="mt-12 grid gap-x-14 lg:grid-cols-2">
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
                <p className="mb-4 ml-6 text-[13.5px] leading-relaxed text-muted-foreground">{item.a}</p>
              </details>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------------ */
/* Footer                                                              */
/* ------------------------------------------------------------------ */

function Footer({ lang, copy }: { lang: string; copy: HomeCopy }) {
  const others = i18n.languages.filter((code) => code !== lang)
  return (
    <footer className="border-t border-border">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-6 py-10">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <HomeLink lang={lang} className="flex items-center gap-2.5 font-bold tracking-tight">
            <img
              src="/zshell-icon.png"
              alt=""
              width={1024}
              height={1024}
              className="size-6 rounded-[6px]"
            />
            zshell
          </HomeLink>
          <nav className="flex flex-wrap items-center gap-x-6 gap-y-2 font-mono text-[12px] text-muted-foreground">
            <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="transition-colors hover:text-foreground">
              GitHub
            </a>
            <DocsLink lang={lang} className="transition-colors hover:text-foreground">
              {copy.footerDocs}
            </DocsLink>
            {/* The changelog is generated from CHANGELOG.md, so it stays English. */}
            <Link to="/changelog" className="transition-colors hover:text-foreground">
              {copy.footerChangelog}
            </Link>
            {others.map((code) => (
              <HomeLink key={code} lang={code} className="transition-colors hover:text-foreground">
                {homeCopy(code).languageName}
              </HomeLink>
            ))}
          </nav>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border/60 pt-5 text-[12.5px] text-muted-foreground">
          <span>{copy.footerTagline}</span>
          <span className="font-mono">
            {copy.footerBuiltBy.before}
            <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="text-foreground transition-colors hover:text-brand">
              zshell
            </a>
            {copy.footerBuiltBy.after} · © 2026
          </span>
        </div>
      </div>
    </footer>
  )
}

/* ------------------------------------------------------------------ */
/* Shared bits                                                         */
/* ------------------------------------------------------------------ */

/**
 * The Homebrew one-liner with a copy button. The command stays selectable so
 * it's still usable if the Clipboard API isn't available (insecure context,
 * denied permission).
 */
function CopyCommand({
  command,
  label,
  copiedLabel,
  aria,
}: {
  command: string
  label: string
  copiedLabel: string
  aria: string
}) {
  const [copied, setCopied] = useState(false)
  const commandRef = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(timer)
  }, [copied])

  const copyCommand = async () => {
    try {
      await navigator.clipboard.writeText(command)
      setCopied(true)
    } catch {
      // Clipboard denied (insecure context, permissions policy). Select the
      // command so ⌘C still works — a button that does nothing reads as broken.
      const node = commandRef.current
      if (!node) return
      const range = document.createRange()
      range.selectNodeContents(node)
      const selection = window.getSelection()
      selection?.removeAllRanges()
      selection?.addRange(range)
    }
  }

  return (
    <div className="flex max-w-full items-stretch self-start overflow-hidden rounded-md border border-border bg-card font-mono text-[13px]">
      <code className="flex min-w-0 items-center gap-2 overflow-x-auto px-4 py-2.5 whitespace-pre">
        <span aria-hidden className="shrink-0 text-muted-foreground select-none">
          $
        </span>
        <span ref={commandRef}>{command}</span>
      </code>
      <button
        type="button"
        onClick={copyCommand}
        aria-label={aria}
        className="inline-flex shrink-0 items-center gap-1.5 border-l border-border px-3 text-muted-foreground transition-colors hover:bg-brand/10 hover:text-brand"
      >
        <span aria-hidden className={cn('size-3.5 shrink-0', copied ? 'i-mingcute-check-line' : 'i-mingcute-copy-2-line')} />
        <span aria-live="polite" className="max-[420px]:sr-only">
          {copied ? copiedLabel : label}
        </span>
      </button>
    </div>
  )
}

/** A feature's name and what it does — the page's one repeating unit. */
function DefinitionRow({ name, detail }: Row) {
  return (
    <li className="group">
      <span className="block text-[14px] font-semibold text-foreground transition-colors group-hover:text-brand">
        {name}
      </span>
      <span className="mt-0.5 block text-[13px] leading-relaxed text-muted-foreground">{detail}</span>
    </li>
  )
}
