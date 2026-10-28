import { useSidebar } from 'fumadocs-ui/layouts/docs/slots/sidebar'
import { LanguageSelect } from '@/components/language-select'
import { ThemeToggle } from '@/components/theme-toggle'
import { GITHUB_URL } from '@/lib/release'

export function DocsSidebarFooter({ lang, slug }: { lang: string; slug: string }) {
  const { setOpen } = useSidebar()

  return (
    <div className="docs-sidebar-footer">
      <LanguageSelect lang={lang} slug={slug} size="compact" onChange={() => setOpen(false)} />
      <ThemeToggle lang={lang} size="compact" />
      <a
        href={GITHUB_URL}
        target="_blank"
        rel="noopener noreferrer"
        aria-label="GitHub"
        title="GitHub"
        onClick={() => setOpen(false)}
        className="inline-flex size-9 shrink-0 items-center justify-center rounded-[var(--control-radius)] border border-border bg-background text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring focus-visible:outline-offset-2"
      >
        <span className="i-mingcute-github-line text-lg" aria-hidden="true" />
      </a>
    </div>
  )
}
