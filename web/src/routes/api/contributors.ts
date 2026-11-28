import { createFileRoute } from '@tanstack/react-router'
import { fetchContributorCount } from '@/lib/contributors'

/**
 * The repository contributor count, as JSON. Prerendered to the literal path
 * `api/contributors` (see vite.config.ts) so `/changelog` reached by
 * client-side navigation reads the same count the build did, from our own
 * origin.
 */
export const Route = createFileRoute('/api/contributors')({
  server: {
    handlers: {
      GET: async () => Response.json({ count: await fetchContributorCount() }),
    },
  },
})
