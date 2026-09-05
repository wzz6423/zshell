import { createRouter, Link } from '@tanstack/react-router'
import { routeTree } from './routeTree.gen'

export function getRouter() {
  return createRouter({
    routeTree,
    // Vite's `base`: every route lives under the subpath GitHub Pages serves
    // this repository from.
    basepath: import.meta.env.BASE_URL,
    scrollRestoration: true,
    defaultPreload: 'intent',
    defaultNotFoundComponent: () => (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 font-mono text-sm">
        <p className="text-muted-foreground">404 — not found</p>
        <Link to="/" className="underline underline-offset-4 hover:text-foreground">
          ← back to zshell
        </Link>
      </div>
    ),
  })
}
