import { createFromSource } from 'fumadocs-core/search/server'
import { source } from '@/lib/source'
import type { Language } from '@/lib/i18n'

const servers = new Map<Language, ReturnType<typeof createFromSource>>()

export function docsSearchIndex(lang: Language) {
  let server = servers.get(lang)
  if (!server) {
    // Export only this language so opening search never downloads all 17 catalogs.
    server = createFromSource({ ...source, getPages: () => source.getPages(lang) })
    servers.set(lang, server)
  }
  return server
}
