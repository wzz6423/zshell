import { Link } from '@tanstack/react-router'
import { DocsLink } from '@/components/site-links'
import { uiCopy } from '@/lib/ui-copy'
import { LanguageSelect } from '@/components/language-select'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { GITHUB_URL } from '@/lib/release'

const AUTHOR = 'zshell'
const LINK = 'text-foreground transition-colors hover:text-brand'

export function SiteFooter({ lang = DEFAULT_LANGUAGE }: { lang?: string }) {
  const copy = uiCopy(lang)

  return (
    <footer className="text-[13px] text-muted-foreground">
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
      {' · '}<LanguageSelect lang={lang} />{' '}
      · © 2026
    </footer>
  )
}
