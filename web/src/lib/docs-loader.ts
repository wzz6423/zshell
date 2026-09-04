import { notFound } from '@tanstack/react-router'
import { createIsomorphicFn } from '@tanstack/react-start'
import type { SerializedPageTree } from 'fumadocs-core/source/client'
import { buildDocsIndex, type DocsIndex } from '@/lib/docs-index'

/** What a docs route hands its component. */
export type DocsPageData = {
  path: string
  pageTree: SerializedPageTree
  meta: Array<Record<string, string>>
}

/**
 * One request per language for the whole session: every page in a language
 * shares its index, and the first page of all was prerendered with the index
 * already embedded.
 */
const inFlight = new Map<string, Promise<DocsIndex>>()

function fetchDocsIndex(lang: string): Promise<DocsIndex> {
  let pending = inFlight.get(lang)
  if (!pending) {
    pending = fetch(`/api/docs/${lang}`).then((res) => {
      if (!res.ok) throw notFound()
      return res.json() as Promise<DocsIndex>
    })
    // A failed fetch must not poison the language for the rest of the session.
    pending.catch(() => inFlight.delete(lang))
    inFlight.set(lang, pending)
  }
  return pending
}

/**
 * The index is read straight from the MDX collection while rendering, and from
 * the static JSON that same render produced once the browser takes over. The
 * compiler keeps each half out of the other's bundle.
 */
const docsIndex = createIsomorphicFn()
  .server((lang: string) => buildDocsIndex(lang))
  .client((lang: string) => fetchDocsIndex(lang))

/** Resolves one docs page. The browser fetches the compiled MDX for `path` itself. */
export async function loadDocsPage({
  slug,
  lang,
}: {
  slug: string
  lang: string
}): Promise<DocsPageData> {
  const index = await docsIndex(lang)
  const page = index.pages[slug]
  if (!page) throw notFound()

  return {
    path: page.path,
    pageTree: index.pageTree,
    meta: [
      { title: `${page.title} — Zshell` },
      ...(page.description ? [{ name: 'description', content: page.description }] : []),
    ],
  }
}
