import { createFileRoute } from '@tanstack/react-router'
import { createFromSource } from 'fumadocs-core/search/server'
import { createTokenizer } from '@orama/tokenizers/mandarin'
import { source } from '@/lib/source'

// Chinese has no spaces to split on, so it needs its own tokenizer for the
// search index to contain anything but whole paragraphs.
const server = createFromSource(source, {
  localeMap: {
    en: 'english',
    zh: { tokenizer: createTokenizer() },
  },
})

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
