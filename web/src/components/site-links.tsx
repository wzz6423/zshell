import { Link } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { DEFAULT_LANGUAGE, homePath, language } from '@/lib/i18n'

type LinkProps = { lang: string; className?: string; children: ReactNode; onClick?: () => void }

export function HomeLink({ lang, className, children, onClick }: LinkProps) {
  return (
    <Link to={homePath(lang)} className={className} onClick={onClick}>
      {children}
    </Link>
  )
}

/**
 * Docs, in contrast, are one `/$lang/docs` route for every language but the
 * default, which is served unprefixed. TanStack types `to` against the route
 * tree, so both have to be spelled out.
 */
export function DocsLink({ lang, className, children, onClick, slug = '' }: LinkProps & { slug?: string }) {
  return language(lang) === DEFAULT_LANGUAGE ? (
    <Link to="/docs/$" params={{ _splat: slug }} className={className} onClick={onClick}>
      {children}
    </Link>
  ) : (
    <Link to="/$lang/docs/$" params={{ lang: language(lang), _splat: slug }} className={className} onClick={onClick}>
      {children}
    </Link>
  )
}
