import { docsPath, homePath, i18n, language, languageTag, type Language } from './i18n'
import { withBase } from './utils'

const ORIGIN = 'https://wzz6423.github.io'
const openGraphLocales: Record<Language, string> = { zh: 'zh_CN', 'zh-Hant': 'zh_TW', en: 'en_US', ja: 'ja_JP', ko: 'ko_KR', fr: 'fr_FR', de: 'de_DE', es: 'es_ES', 'pt-BR': 'pt_BR', it: 'it_IT', nl: 'nl_NL', ru: 'ru_RU', ar: 'ar_AR', th: 'th_TH', id: 'id_ID', vi: 'vi_VN', tr: 'tr_TR' }

export function pageHead(lang: string, title: string, description?: string, slug?: string) {
  const pathFor = (locale: string) => slug === undefined ? homePath(locale) : docsPath(locale, slug)
  const url = (locale: string) => `${ORIGIN}${withBase(pathFor(locale))}`
  return {
    meta: [
      { title },
      ...(description ? [{ name: 'description', content: description }, { property: 'og:description', content: description }] : []),
      { property: 'og:title', content: title },
      { property: 'og:url', content: url(lang) },
      { property: 'og:type', content: 'website' },
      { property: 'og:locale', content: openGraphLocales[language(lang)] },
      { property: 'og:image', content: `${ORIGIN}${withBase('/zshell-icon.png')}` },
    ],
    links: [
      { rel: 'canonical', href: url(lang) },
      ...i18n.languages.map((locale) => ({ rel: 'alternate', hrefLang: languageTag(locale), href: url(locale) })),
      { rel: 'alternate', hrefLang: 'x-default', href: url(i18n.defaultLanguage) },
    ],
  }
}
