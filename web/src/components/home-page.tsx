import { useEffect } from 'react'
import { Link } from '@tanstack/react-router'
import { DocsLink, HomeLink } from '@/components/site-links'
import type { HomeCopy, Row } from '@/lib/home-copy'
import { LanguageSelect } from '@/components/language-select'
import { BREW_COMMAND, GITHUB_URL, type Release } from '@/lib/release'
import { cn, withBase } from '@/lib/utils'
import { ModernHero } from '@/components/modern-hero'
import { MinimalFeature, MinimalSection } from '@/components/minimal-components'
import { ThemeToggle } from '@/components/theme-toggle'

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
    <div className="home-page min-h-screen bg-white font-sans text-base leading-relaxed dark:bg-gray-950">
      <MinimalHeader lang={lang} copy={copy} release={release} />

      <main id="main">
        <ModernHero lang={lang} copy={copy} release={release} />
        <MinimalFeatures />
        <DownloadSection copy={copy} release={release} />
      </main>

      <MinimalFooter lang={lang} />
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Header                                                              */
/* ------------------------------------------------------------------ */

function MinimalHeader({ lang, copy, release }: { lang: string; copy: HomeCopy; release: Release }) {
  return (
    <header className="fixed top-0 z-50 w-full border-b border-gray-200 bg-white/80 backdrop-blur-xl dark:border-gray-800 dark:bg-gray-950/80">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-6">
        <HomeLink lang={lang} className="flex items-center gap-2 text-lg font-medium text-black dark:text-white">
          <img
            src={withBase('/zshell-icon.png')}
            alt=""
            width={24}
            height={24}
            className="rounded"
          />
          zshell
        </HomeLink>

        <div className="flex items-center gap-6">
          <DocsLink lang={lang} className="text-sm text-gray-600 transition-colors hover:text-black dark:text-gray-400 dark:hover:text-white">
            文档
          </DocsLink>
          <Link to="/changelog" className="text-sm text-gray-600 transition-colors hover:text-black dark:text-gray-400 dark:hover:text-white">
            更新日志
          </Link>
          <ThemeToggle />
          <LanguageSelect lang={lang} />
        </div>
      </div>
    </header>
  )
}

/* ------------------------------------------------------------------ */
/* Features                                                            */
/* ------------------------------------------------------------------ */

function MinimalFeatures() {
  const features = [
    {
      number: '01',
      title: '项目与会话管理',
      description: '原生 AppKit 界面管理项目、标签页和分屏窗格。快速切换项目，每个项目保持独立的终端会话和工作环境。',
      icon: 'i-mingcute-folder-open-fill',
    },
    {
      number: '02',
      title: '灵活的分屏布局',
      description: '原生分屏系统，支持标签页和多窗格布局。在同一窗口并排查看多个终端会话、文件或浏览器。',
      icon: 'i-mingcute-layout-grid-fill',
    },
    {
      number: '03',
      title: 'Git 集成与文件管理',
      description: '内置文件树、Git 状态查看和可编辑的差异对比。快速检查代码变更、暂存文件和提交历史。',
      icon: 'i-mingcute-git-branch-fill',
    },
    {
      number: '04',
      title: '命令面板与文件搜索',
      description: '项目范围的文件搜索、命令面板和本地路径链接。快速导航到任何文件或执行命令。',
      icon: 'i-mingcute-search-line',
    },
    {
      number: '05',
      title: '集成浏览器面板',
      description: '内置浏览器标签页和窗格，方便查看文档、调试 Web 应用或预览开发结果。',
      icon: 'i-mingcute-compass-line',
    },
    {
      number: '06',
      title: 'AI Agent 集成',
      description: 'AI 智能体可以委托后台工作、跨 Zshell 窗格协调，提供状态报告和人工审批控制。',
      icon: 'i-mingcute-magic-2-line',
    },
    {
      number: '07',
      title: '多终端后端支持',
      description: '默认使用 libghostty，可选 Alacritty 后端。灵活选择最适合你的终端引擎。',
      icon: 'i-mingcute-terminal-box-line',
    },
    {
      number: '08',
      title: '原生 macOS 体验',
      description: '原生 AppKit 应用，完美集成 macOS 系统。流畅运行，低资源占用，支持 macOS 15.6+。',
      icon: 'i-mingcute-apple-fill',
    },
  ]

  return (
    <MinimalSection>
      {features.map((feature) => (
        <MinimalFeature key={feature.number} {...feature} />
      ))}
    </MinimalSection>
  )
}

