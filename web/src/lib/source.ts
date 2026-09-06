import { createGetUrl, loader } from 'fumadocs-core/source'
import { docs } from 'collections/server'
import { i18n } from '@/lib/i18n'

export const source = loader({
  source: docs.toFumadocsSource(),
  baseUrl: '/docs',
  // Unsuffixed MDX files are English; public URLs still default to Chinese.
  i18n: { ...i18n, defaultLanguage: 'en' },
  url: createGetUrl('/docs', i18n),
})
