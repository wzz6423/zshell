import { createRouter, Link, useRouterState } from '@tanstack/react-router'
import { routeTree } from './routeTree.gen'
import { homePath, languageFromPath } from './lib/i18n'
import { uiCopy } from './lib/ui-copy'

export function getRouter() {
  return createRouter({
    routeTree,
    // Vite's `base`: every route lives under the subpath GitHub Pages serves
    // this repository from.
    basepath: import.meta.env.BASE_URL,
    scrollRestoration: true,
    defaultPreload: 'intent',
    defaultNotFoundComponent: NotFound,

  })
}

function NotFound() {
  const pathname = useRouterState({ select: (state) => state.location.pathname })
  const lang = languageFromPath(pathname)
  const copy = uiCopy(lang)
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4 font-mono text-sm">
      <p className="text-muted-foreground">404 — {copy.notFound}</p>
      <Link to={homePath(lang)} className="underline underline-offset-4 hover:text-foreground">{copy.backHome}</Link>
    </div>
  )
}
