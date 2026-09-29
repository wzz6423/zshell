import { defineI18n } from 'fumadocs-core/i18n'

/** Canonical tags match the macOS language picker. `zh` keeps existing docs filenames and URLs. */
export const siteLocales = ['zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'pt-BR', 'it', 'nl', 'ru', 'ar', 'th', 'id', 'vi', 'tr'] as const
export type SiteLocale = (typeof siteLocales)[number]
export type Language = Exclude<SiteLocale, 'zh-Hans'> | 'zh'

export const languageNames: Record<Language, string> = {
  zh: '简体中文', 'zh-Hant': '繁體中文', en: 'English', ja: '日本語', ko: '한국어',
  fr: 'Français', de: 'Deutsch', es: 'Español', 'pt-BR': 'Português (Brasil)', it: 'Italiano',
  nl: 'Nederlands', ru: 'Русский', ar: 'العربية', th: 'ไทย', id: 'Bahasa Indonesia', vi: 'Tiếng Việt', tr: 'Türkçe',
}

export const DEFAULT_LANGUAGE = 'zh' as const

export const i18n = defineI18n({
  defaultLanguage: DEFAULT_LANGUAGE,
  languages: siteLocales.map((locale): Language => locale === 'zh-Hans' ? 'zh' : locale),
  hideLocale: 'default-locale',
})

export function isLanguage(value: string | undefined): value is Language | 'zh-Hans' {
  return value === 'zh-Hans' || (value !== undefined && (i18n.languages as string[]).includes(value))
}

export function language(value: string | undefined): Language {
  if (!isLanguage(value) || value === 'zh-Hans') return DEFAULT_LANGUAGE
  return value
}

export function languageTag(value: string): SiteLocale {
  const locale = language(value)
  return locale === 'zh' ? 'zh-Hans' : locale
}

export function languageDirection(value: string): 'ltr' | 'rtl' {
  return language(value) === 'ar' ? 'rtl' : 'ltr'
}

export function homePath(value: string): '/' | `/${Exclude<Language, 'zh'>}` {
  const locale = language(value)
  return locale === DEFAULT_LANGUAGE ? '/' : `/${locale}`
}

export function docsPath(value: string, slug = ''): string {
  const prefix = homePath(value).replace(/\/$/, '')
  return `${prefix}/docs${slug ? `/${slug}` : ''}`
}

/** Router locations may include the GitHub Pages base path. */
export function languageFromPath(pathname: string, base = import.meta.env.BASE_URL): Language {
  const path = base && pathname.startsWith(base) ? pathname.slice(base.length) : pathname
  const prefix = path.replace(/^\//, '').split('/')[0]
  return prefix === 'changelog' ? 'en' : language(prefix)
}
