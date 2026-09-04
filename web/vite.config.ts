import { readdirSync } from 'node:fs'
import { defineConfig } from 'vite'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import viteReact from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import mdx from 'fumadocs-mdx/vite'
import { i18n } from './src/lib/i18n'

/**
 * Every docs URL, in every language, so the docs prerender as static pages
 * like the rest of the site. Derived from the filenames: `git.zh.mdx` is the
 * Chinese translation of `git.mdx`, not a page of its own, and a page missing
 * a translation still gets a URL because it falls back to English.
 */
function docsPages() {
  const slugs = readdirSync('content/docs')
    .filter((name) => name.endsWith('.mdx'))
    .map((name) => name.slice(0, -'.mdx'.length))
    .filter((name) => !name.includes('.'))
    .map((name) => (name === 'index' ? '' : `/${name}`))

  return i18n.languages.flatMap((lang) => {
    const prefix = lang === i18n.defaultLanguage ? '' : `/${lang}`
    return slugs.map((slug) => ({ path: `${prefix}/docs${slug}` }))
  })
}

export default defineConfig({
  server: { port: 3000 },
  resolve: { tsconfigPaths: true },
  plugins: [
    mdx(),
    tailwindcss(),
    tanstackStart({
      prerender: {
        enabled: true,
        autoStaticPathsDiscovery: false,
        crawlLinks: false,
      },
      pages: [
        // The landing pages, so the whole site ships as static files.
        { path: '/' },
        { path: '/zh' },
        { path: '/changelog' },
        // Not pages: the search index, the release the download buttons point
        // at, and the sidebar tree and titles for one language. Each response is
        // JSON rather than HTML, so it lands at its literal path — `api/search`
        // is where Fumadocs' static search client looks, and the other two are
        // what a page fetches when the browser navigates to it rather than
        // loading it as a prerendered document.
        { path: '/api/search' },
        { path: '/api/release' },
        ...i18n.languages.map((lang) => ({ path: `/api/docs/${lang}` })),
        ...docsPages(),
      ],
      sitemap: { enabled: false },
    }),
    viteReact(),
  ],
})