/* ------------------------------------------------------------------ */
/* Download                                                            */
/* ------------------------------------------------------------------ */

function DownloadSection({ copy, release }: { copy: HomeCopy; release: Release }) {
  return (
    <MinimalSection className="border-t border-gray-200 dark:border-gray-800">
      <div className="text-center">
        <h2 className="mb-6 text-4xl font-light text-black dark:text-white">立即开始</h2>
        <p className="mb-8 text-lg text-gray-600 dark:text-gray-400">
          v{release.version} · macOS {release.minSystem}+
        </p>

        <div className="flex flex-col items-center gap-4">
          <a
            href={release.dmg}
            download
            className="inline-flex items-center gap-2 rounded-full bg-black px-8 py-3 text-base font-medium text-white transition-all hover:bg-gray-800 dark:bg-white dark:text-black dark:hover:bg-gray-200"
          >
            下载 macOS 版本
          </a>

          <div className="mt-4 max-w-xl rounded-lg border border-gray-200 bg-gray-50 p-4 dark:border-gray-700 dark:bg-gray-900">
            <code className="text-sm text-gray-600 dark:text-gray-300">{BREW_COMMAND}</code>
          </div>
        </div>
      </div>
    </MinimalSection>
  )
}

/* ------------------------------------------------------------------ */
/* Footer                                                              */
/* ------------------------------------------------------------------ */

function MinimalFooter({ lang }: { lang: string }) {
  return (
    <footer className="border-t border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <div className="mx-auto max-w-6xl px-6 py-12">
        <div className="flex flex-col items-center justify-between gap-4 text-sm text-gray-600 sm:flex-row dark:text-gray-400">
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
            <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="hover:text-black dark:hover:text-white">
              GitHub
            </a>
            <DocsLink lang={lang} className="hover:text-black dark:hover:text-white">
              文档
            </DocsLink>
            <Link to="/changelog" className="hover:text-black dark:hover:text-white">
              更新日志
            </Link>
          </div>
        </div>
      </div>
    </footer>
  )
}

/* ------------------------------------------------------------------ */
/* Chrome                                                              */
/* ------------------------------------------------------------------ */

