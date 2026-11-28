import { afterEach, describe, expect, test } from 'bun:test'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import {
  FALLBACK_CONTRIBUTOR_COUNT,
  fetchClientContributorCount,
  fetchContributorCount,
  parseContributorCount,
} from '../src/lib/contributors'

const originalFetch = globalThis.fetch
const originalConsoleError = console.error
const originalGithubToken = process.env.GITHUB_TOKEN

function restoreEnvironment() {
  globalThis.fetch = originalFetch
  console.error = originalConsoleError
  if (originalGithubToken === undefined) {
    delete process.env.GITHUB_TOKEN
  } else {
    process.env.GITHUB_TOKEN = originalGithubToken
  }
}

function mockFetch(
  handler: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>,
) {
  globalThis.fetch = handler as unknown as typeof fetch
}

afterEach(restoreEnvironment)

describe('parseContributorCount', () => {
  test('extracts the total count from GitHub Link rel="last" pagination', async () => {
    const response = new Response('[{"login":"alice"}]', {
      status: 200,
      headers: {
        Link: '<https://api.github.com/repositories/1/contributors?per_page=1&anon=1&page=2>; rel="next", <https://api.github.com/repositories/1/contributors?per_page=1&anon=1&page=17>; rel="last"',
      },
    })
    expect(await parseContributorCount(response)).toBe(17)
  })

  test('returns 0 for HTTP 204 No Content', async () => {
    const response = new Response(null, { status: 204 })
    expect(await parseContributorCount(response)).toBe(0)
  })

  test('counts array entries when the Link header is absent', async () => {
    const single = new Response(JSON.stringify([{ login: 'alice' }]), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
    const empty = new Response(JSON.stringify([]), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
    expect(await parseContributorCount(single)).toBe(1)
    expect(await parseContributorCount(empty)).toBe(0)
  })

  test('falls back on non-array JSON or non-OK responses', async () => {
    console.error = () => {}

    const nonArray = new Response(JSON.stringify({ message: 'unexpected' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
    const rateLimited = new Response('rate limit exceeded', {
      status: 403,
      statusText: 'Forbidden',
    })

    expect(await parseContributorCount(nonArray)).toBe(
      FALLBACK_CONTRIBUTOR_COUNT,
    )
    expect(await parseContributorCount(rateLimited)).toBe(
      FALLBACK_CONTRIBUTOR_COUNT,
    )
  })
})

describe('fetchContributorCount', () => {
  test('sends GitHub headers and Bearer token when GITHUB_TOKEN is set', async () => {
    process.env.GITHUB_TOKEN = 'test-token-value'
    let capturedHeaders: Record<string, string> | undefined
    let capturedUrl = ''

    mockFetch(async (input, init) => {
      capturedUrl = String(input)
      capturedHeaders = init?.headers as Record<string, string>
      return new Response('[{"login":"alice"}]', {
        status: 200,
        headers: {
          Link: '<https://api.github.com/repositories/1/contributors?per_page=1&anon=1&page=9>; rel="last"',
        },
      })
    })

    expect(await fetchContributorCount()).toBe(9)
    expect(capturedUrl).toContain(
      'https://api.github.com/repos/wzz6423/zshell/contributors',
    )
    expect(capturedHeaders?.Accept).toBe('application/vnd.github+json')
    expect(capturedHeaders?.['User-Agent']).toBe('zshell.sh')
    expect(capturedHeaders?.Authorization).toBe('Bearer test-token-value')
  })

  test('omits Authorization when GITHUB_TOKEN is unset and falls back on network failure', async () => {
    delete process.env.GITHUB_TOKEN
    console.error = () => {}

    let capturedHeaders: Record<string, string> | undefined
    mockFetch(async (_input, init) => {
      capturedHeaders = init?.headers as Record<string, string>
      return new Response(JSON.stringify([{ login: 'alice' }]), {
        status: 200,
      })
    })
    expect(await fetchContributorCount()).toBe(1)
    expect(capturedHeaders?.Authorization).toBeUndefined()

    mockFetch(async () => {
      throw new Error('network down')
    })
    expect(await fetchContributorCount()).toBe(FALLBACK_CONTRIBUTOR_COUNT)
  })
})

describe('fetchClientContributorCount', () => {
  test('reads prerendered /api/contributors JSON with no process global', async () => {
    const requestedUrls: string[] = []
    mockFetch(async (input) => {
      requestedUrls.push(String(input))
      return Response.json({ count: 12 })
    })

    const savedDescriptor = Object.getOwnPropertyDescriptor(
      globalThis,
      'process',
    )
    Reflect.deleteProperty(globalThis, 'process')
    try {
      expect(typeof globalThis.process).toBe('undefined')
      const count = await fetchClientContributorCount(
        '/zshell/api/contributors',
      )
      expect(count).toBe(12)
    } finally {
      if (savedDescriptor) {
        Object.defineProperty(globalThis, 'process', savedDescriptor)
      }
    }

    expect(requestedUrls).toEqual(['/zshell/api/contributors'])
  })

  test('accepts zero contributors from the prerendered endpoint', async () => {
    mockFetch(async () => Response.json({ count: 0 }))
    expect(await fetchClientContributorCount('/zshell/api/contributors')).toBe(
      0,
    )
  })

  test('falls back and reports errors on failed fetch, non-OK HTTP, or invalid payloads', async () => {
    let errors = 0
    const onError = () => {
      errors += 1
    }

    mockFetch(async () => {
      throw new Error('offline')
    })
    expect(
      await fetchClientContributorCount('/zshell/api/contributors', onError),
    ).toBe(FALLBACK_CONTRIBUTOR_COUNT)

    mockFetch(
      async () => new Response('missing', { status: 404, statusText: 'Not Found' }),
    )
    expect(
      await fetchClientContributorCount('/zshell/api/contributors', onError),
    ).toBe(FALLBACK_CONTRIBUTOR_COUNT)

    mockFetch(async () => new Response('not-json', { status: 200 }))
    expect(
      await fetchClientContributorCount('/zshell/api/contributors', onError),
    ).toBe(FALLBACK_CONTRIBUTOR_COUNT)

    for (const payload of [
      {},
      { count: '12' },
      { count: -1 },
      { count: null },
      null,
    ]) {
      mockFetch(async () => Response.json(payload))
      expect(
        await fetchClientContributorCount('/zshell/api/contributors', onError),
      ).toBe(FALLBACK_CONTRIBUTOR_COUNT)
    }

    expect(errors).toBe(8)
  })
})

const distClientDir = new URL('../dist/client/', import.meta.url)
const hasBuiltClient = existsSync(distClientDir)

describe('prerendered changelog contributor artifacts', () => {
  test.skipIf(!hasBuiltClient)(
    'prerenders /api/contributors JSON and keeps GITHUB_TOKEN and server fetch out of client bundles',
    () => {
      const apiPath = new URL('api/contributors', distClientDir)
      expect(existsSync(apiPath)).toBe(true)

      const payload: unknown = JSON.parse(readFileSync(apiPath, 'utf8'))
      expect(typeof payload).toBe('object')
      expect(payload).not.toBeNull()
      const count = (payload as { count?: unknown }).count
      expect(typeof count).toBe('number')
      expect(Number.isFinite(count)).toBe(true)
      expect(count as number).toBeGreaterThanOrEqual(0)

      const assetsDir = new URL('assets/', distClientDir)
      const jsAssets = readdirSync(assetsDir).filter((name) =>
        name.endsWith('.js'),
      )
      expect(jsAssets.length).toBeGreaterThan(0)

      let referencesContributorsEndpoint = false
      for (const file of jsAssets) {
        const content = readFileSync(new URL(file, assetsDir), 'utf8')
        expect(content, file).not.toContain('GITHUB_TOKEN')
        expect(content, file).not.toContain('process.env')
        expect(content, file).not.toContain('api.github.com')
        if (content.includes('/api/contributors')) {
          referencesContributorsEndpoint = true
        }
      }
      expect(referencesContributorsEndpoint).toBe(true)
    },
  )
})
