import { describe, expect, test } from 'bun:test'
import { readFileSync, readdirSync } from 'node:fs'
import { docsPath, homePath, i18n, isLanguage, language, languageDirection, languageFromPath, languageNames, languageTag, siteLocales } from '../src/lib/i18n'
import { docsTranslations, uiCopy } from '../src/lib/ui-copy'
import type { HomeCopy } from '../src/lib/home-copy'

const copies = Object.fromEntries(await Promise.all(i18n.languages.map(async (locale) => [locale, (await import(`../src/lib/home-copy/${locale}.ts`)).default as HomeCopy]))) as Record<string, HomeCopy>

function leaves(value: unknown, path = ''): Record<string, string> {
  if (typeof value === 'string') return { [path]: value }
  return Object.assign({}, ...Object.entries(value as Record<string, unknown>).map(([key, child]) => leaves(child, `${path}.${key}`)))
}

describe('language routes', () => {
  test('offers the same 17 canonical tags as the app and preserves Simplified Chinese URLs', () => {
    expect(siteLocales).toEqual(['zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'pt-BR', 'it', 'nl', 'ru', 'ar', 'th', 'id', 'vi', 'tr'])
    expect(new Set(i18n.languages).size).toBe(17)
    expect(homePath('zh')).toBe('/')
    expect(homePath('zh-Hans')).toBe('/')
    expect(docsPath('zh-Hans', 'git')).toBe('/docs/git')
    expect(docsPath('zh-Hant', 'git')).toBe('/zh-Hant/docs/git')
    expect(language('zh-Hant')).toBe('zh-Hant')
    expect(languageTag('zh')).toBe('zh-Hans')
    expect(isLanguage('unsupported')).toBe(false)
  })

  test('recognizes the Pages base path and sets direction only for Arabic', () => {
    for (const locale of i18n.languages) {
      expect(languageFromPath(`/zshell${homePath(locale)}`, '/zshell/')).toBe(locale)
      expect(languageFromPath(docsPath(locale, 'git'), '/zshell/')).toBe(locale)
      expect(languageDirection(locale)).toBe(locale === 'ar' ? 'rtl' : 'ltr')
    }
    expect(languageFromPath('/zshell/changelog', '/zshell/')).toBe('en')
    expect(languageFromPath('/zshell/zh-Hans', '/zshell/')).toBe('zh')
  })
})

describe('complete static translations', () => {
  const english = leaves(copies.en)
  for (const locale of i18n.languages) {
    test(`${locale}: complete homepage and navigation copy`, () => {
      const copy = copies[locale]
      expect(copy.languageName).toBe(languageNames[locale])
      const translated = leaves(copy)
      expect(Object.keys(translated).sort()).toEqual(Object.keys(english).sort())
      expect(copy.features.groups.map((group) => group.rows.length)).toEqual([4, 4, 4, 4])
      expect(copy.shortcuts.rows).toHaveLength(19)
      expect(copy.faq.items).toHaveLength(5)
      expect(copy.copyAria.match(/\{command\}/g)).toHaveLength(1)
      for (const [key, text] of Object.entries(translated)) {
        if (!['.hero.titleAfter', '.footerBuiltBy.before', '.footerBuiltBy.after'].includes(key)) expect(text.trim().length).toBeGreaterThan(0)
        if (locale !== 'en' && english[key].length > 40) expect(text).not.toBe(english[key])
      }
      expect(uiCopy(locale).language.length).toBeGreaterThan(0)
      expect(docsTranslations(locale)['Search(search dialog)']).toBe(uiCopy(locale).search)
      expect(docsTranslations(locale)['Next Page(pagination)']).toBe(uiCopy(locale).next)
      expect(docsTranslations(locale).displayName).toBe(languageNames[locale])
    })
  }

  test('every non-default home has an explicit route and independent translation module', () => {
    const routes = readdirSync(new URL('../src/routes/', import.meta.url))
    const translationFiles = readdirSync(new URL('../src/lib/home-copy/', import.meta.url))
    for (const locale of i18n.languages) {
      expect(routes).toContain(locale)
      expect(translationFiles).toContain(`${locale}.ts`)
    }
    expect(routes).toContain('zh-Hans')
  })
})

describe('translated documentation', () => {
  const directory = new URL('../content/docs/', import.meta.url)
  const files = readdirSync(directory)
  const originals = files.filter((file) => /^[^.]+\.mdx$/.test(file))

  for (const locale of i18n.languages) {
    test(`${locale}: every document has valid translated content`, () => {
      for (const original of originals) {
        const filename = locale === 'en' ? original : original.replace('.mdx', `.${locale}.mdx`)
        expect(files, filename).toContain(filename)
        const text = readFileSync(new URL(filename, directory), 'utf8')
        const frontmatter = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/)
        expect(frontmatter, filename).not.toBeNull()
        const metadata = Bun.YAML.parse(frontmatter![1]) as Record<string, unknown>
        expect(typeof metadata.title, filename).toBe('string')
        expect(typeof metadata.description, filename).toBe('string')
        expect(String(metadata.title).trim().length, filename).toBeGreaterThan(0)
        expect(String(metadata.description).trim().length, filename).toBeGreaterThan(0)
        const body = text.slice(frontmatter![0].length).trim()
        expect(body.length, filename).toBeGreaterThan(0)
        if (locale !== 'en') {
          const english = readFileSync(new URL(original, directory), 'utf8').replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '').trim()
          expect(body, filename).not.toBe(english)
        }
      }
    })
  }
})
