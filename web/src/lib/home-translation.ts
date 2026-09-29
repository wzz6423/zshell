import type { HomeCopy } from './home-copy'
import { languageNames, type Language } from './i18n'

type Tuple<T, N extends number, R extends T[] = []> = R['length'] extends N ? R : Tuple<T, N, [...R, T]>
type Pair = [string, string]
type HomeTranslation = {
  title: string
  description: string
  nav: Tuple<string, 9>
  hero: Tuple<string, 6>
  preview: { label: string; tabs: Tuple<string, 3>; captions: Tuple<string, 3>; labels: Tuple<string, 10>; prompts: Tuple<string, 3> }
  actions: { skip: string; copy: string; copied: string; copyAria: string }
  featureTitle: string
  groups: Tuple<string, 4>
  features: Tuple<Pair, 16>
  shortcutsTitle: string
  allShortcuts: string
  shortcuts: Tuple<string, 19>
  download: { title: string; dmg: string; mirror: string; license: string }
  faq: Tuple<Pair, 5>
  builtBy: Pair
}

const keys = ['Cmd+N', 'Cmd+T', 'Cmd+W', 'Cmd+1–9', 'Ctrl+1–9', 'Ctrl+Tab', 'Cmd+P', 'Cmd+D / Cmd+Shift+D', 'Opt+Cmd+arrows', 'Cmd+[ / Cmd+]', 'Cmd+Shift+Return', 'Ctrl+Cmd+arrows / =', 'Cmd+B / Cmd+Shift+B', 'Cmd+Shift+G / E / I', 'Cmd+F / Cmd+G', 'Cmd+K', 'Cmd+S', 'Cmd+L / Cmd+R', 'Cmd+Shift+A']
const slugs = ['projects', 'files', 'automation', 'configuration']

/** Only technical identifiers are shared; every visible sentence is supplied by its locale. */
export function defineHomeCopy(lang: Language, t: HomeTranslation, changelog: string): HomeCopy {
  const [overview, sections, features, shortcuts, faq, docs, download, menuOpen, menuClose] = t.nav
  const [eyebrow, titleBefore, titleHighlight, titleAfter, lede, heroDownload] = t.hero
  const [projects, local, remote, files, changes, agents, running, attention, queue, docsAction] = t.preview.labels
  return {
    languageName: languageNames[lang], title: t.title, description: t.description,
    nav: { overview, sections, features, shortcuts, faq, docs, download, menuOpen, menuClose },
    hero: { eyebrow, titleBefore, titleHighlight, titleAfter, lede, download: heroDownload, docs: docsAction },
    preview: { label: t.preview.label, tabs: t.preview.tabs, captions: t.preview.captions, projects, local, remote, files, changes, agents, running, attention, queue, prompts: t.preview.prompts },
    skipLink: t.actions.skip, copy: t.actions.copy, copied: t.actions.copied, copyAria: t.actions.copyAria,
    features: { title: t.featureTitle, docsLink: docs, groups: t.groups.map((name, index) => ({ name, slug: slugs[index], rows: t.features.slice(index * 4, index * 4 + 4).map(([name, detail]) => ({ name, detail })) })) },
    shortcuts: { title: t.shortcutsTitle, docsLink: t.allShortcuts, rows: t.shortcuts.map((detail, index) => ({ name: keys[index], detail })) },
    download: { ...t.download, changelog },
    faq: { title: faq, items: t.faq.map(([q, a]) => ({ q, a })) },
    footerBuiltBy: { before: t.builtBy[0], after: t.builtBy[1] }, footerDocs: docs, footerChangelog: changelog,
  }
}
