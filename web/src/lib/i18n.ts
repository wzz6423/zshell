import { defineI18n } from 'fumadocs-core/i18n'

/**
 * Docs languages. Chinese is the default and stays unprefixed (`/docs/...`);
 * every other language sits under its own prefix (`/en/docs/...`).
 *
 * Translations live beside their English original as `<name>.<lang>.mdx`.
 * A page with no translation falls back to the English one rather than 404ing.
 */
export const i18n = defineI18n({
  defaultLanguage: 'zh',
  languages: ['zh', 'en'],
  hideLocale: 'default-locale',
})

export const DEFAULT_LANGUAGE = i18n.defaultLanguage

export function isLanguage(value: string | undefined): boolean {
  return value !== undefined && (i18n.languages as string[]).includes(value)
}