function SectionProgress({ copy }: { copy: HomeCopy }) {
  const [active, setActive] = useState('overview')
  const sections = [
    { id: 'overview', label: copy.nav.overview },
    { id: 'features', label: copy.features.title },
    { id: 'shortcuts', label: copy.shortcuts.title },
    { id: 'download', label: `${copy.nav.download} / ${copy.nav.faq}` },
  ]

  useEffect(() => {
    const ids = ['overview', 'features', 'shortcuts', 'download']
    let frame = 0
    const update = () => {
      frame = 0
      const reached = ids.filter((id) => (document.getElementById(id)?.getBoundingClientRect().top ?? Infinity) <= 120)
      const atEnd = window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2
      const target = document.getElementById(window.location.hash.slice(1))
      // Short final sections share the same clamped scroll position; honor the clicked anchor there.
      const targetY = target ? Math.min(
        document.documentElement.scrollHeight - window.innerHeight,
        Math.max(0, target.getBoundingClientRect().top + window.scrollY - parseFloat(getComputedStyle(target).scrollMarginTop)),
      ) : -1
      const onTarget = target && ids.includes(target.id) && Math.abs(window.scrollY - targetY) < 2
      setActive(onTarget ? target.id : atEnd ? ids[ids.length - 1] : reached.at(-1) ?? ids[0])
    }
    const schedule = () => { if (!frame) frame = requestAnimationFrame(update) }
    update()
    window.addEventListener('scroll', schedule, { passive: true })
    window.addEventListener('resize', schedule)
    window.addEventListener('hashchange', schedule)
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('scroll', schedule)
      window.removeEventListener('resize', schedule)
      window.removeEventListener('hashchange', schedule)
    }
  }, [])

  return (
    <nav className="section-progress" aria-label={copy.nav.sections}>
      {sections.map(({ id, label }) => (
        <a key={id} href={`#${id}`} aria-label={label} aria-current={active === id ? 'location' : undefined}>
          <span className="section-progress-mark" aria-hidden />
          <span className="section-progress-label" aria-hidden>{label}</span>
        </a>
      ))}
    </nav>
  )
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
  const menuButton = useRef<HTMLButtonElement>(null)
  const anchors = [
    { href: '#features', label: copy.nav.features },
    { href: '#shortcuts', label: copy.nav.shortcuts },
    { href: '#faq', label: copy.nav.faq },
  ]

  useEffect(() => {
    if (!open) return
    const close = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setOpen(false)
        menuButton.current?.focus()
      }
    }
    window.addEventListener('keydown', close)
    return () => window.removeEventListener('keydown', close)
  }, [open])

  return (
    <header className="sticky top-0 z-50 border-b border-border bg-background/95">
      <div className="home-container flex h-20 items-center justify-between gap-4">
        <HomeLink lang={lang} className="flex items-center gap-2.5 font-bold tracking-tight">
          <img
            src={withBase('/zshell-icon.png')}
            alt=""
            width={1024}
            height={1024}
            className="size-7 rounded-[7px]"
          />
          zshell
        </HomeLink>

        <nav aria-label={copy.nav.features} className="hidden items-center gap-6 font-mono text-[12px] text-muted-foreground lg:flex">
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
          <LanguageSelect lang={lang} onChange={() => setOpen(false)} />
          <a
            href={release.dmg}
            download
            className="hidden min-h-10 items-center gap-1.5 border border-border px-3.5 text-[13px] font-semibold transition-colors hover:border-brand hover:text-brand sm:inline-flex"
          >
            <span aria-hidden className="i-mingcute-apple-fill size-3.5" />
            {copy.nav.download}
          </a>
          <button
            type="button"
            ref={menuButton}
            aria-expanded={open}
            aria-label={open ? copy.nav.menuClose : copy.nav.menuOpen}
            onClick={() => setOpen(!open)}
            aria-controls="mobile-navigation" className="flex size-11 items-center justify-center border border-border text-foreground lg:hidden"
          >
            <span aria-hidden className={cn('size-4', open ? 'i-mingcute-close-line' : 'i-mingcute-menu-line')} />
          </button>
        </div>
      </div>

      {open && (
        <nav id="mobile-navigation" className="flex max-h-[calc(100dvh-5rem)] flex-col gap-1 overflow-y-auto border-t border-border bg-background px-6 py-3 font-mono text-sm lg:hidden">
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
            onClick={() => setOpen(false)}
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
    <section id="overview" className="hero-section scroll-mt-24">
      <div className="home-container py-8 md:py-10">
        <div className="flex flex-wrap items-center justify-between gap-4 font-mono text-xs">
          <p className="flex items-center gap-3 tracking-wide text-muted-foreground">
            <span aria-hidden className="text-brand">[ &gt;_ ]</span>{copy.hero.eyebrow}
          </p>
          <Link to="/changelog" className="inline-flex items-center gap-2 text-muted-foreground hover:text-brand">
            v{release.version}<span aria-hidden>↗</span>
          </Link>
        </div>
        <div className="hero-content">
          <div className="hero-intro">
            <Reveal>
              <h1 className="hero-title">
                <span>{copy.hero.titleBefore}</span>
                <span>{copy.hero.titleHighlight}{copy.hero.titleAfter}<span aria-hidden className="hero-cursor" /></span>
              </h1>
            </Reveal>
            <Reveal delay={90}>
              <p className="max-w-md text-base leading-relaxed text-muted-foreground">{copy.hero.lede}</p>
              <div className="mt-7 flex flex-wrap items-center gap-5">
                <a href={release.dmg} download className="home-cta">
                  <span aria-hidden className="i-mingcute-apple-fill size-4" />{copy.hero.download}
                  <span aria-hidden className="i-mingcute-arrow-down-line size-4" />
                </a>
                <DocsLink lang={lang} className="home-text-link">{copy.hero.docs}<span aria-hidden>↗</span></DocsLink>
              </div>
            </Reveal>
          </div>
          <Reveal delay={140}>
            <TerminalWindow copy={copy} />
          </Reveal>
        </div>
      </div>
    </section>
  )
}

function TerminalWindow({ copy }: { copy: HomeCopy }) {
  const [view, setView] = useState(0)
  const preview = copy.preview

  return (
    <figure className="workspace-preview">
      <div className="preview-toolbar">
        <span className="hidden text-xs text-muted-foreground sm:block">{preview.label}</span>
        <div className="preview-switcher" role="group" aria-label={preview.label}>
          {preview.tabs.map((label, index) => (
            <button key={label} type="button" aria-pressed={view === index} aria-controls="workspace-example" onClick={() => setView(index)}>
              <span aria-hidden className="me-2 opacity-50">0{index + 1}</span>{label}
            </button>
          ))}
        </div>
      </div>
      <div id="workspace-example" className="workspace-window" role="img" aria-label={`${preview.label}：${preview.captions[view]}`}>
        <div className="workspace-titlebar" dir="ltr" aria-hidden="true">
          <span className="flex gap-1.5"><i /><i /><i /></span>
          <span>zshell — ~/code/zshell</span>
          <span aria-hidden />
        </div>
        <div className="workspace-body" aria-hidden="true">
          <aside className="workspace-sidebar">
            <p className="preview-label">{preview.projects}</p>
            <p className="mt-6 text-xs text-muted-foreground">{preview.local}</p>
            <p className="preview-project selected"><span>▾</span> zshell</p>
            <p className="preview-project"><span>▸</span> website</p>
            <p className="preview-project"><span>▸</span> dotfiles</p>
            <p className="mt-6 text-xs text-muted-foreground">{preview.remote}</p>
            <p className="preview-project"><span>↗</span> staging</p>
            <div className="mt-auto border-t border-border pt-4 text-xs text-muted-foreground">main <span className="float-right text-brand">+12 −3</span></div>
          </aside>
          <div className="min-w-0">
            <div className="workspace-tabs" dir="ltr"><span className="text-foreground">{view === 0 ? 'shell' : view === 1 ? 'review' : 'codex'}</span><span>dev server</span><span className="ml-auto">+</span></div>
            {view === 0 ? (
              <div className="preview-terminal" dir="ltr">
                <p className="text-muted-foreground">~/code/zshell <span className="text-brand">main</span></p>
                <p className="mt-5"><span className="text-brand">❯</span> git status --short</p>
                <p className="mt-2 text-muted-foreground"><span className="text-brand"> M</span> src/workspace.ts</p>
                <p className="text-muted-foreground"><span className="text-brand"> M</span> src/theme.css</p>
                <p className="text-muted-foreground"><span className="text-brand">??</span> docs/quick-start.md</p>
                <p className="mt-6"><span className="text-brand">❯</span> <span className="preview-caret" /></p>
                <div className="preview-split"><span>dev server</span><span>localhost:3000 ↗</span></div>
                <p className="text-muted-foreground"><span className="text-brand">❯</span> bun run dev</p>
              </div>
            ) : view === 1 ? (
              <div className="preview-code" dir="ltr">
                <p className="mb-6 text-muted-foreground">src/workspace.ts</p>
                <p><span className="line-number">18</span> const workspace = {'{'}</p>
                <p className="diff-removed"><span className="line-number">19</span>−  layout: 'single',</p>
                <p className="diff-added"><span className="line-number">19</span>+  layout: 'split',</p>
                <p className="diff-added"><span className="line-number">20</span>+  keepContext: true,</p>
                <p><span className="line-number">21</span> {'}'}</p>
                <p className="mt-8 text-muted-foreground">main → feat/workspace</p>
              </div>
            ) : (
              <div className="preview-terminal" dir="ltr">
                <p><span className="text-brand">❯</span> codex</p>
                <p className="mt-5 text-muted-foreground">› {preview.prompts[0]}</p>
                <p className="mt-4 text-brand">{preview.running} <span className="preview-caret" /></p>
                <div className="preview-queue">
                  <p className="preview-label">{preview.queue}</p>
                  <p className="mt-3">01 <span className="text-muted-foreground">{preview.prompts[1]}</span></p>
                  <p className="mt-2">02 <span className="text-muted-foreground">{preview.prompts[2]}</span></p>
                </div>
              </div>
            )}
          </div>
          <aside className="workspace-inspector">
            <p className="preview-label">{view === 2 ? preview.agents : preview.changes}</p>
            {view === 2 ? (
              <div className="space-y-6 pt-6"><p>codex<span className="mt-1 block text-xs text-brand">● {preview.running}</span></p><p>claude<span className="mt-1 block text-xs text-muted-foreground">○ {preview.attention}</span></p></div>
            ) : (
              <div className="space-y-3 pt-6 text-xs text-muted-foreground"><p><span className="text-brand">M</span> workspace.ts</p><p><span className="text-brand">M</span> theme.css</p><p><span className="text-brand">+</span> quick-start.md</p><div className="mt-8 border-t border-border pt-4">{preview.files} <span className="float-right">3</span></div></div>
            )}
          </aside>
        </div>
      </div>
    </figure>
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
    <section id="features" className="home-section">
      <div className="home-container">
        <SectionHeading title={copy.features.title} />
        <div className="mt-8 grid gap-x-10 gap-y-9 lg:grid-cols-2">
          {copy.features.groups.map((group) => (
            <Reveal key={group.name} delay={60}>
              <div className="h-full border-t border-border pt-6 pb-2">
                <div className="mb-6 flex flex-wrap items-center gap-x-4 gap-y-1">
                  <h3 className="text-xl font-semibold tracking-tight">{group.name}</h3>
                  <DocsLink lang={lang} slug={group.slug} className="home-text-link text-xs">{copy.features.docsLink}<span aria-hidden>↗</span></DocsLink>
                </div>
                <ul className="grid list-none gap-x-8 gap-y-6 p-0 sm:grid-cols-2">
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

function Shortcuts({ lang, copy }: { lang: string; copy: HomeCopy }) {
  return (
    <section id="shortcuts" className="home-section">
      <div className="home-container">
        <SectionHeading title={copy.shortcuts.title} action={
          <DocsLink lang={lang} slug="shortcuts" className="home-text-link text-sm text-brand">
            {copy.shortcuts.docsLink}<span aria-hidden>↗</span>
          </DocsLink>
        } />
        <Reveal delay={80}>
          <ul className="shortcut-grid">
            {copy.shortcuts.rows.slice(0, 8).map((row) => (
              <li key={row.name} className="flex flex-wrap content-center items-center gap-x-3 gap-y-2 border-b border-border py-4">
                <span className="keycap" dir="ltr">{row.name}</span>
                <span className="text-[13px] text-muted-foreground">{row.detail}</span>
              </li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  )
}

function Download({ copy, release }: { copy: HomeCopy; release: Release }) {
  return (
    <section id="download" className="home-section">
      <div className="home-container">
        <Reveal>
          <div>
            <h2 className="home-section-title">{copy.download.title}</h2>
            <div className="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-muted-foreground">
              <span>v{release.version}</span>
              <span>macOS {release.minSystem}+</span>
              <span>{copy.download.license}</span>
              <Link to="/changelog" className="home-text-link text-brand">{copy.download.changelog}<span aria-hidden>↗</span></Link>
            </div>
            <div className="mt-5 flex flex-wrap items-stretch gap-3">
              <a
                href={release.dmg}
                download
                className="home-cta"
              >
                <span aria-hidden className="i-mingcute-apple-fill size-4" />
                {copy.download.dmg}
              </a>
              <CopyCommand command={BREW_COMMAND} label={copy.copy} copiedLabel={copy.copied} aria={copy.copyAria.replace('{command}', BREW_COMMAND)} />
            </div>
            {release.architecturePackages && <div className="mt-4 space-y-2 font-mono text-[12px] text-muted-foreground">
              {(['github', 'gitee'] as const).map((host) => (
                <div key={host} className="flex flex-wrap items-center gap-x-4 gap-y-2">
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
        </Reveal>
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

/* ------------------------------------------------------------------ */
/* Footer                                                              */
/* ------------------------------------------------------------------ */

function Footer({ lang, copy }: { lang: string; copy: HomeCopy }) {
  return (
    <footer className="border-t border-border">
      <div className="home-container py-6">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <HomeLink lang={lang} className="flex items-center gap-2.5 font-bold tracking-tight">
            <img
              src={withBase('/zshell-icon.png')}
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
          </nav>
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
    <div className="home-command flex max-w-full items-stretch overflow-hidden border border-border bg-card font-mono text-xs">
      <code dir="ltr" className="flex min-w-0 items-center gap-2 overflow-x-auto px-4 py-2.5 whitespace-pre">
        <span aria-hidden className="shrink-0 text-muted-foreground select-none">
          $
        </span>
        <span ref={commandRef}>{command}</span>
      </code>
      <button
        type="button"
        onClick={copyCommand}
        aria-label={aria}
        className="inline-flex shrink-0 items-center gap-1.5 border-s border-border px-3 text-muted-foreground transition-colors hover:bg-brand/10 hover:text-brand"
      >
        <span aria-hidden className={cn('size-3.5 shrink-0', copied ? 'i-mingcute-check-line' : 'i-mingcute-copy-2-line')} />
        <span aria-live="polite" className="max-[420px]:sr-only">
          {copied ? copiedLabel : label}
        </span>
      </button>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Modern Features Section                                             */
/* ------------------------------------------------------------------ */

function ModernFeatures({ lang, copy }: { lang: string; copy: HomeCopy }) {
  const features = [
    {
      title: '项目管理',
      description: '轻松管理多个项目，快速切换工作环境，提高开发效率',
      icon: 'i-mingcute-folder-open-fill',
      gradient: 'bg-gradient-to-br from-green-500/10 to-transparent',
    },
    {
      title: '分屏布局',
      description: '灵活的窗格布局系统，支持多种分屏方式，并排查看多个终端',
      icon: 'i-mingcute-layout-grid-fill',
      gradient: 'bg-gradient-to-br from-blue-500/10 to-transparent',
    },
    {
      title: 'Git 集成',
      description: '内置 Git 面板，可视化管理代码变更、分支和提交历史',
      icon: 'i-mingcute-git-branch-fill',
      gradient: 'bg-gradient-to-br from-purple-500/10 to-transparent',
    },
    {
      title: '文件浏览器',
      description: '内置文件树浏览器，快速导航项目文件，支持文件搜索',
      icon: 'i-mingcute-file-search-fill',
      gradient: 'bg-gradient-to-br from-yellow-500/10 to-transparent',
    },
    {
      title: '代码编辑器',
      description: '集成轻量级代码编辑器，快速编辑文件无需切换应用',
      icon: 'i-mingcute-code-fill',
      gradient: 'bg-gradient-to-br from-red-500/10 to-transparent',
    },
    {
      title: '原生性能',
      description: '原生 macOS 应用，流畅运行，低资源占用，完美集成系统',
      icon: 'i-mingcute-flash-fill',
      gradient: 'bg-gradient-to-br from-orange-500/10 to-transparent',
    },
  ]

  return (
    <AnimatedSection id="features" className="scroll-mt-24 bg-black py-24">
      <div className="home-container">
        <div className="mb-16 text-center">
          <h2 className="mb-4 text-4xl font-bold text-white md:text-5xl">
            强大的功能特性
          </h2>
          <p className="mx-auto max-w-2xl text-lg text-gray-400">
            为开发者打造的现代化终端工作空间
          </p>
        </div>

        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
          {features.map((feature, index) => (
            <AnimatedFeatureCard
              key={feature.title}
              {...feature}
              delay={index * 100}
            />
          ))}
        </div>
      </div>
    </AnimatedSection>
  )
}

/* ------------------------------------------------------------------ */
/* Code Showcase Section                                              */
/* ------------------------------------------------------------------ */

function CodeShowcase({ copy }: { copy: HomeCopy }) {
  const codeExample = `❯ cd ~/code/zshell

❯ git status
M  src/workspace.ts
M  src/theme.css
?? docs/quick-start.md

❯ git add .
❯ git commit -m "feat: add workspace management"

❯ bun run dev
✓ Server running at localhost:3000`

  return (
    <AnimatedSection className="bg-gradient-to-b from-black to-gray-900 py-24">
      <div className="home-container">
        <div className="grid items-center gap-12 lg:grid-cols-2">
          <div>
            <h2 className="mb-6 text-4xl font-bold text-white md:text-5xl">
              流畅的开发体验
            </h2>
            <p className="mb-8 text-lg text-gray-400">
              原生 macOS 终端，结合现代化的项目管理功能，让你的开发工作更加高效和愉悦。
            </p>

            <ul className="space-y-4">
              {[
                '智能命令补全和历史记录',
                '自定义主题和配色方案',
                '快捷键驱动的高效操作',
                'SSH 远程服务器管理',
              ].map((item, index) => (
                <li key={index} className="flex items-center gap-3 text-gray-300">
                  <span className="i-mingcute-check-circle-fill text-xl text-green-400" />
                  {item}
                </li>
              ))}
            </ul>
          </div>

          <div>
            <CodeWindow code={codeExample} />
          </div>
        </div>
      </div>
    </AnimatedSection>
  )
}

/** A feature's name and what it does — the page's one repeating unit. */
function DefinitionRow({ name, detail }: Row) {
  return (
    <li className="min-w-0">
      <span className="block text-base font-semibold text-foreground">
        {name}
      </span>
      <span className="mt-2 block text-[15px] leading-7 text-muted-foreground">{detail}</span>
    </li>
  )
}
