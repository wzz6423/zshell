import { useNavigate, useRouterState } from '@tanstack/react-router'
import { docsPath, homePath, i18n, language, languageNames, languageTag } from '@/lib/i18n'
import { uiCopy } from '@/lib/ui-copy'
import { currentHeadingHash } from '@/lib/docs-anchors'

/** Native select keeps all 17 languages usable with a keyboard and on small screens. */
export function LanguageSelect({ lang, slug, onChange }: { lang: string; slug?: string; onChange?: () => void }) {
  const navigate = useNavigate()
  const hash = useRouterState({ select: (state) => state.location.hash })
  return (
    <select
      className="language-select"
      aria-label={uiCopy(lang).language}
      value={language(lang)}
      onChange={(event) => {
        const next = event.currentTarget.value
        onChange?.()
        void navigate({ to: slug === undefined ? homePath(next) : docsPath(next, slug), hash: currentHeadingHash(hash) })
      }}
    >
      {i18n.languages.map((locale) => <option key={locale} value={locale} lang={languageTag(locale)} dir={locale === 'ar' ? 'rtl' : 'ltr'}>{languageNames[locale]}</option>)}
    </select>
  )
}
