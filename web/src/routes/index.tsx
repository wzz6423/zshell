import { createFileRoute } from '@tanstack/react-router'
import { HomePage } from '@/components/home-page'
import { homeCopy } from '@/lib/home-copy'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { loadRelease } from '@/lib/release'

/** The default Chinese landing page. Other languages live at `/$lang`. */
export const Route = createFileRoute('/')({
  component: Home,
  // Baked in at build time, so the site is redeployed after a release — see
  // `loadRelease`. It cannot change without one, hence no refetching.
  loader: () => loadRelease(),
  staleTime: Infinity,
  head: () => {
    const copy = homeCopy(DEFAULT_LANGUAGE)
    return {
      meta: [
        { title: copy.title },
        { name: 'description', content: copy.description },
      ],
    }
  },
})

function Home() {
  return <HomePage lang={DEFAULT_LANGUAGE} release={Route.useLoaderData()} />
}
