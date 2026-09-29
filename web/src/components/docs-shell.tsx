import { Suspense, lazy } from 'react'
import { useNavigate, useRouterState } from '@tanstack/react-router'
import browserCollections from 'collections/browser'
import { useFumadocsLoader } from 'fumadocs-core/source/client'
import { RootProvider } from 'fumadocs-ui/provider/tanstack'
import { DocsLayout } from 'fumadocs-ui/layouts/docs'
import { DocsBody, DocsDescription, DocsPage, DocsTitle } from 'fumadocs-ui/layouts/docs/page'
import { getMDXComponents } from '@/components/docs-mdx'
import { LanguageSelect } from '@/components/language-select'
import { docsLayoutOptions } from '@/lib/docs-layout'
import type { DocsPageData } from '@/lib/docs-loader'
import { DEFAULT_LANGUAGE, i18n, languageDirection, languageNames, languageTag } from '@/lib/i18n'
import { docsTranslations, uiCopy } from '@/lib/ui-copy'
import { currentHeadingHash } from '@/lib/docs-anchors'

// Search and its tokenizer are loaded only when the reader needs them.
const DocsSearchDialog = lazy(() => import('@/components/docs-search'))

export const docsClientLoader = browserCollections.docs.createClientLoader<{ lang: string; contentLanguage: string }>({
  component({ toc, frontmatter, default: MDX }, { lang, contentLanguage }) {
    const isFallback = lang !== contentLanguage
    return (
      <DocsPage toc={toc} className="docs-page" tableOfContent={{ single: true }}>
        {isFallback && <p className="docs-fallback" role="note">{uiCopy(lang).fallback.replace('{language}', languageNames[lang as keyof typeof languageNames])}</p>}
        <DocsTitle lang={languageTag(contentLanguage)} dir={languageDirection(contentLanguage)}>{frontmatter.title}</DocsTitle>
        <DocsDescription lang={languageTag(contentLanguage)} dir={languageDirection(contentLanguage)} className="docs-description">{frontmatter.description}</DocsDescription>
        <DocsBody lang={languageTag(contentLanguage)} dir={languageDirection(contentLanguage)} className="docs-body">
          <MDX components={getMDXComponents()} />
        </DocsBody>
      </DocsPage>
    )
  },
})

export function DocsShell({ lang, slug, data: serialized }: { lang: string; slug: string; data: DocsPageData }) {
  const data = useFumadocsLoader(serialized)
  const navigate = useNavigate()
  const hash = useRouterState({ select: (state) => state.location.hash })

  return (
    <RootProvider
      dir={languageDirection(lang)}
      theme={{ enabled: false }}
      search={{ SearchDialog: DocsSearchDialog }}
      i18n={{
        locale: lang,
        defaultLanguage: DEFAULT_LANGUAGE,
        hideLocale: i18n.hideLocale,
        translations: docsTranslations(lang),
        locales: i18n.languages.map((locale) => ({ locale, name: languageNames[locale] })),
        onLocaleChange: (next) => next === DEFAULT_LANGUAGE
          ? navigate({ to: '/docs/$', params: { _splat: slug }, hash: currentHeadingHash(hash) })
          : navigate({ to: '/$lang/docs/$', params: { lang: next, _splat: slug }, hash: currentHeadingHash(hash) }),
      }}
    >
      <DocsLayout
        {...docsLayoutOptions(lang)}
        tree={data.pageTree}
        containerProps={{ className: 'docs-layout' }}
        slots={{ languageSelect: { root: () => <LanguageSelect lang={lang} slug={slug} />, text: () => null } }}
      >
        <Suspense>{docsClientLoader.useContent(data.path, { lang, contentLanguage: data.contentLanguage })}</Suspense>
      </DocsLayout>
    </RootProvider>
  )
}
