import { homeCopy } from './home-copy'
import { loadRelease } from './release'

export async function loadHomePage(lang: string) {
  const [copy, release] = await Promise.all([homeCopy(lang), loadRelease()])
  return { copy, release }
}
