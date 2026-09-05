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

Three of those URLs answer with JSON instead of a document, and are how a page
reached by client-side navigation gets what a server would otherwise have
computed for it: `/api/search` is the docs search index, `/api/release` is the
release the download buttons point at, and `/api/docs/<lang>` is the sidebar tree
and page titles for one language. Each is read straight from the source while
prerendering and fetched from the static file afterwards — see
[`src/lib/docs-loader.ts`](src/lib/docs-loader.ts) for the `createIsomorphicFn`
split that keeps the build-time half out of the browser bundle.

## Languages

Chinese is the default and stays unprefixed (`/`, `/docs/git`); English sits
under its own prefix (`/en`, `/en/docs/git`). The supported list
is [`src/lib/i18n.ts`](src/lib/i18n.ts).

**Landing page.** One [`HomePage`](src/components/home-page.tsx) rendered from
per-language strings in [`src/lib/home-copy.ts`](src/lib/home-copy.ts), with a
route per language: [`routes/index.tsx`](src/routes/index.tsx),
[`routes/en/index.tsx`](src/routes/en/index.tsx), and
[`routes/zh/index.tsx`](src/routes/zh/index.tsx). Spelling the routes out is
deliberate — a landing page under `/$lang` shares a chunk with `/$lang/docs`,
and once it also shares `HomePage` with `/`, the bundler folds the ~190 kB
Fumadocs bundle into the entry chunk that every page loads. Adding a language
means a route file plus an entry in `home-copy.ts` and in `HOME_ROUTES`
([`src/components/site-links.tsx`](src/components/site-links.tsx)).

**Docs.** MDX under [`content/docs`](content/docs), served by Fumadocs from a
single `/$lang/docs` route. A translation is the same filename with the
language inserted — `git.mdx` → `git.zh.mdx` — and a page with no translation
falls back to English instead of 404ing. Sidebar order and section headings
come from `meta.json` (`meta.zh.json` for the translated labels). A new
language also needs a UI language pack in
[`src/components/docs-shell.tsx`](src/components/docs-shell.tsx). Search needs
nothing: the engine's tokenizer is multilingual by default, so
[`src/routes/api/search.ts`](src/routes/api/search.ts) splits the index and
[`src/components/docs-search.tsx`](src/components/docs-search.tsx) splits the
query the same way, in any language, without either side being configured.

Docs pages are written for people using the app; see
[CONTRIBUTING.md](../CONTRIBUTING.md). Every docs URL is prerendered —
[`vite.config.ts`](vite.config.ts) derives the list from the filenames, so a new
page needs no config change.

## Notes

- The theme lives in [`src/styles/app.css`](src/styles/app.css) — a GitHub-dark
  palette that mirrors the macOS app (`mac/zshell/Theme.swift`). Fumadocs reads the
  same variables through `fumadocs-ui/css/shadcn.css`, so the docs inherit it.
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
- The site has no hero product shot yet. Add one under `public/` and reference
  it from `src/components/home-page.tsx` when it is ready.
