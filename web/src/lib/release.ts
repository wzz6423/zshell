import { createIsomorphicFn } from '@tanstack/react-start'

export type Release = { version: string; minSystem: string; dmg: string }

const RELEASES_ORIGIN = 'https://releases.zshell.sh'
const APPCAST_URL = `${RELEASES_ORIGIN}/appcast.xml`

export const GITHUB_URL = 'https://github.com/wzz6423/zshell'

// Cask lives in wzz6423/homebrew-tap, so the tap has to be named explicitly.
// `--cask` is optional — brew falls back to casks, and the tap has no `zshell` formula.
export const BREW_COMMAND = 'brew install wzz6423/tap/zshell'

// What a build advertises when the appcast can't be reached. Keep it on the
// newest release: `minSystem` mirrors the app's MACOSX_DEPLOYMENT_TARGET.
const FALLBACK: Release = {
  version: '0.0.1',
  minSystem: '15.6',
  dmg: `${RELEASES_ORIGIN}/zshell-0.0.1.dmg`,
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
    dmg: `${RELEASES_ORIGIN}/zshell-${best.version}.dmg`,
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
    cached ??= fetch('/api/release')
      .then((res) => res.json() as Promise<Release>)
      .catch(() => {
        cached = undefined
        return FALLBACK
      })
    return cached
  })
