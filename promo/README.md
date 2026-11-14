# Zshell — launch video

**English** | [简体中文](README.zh-CN.md)

A 2-minute 40-second product launch film for **Zshell**, the native terminal
workspace for macOS, written as code and rendered to MP4 with a warm
synthwave score by Scott Buckley.

## Stack

- [Remotion](https://www.remotion.dev) 4 (React 19 + TypeScript)
- [Tailwind CSS v4](https://tailwindcss.com) through `@remotion/tailwind-v4`
- JetBrains Mono and Geist bundled from [Fontsource](https://fontsource.org), so
  a render never waits on a font CDN

## Develop

Run these commands from `promo/`; dependencies are locked by `promo/bun.lock`.

```sh
bun install --frozen-lockfile
bun run studio     # preview and scrub at http://localhost:3000
bun run typecheck  # tsc --noEmit
bun run render     # out/zshell-launch.mp4, 1920×1080 at 60 fps
bun run render:4k  # out/zshell-launch-4k.mp4, 3840×2160 at 60 fps
```

The scripts wrap the Remotion CLI, so `npx remotion studio` and
`npx remotion render LaunchVideo out/zshell-launch.mp4` do the same. The 4K file
is the same composition rendered with `--scale=2`. The first render downloads
Chrome Headless Shell into `node_modules/.remotion`.

Render one frame to check a change without rendering the whole film:

```sh
bunx remotion still LaunchVideo out/f1500.png --frame=1500
```

## Website and README distribution

The website and both root READMEs share the versioned
[`zshell-launch-1080p.mp4`](../web/public/video/zshell-launch-1080p.mp4) and
[`zshell-launch-poster.jpg`](../web/public/video/zshell-launch-poster.jpg) in
`web/public/video/`. The video is a 1920×1080, 60 fps H.264 export of the same
composition as the 4K master, with the same continuous score and MP4 faststart
enabled. The poster is the title and workspace reveal at 4.5 seconds.

GitHub Pages publishes them under `/zshell/video/` after the change is merged
to `main` and the website deployment succeeds.

## Timeline

One composition, `LaunchVideo`: 9600 frames at 60 fps.
[`src/timeline.ts`](src/timeline.ts) holds the start and length of every scene,
and each scene counts frames from its own zero.

| Scene | Seconds | Source | Shows |
| --- | --- | --- | --- |
| 1 · The Terminal Awakening | 0–5 | [`Awakening.tsx`](src/scenes/Awakening.tsx) | Shell and tmux config files pile up, collapse into a point, and open as one Zshell window. |
| 2 · Speed & Core Workflow | 5–15 | [`Workflow.tsx`](src/scenes/Workflow.tsx) | Three automation commands are typed and run: a background split that returns the real exit status, an agent start, and an agent prompt. |
| 3 · Under the Hood | 15–27 | [`UnderTheHood.tsx`](src/scenes/UnderTheHood.tsx) | The window tilts apart into four layers, then four chapters: architecture, the two terminal backends, the automation boundary, and the event stream. |
| 4 · Complete Feature Tour | 27–147 | [`Catalog.tsx`](src/scenes/catalog/Catalog.tsx) | Ten chapters demonstrate projects and panes, appearance and cursors, terminal interaction, search and Quick Terminal controls, files and editor, Git and PRs, browser, agent recognition and coordination, persistent sessions and session info, and preferences and tools including Quiet.md. |
| 5 · Feature Bento Grid | 147–154 | [`BentoGrid.tsx`](src/scenes/BentoGrid.tsx) | Git staging, commits and push; turn review; agent status; worktree sessions; remote sessions; global Quick Terminal and paired browser access, with English and Chinese labels. |
| 6 · Outro & Get Started | 154–160 | [`Outro.tsx`](src/scenes/Outro.tsx) | The Homebrew install command types itself, then the logo and the repository address hold. |

## Notes

- The bundled score is a continuous 160-second excerpt (00:00–02:40) from
  [“Electric Dreams” by Scott Buckley](https://www.scottbuckley.com.au/library/electric-dreams/),
  licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
  The composition uses `public/audio/electric-dreams-tour.mp3` for both Studio
  playback and video exports.
  Source, edit settings and a reproducible FFmpeg command are recorded in
  [`public/audio/ATTRIBUTION.md`](public/audio/ATTRIBUTION.md).

  Include this credit in published video descriptions, including YouTube:

  > 'Electric Dreams' by Scott Buckley - released under CC-BY 4.0.
  > www.scottbuckley.com.au. https://creativecommons.org/licenses/by/4.0/
  > 00:00–02:40 excerpt. [Attribution and edit details](public/audio/ATTRIBUTION.md).

- Commands, feature names and settings reflect the owning application source.
  Commands, flags, JSON fields, shortcuts, config keys, and limits are copied
  from [`web/content/docs`](../web/content/docs) and
  [`mac/zshell/Skills/zshell-automation/SKILL.md`](../mac/zshell/Skills/zshell-automation/SKILL.md),
  and live in [`src/data/`](src/data). When the product changes, update that
  folder rather than a scene.
- The shell and tmux files in scene 1, the feature-tour interfaces, and the
  sample projects, changes and sessions are scripted demonstrations of those
  real features. Each tour chapter records its covered features and owning
  source files in `src/scenes/catalog/`. The tour illustrates the controls and
  behavior; it does not execute application actions while rendering. The Quick
  Terminal and browser access examples use separate sessions: the browser
  attaches to a pane in the main workspace.
- Zshell publishes no benchmarks, so the meters in scene 3 fill to documented
  automation limits, not to measurements.
- Colors are tokens in [`src/index.css`](src/index.css); inline styles read them
  through [`src/theme.ts`](src/theme.ts).
- The app icon is imported from
  [`web/public/zshell-icon.png`](../web/public/zshell-icon.png) rather than
  copied.
- The backdrop particles take their rise speed, sway, and soft falloff from the
  website's ambient field
  ([`web/src/components/site-particles.tsx`](../web/src/components/site-particles.tsx))
  but are drawn separately in CSS and share no code or texture with it.
- Animation reads only the current frame — no `Math.random()`, timers, or CSS
  transitions — and the particles are seeded with Remotion's `random()`, so
  frames can render in any order and every render is identical.
- `out/` is ignored. Working renders are not committed; the distribution video
  and poster in `web/public/video/` are versioned for the website and READMEs.
- Remotion is source-available rather than open source. It is free for
  individuals and for organizations of up to three people; larger for-profit
  teams need a [company license](https://www.remotion.dev/docs/license) to
  render with it.
