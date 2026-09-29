import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared'
import { homePath } from '@/lib/i18n'
import { uiCopy } from '@/lib/ui-copy'
import { withBase } from '@/lib/utils'

const GITHUB_URL = 'https://github.com/wzz6423/zshell'

/** Chrome shared by every docs page: the zshell wordmark plus links back to the site. */
export function docsLayoutOptions(lang: string): BaseLayoutProps {
  const labels = uiCopy(lang)
  const home = homePath(lang)

  return {
    githubUrl: GITHUB_URL,
    // The site has no light mode, so a light/dark toggle would be a control
    // that does nothing.
    themeSwitch: { enabled: false },
    nav: {
      url: home,
      title: (
        <span className="inline-flex items-center gap-2">
          <img
            src={withBase('/zshell-icon.png')}
            alt=""
            width={1024}
            height={1024}
            className="size-6 rounded-[6px]"
          />
          <span className="font-mono font-bold tracking-[0.02em]">zshell</span>
        </span>
      ),
    },
    links: [
      { text: labels.changelog, url: '/changelog', active: 'url' },
      { type: 'button', text: labels.download, url: `${home}#download`, active: 'none' },
    ],
  }
}
