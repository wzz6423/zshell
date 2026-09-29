import { language, type Language } from './i18n'

export type Row = { name: string; detail: string }
export type FeatureGroup = { name: string; slug: string; rows: Row[] }

export type HomeCopy = {
  /** Display name of this language, for the language selector. */
  languageName: string
  title: string
  description: string
  nav: {
    overview: string
    sections: string
    features: string
    shortcuts: string
    faq: string
    docs: string
    download: string
    menuOpen: string
    menuClose: string
  }
  hero: {
    eyebrow: string
    /** The title is one sentence with a highlighted phrase in the middle. */
    titleBefore: string
    titleHighlight: string
    titleAfter: string
    lede: string
    download: string
    docs: string
  }
  preview: {
    label: string
    tabs: [string, string, string]
    captions: [string, string, string]
    projects: string
    local: string
    remote: string
    files: string
    changes: string
    agents: string
    running: string
    attention: string
    queue: string
    prompts: [string, string, string]
  }
  skipLink: string
  copy: string
  copied: string
  copyAria: string
  features: {
    title: string
    docsLink: string
    groups: FeatureGroup[]
  }
  shortcuts: {
    title: string
    docsLink: string
    /**
     * Modifiers are spelled out rather than set as ⌘/⇧/⌥/⌃. Geist Mono ships no
     * subset covering U+2318, U+21E7, U+2325, or U+2303, so those glyphs always
     * fall back to another family mid-word — thinner, differently sized, and off
     * the mono grid — and go missing entirely on most non-Apple systems.
     */
    rows: Row[]
  }
  download: {
    title: string
    dmg: string
    mirror: string
    changelog: string
    license: string
  }
  faq: {
    title: string
    items: { q: string; a: string }[]
  }
  /** The author's name is a link, so the credit is split around it. */
  footerBuiltBy: { before: string; after: string }
  footerDocs: string
  footerChangelog: string
}

const translations = import.meta.glob<{ default: HomeCopy }>('./home-copy/*.ts')

/** Each locale is its own chunk, so visitors only download their selected language. */
export async function homeCopy(lang: string): Promise<HomeCopy> {
  const locale: Language = language(lang)
  const load = translations[`./home-copy/${locale}.ts`]
  if (!load) throw new Error(`Missing home translation: ${locale}`)
  return (await load()).default
}
