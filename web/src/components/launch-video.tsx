import { useId } from 'react'
import type { HomeCopy } from '@/lib/home-copy'
import { withBase } from '@/lib/utils'

export function LaunchVideo({ copy }: { copy: HomeCopy['video'] }) {
  const titleId = useId()

  return (
    <section id="launch-video" aria-labelledby={titleId} className="scroll-mt-16 border-t border-border py-16 sm:py-24">
      <div className="mx-auto max-w-6xl px-6">
        <h2 id={titleId} className="mb-8 text-3xl font-light text-foreground sm:text-4xl">{copy.title}</h2>
        <figure>
          <video
            aria-labelledby={titleId}
            controls
            playsInline
            preload="none"
            poster={withBase('/video/zshell-launch-poster.jpg')}
            width={1920}
            height={1080}
            className="block aspect-video h-auto w-full rounded-lg bg-black"
          >
            <source src={withBase('/video/zshell-launch-1080p.mp4')} type="video/mp4" />
          </video>
          <figcaption className="mt-4 text-xs leading-relaxed text-muted-foreground">
            {copy.musicCredit.before}
            <a href="https://www.scottbuckley.com.au/library/electric-dreams/" target="_blank" rel="noreferrer" className="underline underline-offset-2 hover:text-foreground">
              <bdi>“Electric Dreams” — Scott Buckley</bdi>
            </a>{' · '}
            <a href="https://creativecommons.org/licenses/by/4.0/" target="_blank" rel="noreferrer" className="underline underline-offset-2 hover:text-foreground">
              <bdi>CC BY 4.0</bdi>
            </a>
            {copy.musicCredit.after}
          </figcaption>
        </figure>
      </div>
    </section>
  )
}
