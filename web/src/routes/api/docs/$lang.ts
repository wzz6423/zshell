import { createFileRoute } from '@tanstack/react-router'
import { buildDocsIndex } from '@/lib/docs-index'
import { isLanguage } from '@/lib/i18n'

/**
 * The docs metadata for one language, as JSON. Prerendered to the literal path
 * `api/docs/<lang>` (see vite.config.ts) so that client-side navigation between
 * docs pages needs a static file instead of a server.
 */
export const Route = createFileRoute('/api/docs/$lang')({
  server: {
    handlers: {
      GET: async ({ params }) => {
        if (!isLanguage(params.lang)) {
          return new Response('Not Found', { status: 404 })
        }

        return Response.json(await buildDocsIndex(params.lang))
      },
    },
  },
})
