import { Suspense, lazy } from 'react'
import { useNavigate } from '@tanstack/react-router'
import browserCollections from 'collections/browser'
import { useFumadocsLoader } from 'fumadocs-core/source/client'
import { RootProvider } from 'fumadocs-ui/provider/tanstack'
import { i18nProvider, uiTranslations } from 'fumadocs-ui/i18n'
import { DocsLayout } from 'fumadocs-ui/layouts/docs'
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
} from 'fumadocs-ui/layouts/docs/page'
import { zhCN } from '@fumadocs/language/zh-cn'
import { getMDXComponents } from '@/components/docs-mdx'
import { docsLayoutOptions } from '@/lib/docs-layout'
import type { DocsPageData } from '@/lib/docs-loader'
import { DEFAULT_LANGUAGE, i18n } from '@/lib/i18n'

// The dialog, Orama, and the Chinese tokenizer: ~120 kB gzipped of code that a
// reader who never searches should not pay for, ahead of the index itself, which
// the first keystroke fetches. Fumadocs preloads the chunk on hover.
const DocsSearchDialog = lazy(() => import('@/components/docs-search'))

/**
 * The MDX for a page is fetched by the browser on demand — the server only
 * hands over the page's `path`. Shared by both language routes so a page
 * already fetched stays cached when you switch languages and back.
 */
export const docsClientLoader = browserCollections.docs.createClientLoader({
  component({ toc, frontmatter, default: MDX }) {
    return (
      <DocsPage toc={toc}>
        <DocsTitle>{frontmatter.title}</DocsTitle>
        <DocsDescription>{frontmatter.description}</DocsDescription>
        <DocsBody>
          <MDX components={getMDXComponents()} />
        </DocsBody>
      </DocsPage>
    )
  },
})

const translations = i18n.translations().extend(uiTranslations()).preset('zh', zhCN())

export function DocsShell({
  lang,
  slug,
  data: serialized,
}: {
  lang: string
  /** The splat after `/docs/`, used to stay on the same page across languages. */
  slug: string
  data: DocsPageData
}) {
  const data = useFumadocsLoader(serialized)
  const navigate = useNavigate()

  return (
    <RootProvider
      // The site is dark-only, so `<html class="dark">` is set once in the root
      // route; next-themes would only fight it.
      theme={{ enabled: false }}
      search={{ SearchDialog: DocsSearchDialog }}
      i18n={{
        ...i18nProvider(translations, lang),
        // The default handler assumes every locale is a URL prefix, but English
        // is unprefixed here (`hideLocale: 'default-locale'`).
        onLocaleChange: (next) =>
          next === DEFAULT_LANGUAGE
            ? navigate({ to: '/docs/$', params: { _splat: slug } })
            : navigate({ to: '/$lang/docs/$', params: { lang: next, _splat: slug } }),
      }}
    >
      <DocsLayout {...docsLayoutOptions(lang)} tree={data.pageTree}>
        <Suspense>{docsClientLoader.useContent(data.path)}</Suspense>
      </DocsLayout>
    </RootProvider>
  )
}
