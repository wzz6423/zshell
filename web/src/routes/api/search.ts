import { createFileRoute } from '@tanstack/react-router'
import { createFromSource } from 'fumadocs-core/search/server'
import { source } from '@/lib/source'

// The default tokenizer is multilingual, so Chinese — which has no spaces to
// split on — is indexed word by word without any per-language configuration.
const server = createFromSource(source)

// `staticGET` serves the whole index instead of answering one query, so the site
// stays a pile of static files: it is prerendered to `api/search` at build time
// (see vite.config.ts) and searched in the browser.
export const Route = createFileRoute('/api/search')({
  server: {
    handlers: {
      GET: () => server.staticGET(),
    },
  },
})
