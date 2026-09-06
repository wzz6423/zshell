import { createIsomorphicFn } from '@tanstack/react-start'
import { withBase } from '@/lib/utils'

export type Release = {
  version: string
  minSystem: string
  dmg: string
  architecturePackages: boolean
}

export const GITHUB_URL = 'https://github.com/wzz6423/zshell'

export const GITEE_URL = 'https://gitee.com/wzz6423/zshell'
export const RELEASE_ARCHITECTURES = ['universal', 'arm64', 'x86_64'] as const
export type ReleaseArchitecture = (typeof RELEASE_ARCHITECTURES)[number]

const APPCAST_URLS = [
  `${GITEE_URL}/releases/download/update-release/appcast.xml`,
  `${GITHUB_URL}/releases/latest/download/appcast.xml`,
]

export const dmgUrl = (
  version: string,
  architecture: ReleaseArchitecture = 'universal',
  host: 'github' | 'gitee' = 'github',
) =>
  `${host === 'github' ? GITHUB_URL : GITEE_URL}/releases/download/v${version}/zshell-v${version}-macOS-${architecture}.dmg`

// Cask lives in wzz6423/homebrew-tap, so the tap has to be named explicitly.
// `--cask` is optional — brew falls back to casks, and the tap has no `zshell` formula.
export const BREW_COMMAND = 'brew install wzz6423/tap/zshell'

// What a build advertises when the appcast can't be reached. Keep it on the
// newest release: `minSystem` mirrors the app's MACOSX_DEPLOYMENT_TARGET.
const FALLBACK: Release = {
  version: '0.1.0',
  minSystem: '15.6',
  dmg: `${GITHUB_URL}/releases/download/v0.1.0/zshell-0.1.0.dmg`,
  architecturePackages: false,
}

/**
 * Pick the newest release out of the Sparkle appcast — the item with the highest
 * build number (`sparkle:version`). The site links the `.dmg` on the version's
 * release; each architecture's update enclosure points to that same version tag.
 */
function parseLatestRelease(xml: string): Release | null {
  let best: { build: number; version: string; minSystem: string; architecturePackages: boolean } | null = null
  for (const [, item] of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const version = item
      .match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1]
      ?.trim()
    if (!version) continue
    const build = Number(
      item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1]?.trim() ?? '0',
    )
    const minSystem = item
      .match(/<sparkle:minimumSystemVersion>([^<]+)<\/sparkle:minimumSystemVersion>/)?.[1]
      ?.trim()
    if (!best || build > best.build) {
      const enclosureURL = item.match(/<enclosure\b[^>]*\burl=["']([^"']+)["']/)?.[1]
      const architecturePackages = [GITHUB_URL, GITEE_URL].some((host) =>
        enclosureURL === `${host}/releases/download/v${version}/zshell-v${version}-macOS-universal.zip`,
      )
      best = { build, version, minSystem: minSystem || FALLBACK.minSystem, architecturePackages }
    }
  }
  if (!best) return null
  return {
    version: best.version,
    minSystem: best.minSystem,
    dmg: best.architecturePackages
      ? dmgUrl(best.version)
      : `${GITHUB_URL}/releases/download/v${best.version}/zshell-${best.version}.dmg`,
    architecturePackages: best.architecturePackages,
  }
}

/** Reads the appcast. Runs while the landing pages are rendered, never in a browser. */
export async function fetchLatestRelease(): Promise<Release> {
  for (const url of APPCAST_URLS) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(2500) })
      if (!res.ok) continue
      const release = parseLatestRelease(await res.text())
      if (release) return release
    } catch {
      // A mirror outage must not prevent the GitHub fallback from being tried.
    }
  }
  return FALLBACK
}

let cached: Promise<Release> | undefined

/**
 * The release the site was built against: read from the appcast while
 * prerendering, and from the JSON that render produced (`/api/release`) once
 * the browser navigates to a landing page itself. The appcast is on another
 * origin and sends no CORS headers, so the browser cannot read it directly —
 * and would silently fall back to `FALLBACK` if it tried.
 */
export const loadRelease = createIsomorphicFn()
  .server(() => fetchLatestRelease())
  .client(() => {
    cached ??= fetch(withBase('/api/release'))
      .then((res) => res.json() as Promise<Release>)
      .catch(() => {
        cached = undefined
        return FALLBACK
      })
    return cached
  })
