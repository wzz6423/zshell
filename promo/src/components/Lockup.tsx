import type { ReactNode } from 'react';
import { Img, useCurrentFrame, useVideoConfig } from 'remotion';
// Reuses the website's icon so the app artwork lives in one place.
import icon from '../../../web/public/zshell-icon.png';
import { PRODUCT } from '../data/product';
import { pop, SPRING } from '../lib/motion';
import { alpha, color } from '../theme';

// Gradient text needs a transparent fill, so the wordmark cannot use `color`.
const WORDMARK = {
  color: 'transparent',
  backgroundImage: `linear-gradient(95deg, ${color.blue}, ${color.violet} 45%, ${color.pink})`,
  backgroundClip: 'text',
  WebkitBackgroundClip: 'text',
  // The tight tracking would otherwise clip the last glyph out of the painted box.
  paddingRight: 8,
} as const;

const rise = (progress: number, distance = 26) => ({
  opacity: Math.min(1, progress * 1.5),
  transform: `translateY(${(1 - progress) * distance}px)`,
});

export const Lockup = ({ at, scale = 1, children }: { at: number; scale?: number; children?: ReactNode }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const mark = pop(frame, fps, at, SPRING.bouncy);
  const name = pop(frame, fps, at + 10, SPRING.smooth);
  const tagline = pop(frame, fps, at + 24, SPRING.smooth);
  const eyebrow = pop(frame, fps, at + 38, SPRING.smooth);

  return (
    <div className="font-sans" style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', transform: `scale(${scale})` }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 30 }}>
        <Img
          src={icon}
          style={{
            width: 124,
            height: 124,
            opacity: Math.min(1, mark * 1.5),
            transform: `scale(${0.6 + mark * 0.4})`,
            filter: `drop-shadow(0 ${14 * mark}px ${34 * mark}px ${alpha(color.violet, 34)})`,
          }}
        />
        <div style={{ fontSize: 132, fontWeight: 700, letterSpacing: -5, lineHeight: 1, ...WORDMARK, ...rise(name) }}>
          {PRODUCT.name}
        </div>
      </div>
      <div style={{ marginTop: 34, fontSize: 46, fontWeight: 500, letterSpacing: -1, color: color.fg, ...rise(tagline) }}>
        {PRODUCT.tagline.en}
      </div>
      <div
        className="font-mono"
        style={{ marginTop: 20, display: 'flex', alignItems: 'center', gap: 16, fontSize: 21, color: color.muted, ...rise(eyebrow, 14) }}
      >
        <span style={{ color: color.cyan }}>{PRODUCT.eyebrow.en}</span>
        <span style={{ width: 5, height: 5, borderRadius: 999, backgroundColor: color.faint }} />
        <span className="font-sans" style={{ letterSpacing: 2 }}>{PRODUCT.eyebrow.zh}</span>
      </div>
      {children}
    </div>
  );
};
