// Inline styles reference the tokens declared in index.css so a palette
// change stays in one place.
export const color = {
  ink: 'var(--color-ink)',
  surface: 'var(--color-surface)',
  raised: 'var(--color-raised)',
  line: 'var(--color-line)',
  lineStrong: 'var(--color-line-strong)',
  fg: 'var(--color-fg)',
  muted: 'var(--color-muted)',
  faint: 'var(--color-faint)',
  cyan: 'var(--color-cyan)',
  blue: 'var(--color-blue)',
  violet: 'var(--color-violet)',
  pink: 'var(--color-pink)',
  red: 'var(--color-red)',
  amber: 'var(--color-amber)',
  green: 'var(--color-green)',
  shadow: 'var(--color-shadow)',
} as const;

export type Tone = 'cyan' | 'blue' | 'violet' | 'pink' | 'red' | 'amber' | 'green';

export const alpha = (value: string, percent: number) =>
  `color-mix(in srgb, ${value} ${percent}%, transparent)`;
