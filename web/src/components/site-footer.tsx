import { Link } from '@tanstack/react-router'
import { DocsLink } from '@/components/site-links'
import { uiCopy } from '@/lib/ui-copy'
import { LanguageSelect } from '@/components/language-select'
import { ThemeToggle } from '@/components/theme-toggle'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { GITHUB_URL } from '@/lib/release'

const AUTHOR = 'zshell'
const LINK = 'text-foreground transition-colors hover:text-brand'

export function SiteFooter({ lang = DEFAULT_LANGUAGE }: { lang?: string }) {
  const copy = uiCopy(lang)

  return (
    <footer className="flex flex-wrap items-center gap-x-3 gap-y-3 text-[13px] text-muted-foreground">
      <div>
        <a href={GITHUB_URL} target="_blank" rel="noreferrer" className={LINK}>
          {AUTHOR}
        </a>
        {' · '}
        <a href={GITHUB_URL} target="_blank" rel="noreferrer" className={LINK}>
          GitHub
        </a>{' '}
        ·{' '}
        <DocsLink lang={lang} className={LINK}>
          {copy.docs}
        </DocsLink>{' '}
        ·{' '}
        {/* The changelog is generated from CHANGELOG.md, so it stays English. */}
        <Link to="/changelog" className={LINK}>
          {copy.changelog}
        </Link>
      </div>
      <div className="flex items-center gap-2">
        <LanguageSelect lang={lang} size="compact" />
        <ThemeToggle lang={lang} size="compact" />
      </div>
      <span>© 2026</span>
    </footer>
  )
}
