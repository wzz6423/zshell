# Zshell — website

Landing page and documentation for **Zshell**, the native terminal workspace for
macOS.

## Stack

- [TanStack Start](https://tanstack.com/start) (React 19 + Vite 8)
- [Tailwind CSS v4](https://tailwindcss.com)
- [shadcn/ui](https://ui.shadcn.com) with **Base UI** primitives (`@base-ui/react`)
- [Fumadocs](https://fumadocs.dev) for `/docs`
- Prerendered to static files and deployed to
  [GitHub Pages](https://docs.github.com/pages)

## Develop

Run these commands from `web/`; dependencies are locked by `web/bun.lock`.

```sh
bun install --frozen-lockfile
bun run dev        # http://localhost:3000
bun run typecheck  # tsc --noEmit
bun test           # locale routes and complete static copy
```

## Deploy (GitHub Pages)

Pushing to `main` deploys — [`.github/workflows/web-pages.yml`](../.github/workflows/web-pages.yml)
builds the site and uploads it. There is nothing to deploy by hand.

The site answers on **<https://wzz6423.github.io/zshell/>**. A Pages project site
is served from the repository name rather than the domain root, so every URL the
site emits needs that prefix: [`vite.config.ts`](vite.config.ts) sets
`base: '/zshell/'`, and [`src/router.tsx`](src/router.tsx) hands the same value
to `basepath` by reading it back out of `import.meta.env.BASE_URL` — one place to
change, and changing it is all a move to another path or a custom domain takes
(plus a `public/CNAME` naming the host, and the domain in *Settings → Pages*).

Vite rewrites what it can see, which is the imports and the router's links. A
literal path is opaque to it, so anything else — a file in `public/`, or one of
the JSON endpoints below fetched by hand — goes through `withBase()`
([`src/lib/utils.ts`](src/lib/utils.ts)); without it the URL resolves against the
domain root and 404s. Both web workflows assert the built `index.html` still
carries the prefix, because a site that loses it deploys and then renders
nothing.

The prefix lives *inside* the built files, not in the paths they sit at:
prerendering writes `/docs` to `dist/client/docs/index.html`, and Pages serves
that whole directory at `/zshell/`. So `dist/client` is uploaded as-is.

Downloads are not part of this: the DMGs and the appcast are GitHub Release
assets, and the site only links them (see [`src/lib/release.ts`](src/lib/release.ts)).

[`public/.nojekyll`](public/.nojekyll) is there because the build emits asset
chunks whose names start with `_`, which Jekyll hides. Artifact deploys do not
run Jekyll, so this is belt-and-braces against ever serving the site another way.

`bun run build` writes two directories. `dist/client` is the site: every URL as a
static file, and the only thing Pages serves. `dist/server` is the bundle that
prerendering renders those files against — a build artifact, never deployed.
`bun run preview` serves the result locally.

Nothing runs at request time, so a new URL has to be listed in
[`vite.config.ts`](vite.config.ts) to exist at all.

Three endpoint families answer with JSON instead of a document, and are how a page
reached by client-side navigation gets what a server would otherwise have
computed for it: `/api/search` is the default-language search index,
`/api/search-index/<lang>` serves each other language, `/api/release` is the
release the download buttons point at, and `/api/docs/<lang>` is the sidebar tree
and page titles for one language. Each is read straight from the source while
prerendering and fetched from the static file afterwards — see
[`src/lib/docs-loader.ts`](src/lib/docs-loader.ts) for the `createIsomorphicFn`
split that keeps the build-time half out of the browser bundle.

## Languages

Simplified Chinese remains the default at `/` and `/docs/git`. The other
16 languages use their canonical language tags, for example `/ja`, `/pt-BR`,
and `/zh-Hant/docs/git`. The list in [`src/lib/i18n.ts`](src/lib/i18n.ts)
matches the app: Simplified and Traditional Chinese, English, Japanese, Korean,
French, German, Spanish, Brazilian Portuguese, Italian, Dutch, Russian, Arabic,
Thai, Indonesian, Vietnamese, and Turkish.

The internal code `zh` preserves existing `.zh.mdx` filenames and default URLs.
The `/zh` and `/zh-Hans` landing pages remain aliases of `/`; their canonical
link points to `/`, and HTML language tags and alternate links use `zh-Hans`.
Traditional Chinese uses `zh-Hant` throughout and never resolves to Simplified
Chinese. The changelog is generated from the English root changelog and is
identified as English.

**Landing page.** One [`HomePage`](src/components/home-page.tsx) renders the
complete static copy in [`src/lib/home-copy/`](src/lib/home-copy/). Each language
has an explicit route and its own dynamically loaded translation chunk. Keep
those explicit routes: using `/$lang` for the homepage can merge the Fumadocs
branch into the landing-page entry. Add a translation module, route, and entry
in the locale registry together. `bun test` checks that all languages include
the complete feature, shortcut, FAQ, navigation, and preview copy.

**Navigation.** The shared native language selector works on narrow screens
and with a keyboard. Switching within docs preserves the page slug and heading
anchor. Arabic sets HTML and Fumadocs to RTL; terminal output, commands, keyboard
shortcuts, and code blocks retain LTR ordering. Page titles, descriptions,
canonical URLs, Open Graph metadata, and language alternates follow the selected
locale.

**Docs.** MDX is under [`content/docs`](content/docs). A translation keeps the
English filename and adds its internal language code: `git.mdx` becomes
`git.ja.mdx`, `git.zh-Hant.mdx`, or `git.zh.mdx`. Sidebar order and group labels
come from `meta.<lang>.json`. Titles and descriptions come from the translated
frontmatter; preserve explicit heading IDs when translating headings so links
stay valid across languages. Missing translations fall back to English with a
localized notice and English content-language attributes. Navigation, table of
contents controls, pagination, copying, and search UI use
[`src/lib/ui-copy.ts`](src/lib/ui-copy.ts).

Search runs locally against the selected language's prerendered index, so
opening search does not download the other 16 languages. The multilingual tokenizer
is shared by [`src/lib/docs-search-index.ts`](src/lib/docs-search-index.ts) and
[`src/components/docs-search.tsx`](src/components/docs-search.tsx), and the
selected locale chooses the corresponding index.

Docs pages are written for people using the app; see
[CONTRIBUTING.md](../CONTRIBUTING.md). Every docs URL is prerendered —
[`vite.config.ts`](vite.config.ts) derives the list from the filenames, so a new
page needs no config change.

## Notes

- The theme lives in [`src/styles/app.css`](src/styles/app.css). Documentation
  uses the shared GitHub palette through `fumadocs-ui/css/shadcn.css`; the landing
  page scopes its monochrome palette and terminal-green accent to `.home-page`.
- Add more components with `bunx shadcn@latest add <name>` — the project is
  already configured for Base UI (`components.json` → `"style": "base-nova"`).
- Landing pages read the newest release from the Sparkle appcast through
  [`src/lib/release.ts`](src/lib/release.ts), while they are prerendered — the
  appcast is on another origin and sends no CORS headers, so a browser could not
  read it anyway. A release therefore only reaches the site once it is rebuilt,
  which `mac/scripts/release.ts` triggers for us (see
  [RELEASING.md](../mac/RELEASING.md)). Keep the fallback release in that file
  current: it is what a build advertises when the appcast is unreachable.
- [`public/zshell-icon.png`](public/zshell-icon.png) is the shared Logo,
  favicon, and Apple touch icon. It is used by the root route and the site,
  docs, and landing-page navigation — through `withBase()`, like every other
  file in `public/`.
- The landing page uses a labeled workspace illustration with terminal, code
  review, and agent views. It is rendered in CSS, not a screenshot or a live
  terminal. Copy and captions for all 17 languages live in `src/lib/home-copy/`.
