/** Old Chinese bookmarks keep working while every translation shares one heading ID. */
export function currentHeadingHash(hash: string): string {
  for (const anchor of document.querySelectorAll<HTMLElement>('[data-canonical-heading]')) {
    if (anchor.id === hash || encodeURIComponent(anchor.id) === hash) {
      return anchor.dataset.canonicalHeading ?? hash
    }
  }
  return hash
}
