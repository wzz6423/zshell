import { createFileRoute } from '@tanstack/react-router'
import { docsSearchIndex } from '@/lib/docs-search-index'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'

// `staticGET` serves the whole index instead of answering one query, so the site
// stays a pile of static files: it is prerendered to `api/search` at build time
// (see vite.config.ts) and searched in the browser.
export const Route = createFileRoute('/api/search')({
  server: {
    handlers: {
      GET: () => docsSearchIndex(DEFAULT_LANGUAGE).staticGET(),
    },
  },
})
