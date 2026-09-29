import { createFileRoute } from '@tanstack/react-router'
import { HomePage } from '@/components/home-page'
import { loadHomePage } from '@/lib/home-loader'
import { pageHead } from '@/lib/page-head'

const LANG = 'ru'

export const Route = createFileRoute('/ru/')({
  component: Home,
  loader: () => loadHomePage(LANG),
  staleTime: Infinity,
  head: ({ loaderData }) => loaderData ? pageHead(LANG, loaderData.copy.title, loaderData.copy.description) : {},
})

function Home() {
  const data = Route.useLoaderData()
  return <HomePage lang={LANG} release={data.release} copy={data.copy} />
}
