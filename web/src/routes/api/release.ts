import { createFileRoute } from '@tanstack/react-router'
import { fetchLatestRelease } from '@/lib/release'

/**
 * The release the site advertises, as JSON. Prerendered to the literal path
 * `api/release` (see vite.config.ts) so a landing page reached by client-side
 * navigation reads the same appcast the build did, from our own origin.
 */
export const Route = createFileRoute('/api/release')({
  server: {
    handlers: {
      GET: async () => Response.json(await fetchLatestRelease()),
    },
  },
})
