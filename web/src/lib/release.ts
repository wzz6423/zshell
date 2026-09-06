import { createIsomorphicFn } from '@tanstack/react-start'
import { withBase } from '@/lib/utils'

export type Release = { version: string; minSystem: string; dmg: string }

export const GITHUB_URL = 'https://github.com/wzz6423/zshell'

// Releases are GitHub Release assets: the feed and the update archives sit on
// the permanent `updates` release, each version's DMG on its own `v<version>`.
const APPCAST_URL = `${GITHUB_URL}/releases/download/updates/appcast.xml`
const dmgUrl = (version: string) =>
  `${GITHUB_URL}/releases/download/v${version}/zshell-${version}.dmg`

// Cask lives in wzz6423/homebrew-tap, so the tap has to be named explicitly.
// `--cask` is optional — brew falls back to casks, and the tap has no `zshell` formula.
export const BREW_COMMAND = 'brew install wzz6423/tap/zshell'

// What a build advertises when the appcast can't be reached. Keep it on the
// newest release: `minSystem` mirrors the app's MACOSX_DEPLOYMENT_TARGET.
const FALLBACK: Release = {
  version: '0.1.0',
  minSystem: '15.6',
  dmg: dmgUrl('0.1.0'),
}

/**
 * Pick the newest release out of the Sparkle appcast — the item with the highest
 * build number (`sparkle:version`). The site links the notarized `.dmg`, which
 * sits beside the `.zip` update enclosure at `zshell-<version>.dmg`.
 */
function parseLatestRelease(xml: string): Release | null {
  let best: { build: number; version: string; minSystem: string } | null = null
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
      best = { build, version, minSystem: minSystem || FALLBACK.minSystem }
    }
  }
  if (!best) return null
  return {
    version: best.version,
    minSystem: best.minSystem,
    dmg: dmgUrl(best.version),
  }
}

/** Reads the appcast. Runs while the landing pages are rendered, never in a browser. */
export async function fetchLatestRelease(): Promise<Release> {
  try {
    const res = await fetch(APPCAST_URL, { signal: AbortSignal.timeout(2500) })
    if (!res.ok) return FALLBACK
    return parseLatestRelease(await res.text()) ?? FALLBACK
  } catch {
    return FALLBACK
  }
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
