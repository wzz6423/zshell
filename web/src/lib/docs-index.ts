import type { SerializedPageTree } from 'fumadocs-core/source/client'
import { source } from '@/lib/source'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'

/** One docs page, minus the MDX the browser fetches for itself. */
export type DocsIndexEntry = {
  path: string
  title: string
  description?: string
}

/**
 * Everything the docs routes need about a language: the sidebar tree, and the
 * pages keyed by the splat after `/docs/` (the index page is the empty string).
 */
export type DocsIndex = {
  pageTree: SerializedPageTree
  pages: Record<string, DocsIndexEntry>
}

/**
 * Reads the index out of the MDX collection. Only ever runs where the
 * collection exists — during a build, or in the dev server — and reaches the
 * browser as the prerendered JSON at `/api/docs/<lang>`.
 *
 * The URLs come from the default language, the same assumption `docsPages()`
 * in `vite.config.ts` makes: a translation is a variant of an English page, so
 * a page missing one falls back rather than disappearing.
 */
export async function buildDocsIndex(lang: string): Promise<DocsIndex> {
  const pages: Record<string, DocsIndexEntry> = {}

  for (const canonical of source.getPages(DEFAULT_LANGUAGE)) {
    const page = source.getPage(canonical.slugs, lang) ?? canonical
    pages[canonical.slugs.join('/')] = {
      path: page.path,
      title: page.data.title,
      ...(page.data.description ? { description: page.data.description } : {}),
    }
  }

  return {
    pageTree: await source.serializePageTree(source.getPageTree(lang)),
    pages,
  }
}
