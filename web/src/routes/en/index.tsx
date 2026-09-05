import { createFileRoute } from '@tanstack/react-router'
import { HomePage } from '@/components/home-page'
import { homeCopy } from '@/lib/home-copy'
import { loadRelease } from '@/lib/release'

const LANG = 'en'

/** The explicit English landing page, while Chinese stays at the root URL. */
export const Route = createFileRoute('/en/')({
  component: Home,
  loader: () => loadRelease(),
  staleTime: Infinity,
  head: () => {
    const copy = homeCopy(LANG)
    return {
      meta: [
        { title: copy.title },
        { name: 'description', content: copy.description },
      ],
    }
  },
})

function Home() {
  return <HomePage lang={LANG} release={Route.useLoaderData()} />
}
