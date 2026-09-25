import type { ReactNode } from 'react'
import { SiteFooter } from '@/components/site-footer'
import { HomeLink } from '@/components/site-links'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { withBase } from '@/lib/utils'

export function SiteLayout({
  children,
  headerContent,
  lang = DEFAULT_LANGUAGE,
}: {
  children: ReactNode
  headerContent?: ReactNode
  lang?: string
}) {
  return (
    <main className="home-container flex flex-col gap-14 pt-16 pb-20 font-mono text-[14px] leading-[1.6]">
      <header className="flex flex-col gap-3">
        <h1 className="text-2xl font-bold tracking-[0.02em]">
          <HomeLink lang={lang} className="flex items-center gap-2.5">
            <img
              src={withBase('/zshell-icon.png')}
              alt=""
              width={1024}
              height={1024}
              className="size-7 rounded-[7px]"
            />
            zshell
          </HomeLink>
        </h1>
        {headerContent}
      </header>

      {children}

      <SiteFooter lang={lang} />
    </main>
  )
}
