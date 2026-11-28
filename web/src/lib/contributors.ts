import { createIsomorphicFn } from '@tanstack/react-start'
import { withBase } from '@/lib/utils'

const CONTRIBUTORS_URL =
  'https://api.github.com/repos/wzz6423/zshell/contributors?per_page=1&anon=1'

// Fallback used when GitHub's contributors endpoint or the prerendered
// `/api/contributors` JSON cannot be read.
export const FALLBACK_CONTRIBUTOR_COUNT = 2

function isValidContributorCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
}

/**
 * Extract the total contributor count from GitHub's `per_page=1` response.
 * With `per_page=1`, the `rel="last"` page number equals the total count;
 * single-page repositories omit `Link` and return a 0- or 1-item array
 * (or HTTP 204 when empty).
 */
export async function parseContributorCount(
  response: Response,
): Promise<number> {
  if (!response.ok) {
    console.error(
      `Failed to fetch contributors: ${response.status} ${response.statusText}`,
    )
    return FALLBACK_CONTRIBUTOR_COUNT
  }
  if (response.status === 204) return 0

  const lastPage = response.headers
    .get('link')
    ?.match(/[?&]page=(\d+)[^>]*>;\s*rel="last"/)?.[1]
  if (lastPage) {
    const count = Number(lastPage)
    if (isValidContributorCount(count)) return count
  }

  const contributors: unknown = await response.json()
  return Array.isArray(contributors)
    ? contributors.length
    : FALLBACK_CONTRIBUTOR_COUNT
}

/** Reads GitHub's contributors API. Runs while prerendering, never in a browser. */
export async function fetchContributorCount(): Promise<number> {
  try {
    const headers: Record<string, string> = {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'zshell.sh',
    }
    const token = process.env.GITHUB_TOKEN
    if (token) headers.Authorization = `Bearer ${token}`

    const response = await fetch(CONTRIBUTORS_URL, {
      headers,
      signal: AbortSignal.timeout(2500),
    })
    return await parseContributorCount(response)
  } catch (error) {
    console.error('Failed to fetch contributors:', error)
    return FALLBACK_CONTRIBUTOR_COUNT
  }
}

/**
 * Reads the prerendered `/api/contributors` JSON payload in the browser,
 * falling back cleanly without ever touching `process`.
 */
export async function fetchClientContributorCount(
  url: string = withBase('/api/contributors'),
  onError?: () => void,
): Promise<number> {
  try {
    const response = await fetch(url)
    if (!response.ok) {
      onError?.()
      return FALLBACK_CONTRIBUTOR_COUNT
    }
    const data: unknown = await response.json()
    if (
      typeof data === 'object' &&
      data !== null &&
      'count' in data &&
      isValidContributorCount(data.count)
    ) {
      return data.count
    }
    onError?.()
    return FALLBACK_CONTRIBUTOR_COUNT
  } catch {
    onError?.()
    return FALLBACK_CONTRIBUTOR_COUNT
  }
}

let cached: Promise<number> | undefined

/**
 * The contributor count the site was built against: read from GitHub while
 * prerendering, and from the JSON that render produced (`/api/contributors`)
 * once the browser navigates to `/changelog` itself. Calling GitHub directly
 * from the browser would crash on `process.env` and hit anonymous rate limits.
 */
export const loadContributorCount = createIsomorphicFn()
  .server(() => fetchContributorCount())
  .client(() => {
    if (!cached) {
      const pending = Promise.resolve().then(() =>
        fetchClientContributorCount(withBase('/api/contributors'), () => {
          if (cached === pending) cached = undefined
        }),
      )
      cached = pending
    }
    return cached
  })
