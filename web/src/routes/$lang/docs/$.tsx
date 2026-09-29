import { createFileRoute, redirect, notFound } from '@tanstack/react-router'
import { DocsShell, docsClientLoader } from '@/components/docs-shell'
import { DEFAULT_LANGUAGE, isLanguage, language } from '@/lib/i18n'
import { loadDocsPage } from '@/lib/docs-loader'

/** Non-default docs, e.g. `/en/docs/git`. Chinese is unprefixed — see `/docs/$`. */
export const Route = createFileRoute('/$lang/docs/$')({
  component: Page,
  beforeLoad: ({ params }) => {
    // Chinese is served without a prefix, so `/zh/docs/…` would otherwise be a
    // second URL for a page that already lives at `/docs/…`.
    if (!isLanguage(params.lang)) throw notFound()
    if (language(params.lang) === DEFAULT_LANGUAGE) {
      throw redirect({
        to: '/docs/$',
        params: { _splat: params._splat ?? '' },
        statusCode: 301,
      })
    }
  },
  loader: async ({ params }) => {
    const data = await loadDocsPage({
      slug: params._splat ?? '',
      lang: params.lang,
    })
    await docsClientLoader.preload(data.path)
    return data
  },
  head: ({ loaderData }) => loaderData?.head ?? {},
})

function Page() {
  const { lang, _splat } = Route.useParams()
  return <DocsShell lang={lang} slug={_splat ?? ''} data={Route.useLoaderData()} />
}
