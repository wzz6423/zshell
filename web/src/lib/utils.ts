import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/**
 * A URL for something the router does not resolve: a file in `public/`, or one
 * of the prerendered JSON endpoints that is fetched by hand. Vite rewrites the
 * imports it can see, but a literal path in `src`/`href` or `fetch()` is opaque
 * to it and would resolve against the domain root instead of the subpath the
 * site is served from.
 */
export function withBase(path: string) {
  return `${import.meta.env.BASE_URL}${path.replace(/^\//, '')}`
}
