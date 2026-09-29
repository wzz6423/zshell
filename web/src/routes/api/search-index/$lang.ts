import { createFileRoute } from '@tanstack/react-router'
import { docsSearchIndex } from '@/lib/docs-search-index'
import { isLanguage, language } from '@/lib/i18n'

export const Route = createFileRoute('/api/search-index/$lang')({
  server: {
    handlers: {
      GET: ({ params }) => isLanguage(params.lang)
        ? docsSearchIndex(language(params.lang)).staticGET()
        : new Response(null, { status: 404 }),
    },
  },
})
