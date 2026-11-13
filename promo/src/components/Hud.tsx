import type { CSSProperties, ReactNode } from 'react';
import { TOKEN_COLOR, type Token } from '../lib/highlight';
import { alpha, color, type Tone } from '../theme';

type HudBubbleProps = {
  en: string;
  zh: string;
  tone: Tone;
  // 0 hidden, 1 settled.
  progress: number;
  // Which edge the pointer stem hangs from.
  stem?: 'left' | 'right';
  style?: CSSProperties;
};

export const HudBubble = ({ en, zh, tone, progress, stem = 'left', style }: HudBubbleProps) => (
  <div
    className="font-sans"
    style={{
      position: 'absolute',
      display: 'flex',
      alignItems: 'center',
      flexDirection: stem === 'left' ? 'row' : 'row-reverse',
      opacity: Math.min(1, progress * 1.4),
      transform: `translateY(${(1 - progress) * 14}px) scale(${0.94 + progress * 0.06})`,
      transformOrigin: stem === 'left' ? 'left center' : 'right center',
      ...style,
    }}
  >
    <span style={{ width: 11, height: 11, borderRadius: 999, backgroundColor: color[tone], boxShadow: `0 0 18px ${color[tone]}` }} />
    <span style={{ width: 44 * progress, height: 1.5, backgroundColor: alpha(color[tone], 70) }} />
    <div
      style={{
        padding: '12px 18px',
        borderRadius: 12,
        backgroundColor: alpha(color.raised, 92),
        border: `1px solid ${alpha(color[tone], 45)}`,
        boxShadow: `0 18px 50px ${alpha(color.shadow, 16)}, 0 0 34px ${alpha(color[tone], 14)}`,
        backdropFilter: 'blur(10px)',
      }}
    >
      <div style={{ fontSize: 21, fontWeight: 600, color: color.fg, whiteSpace: 'nowrap' }}>{en}</div>
      <div style={{ marginTop: 3, fontSize: 16, color: color[tone], whiteSpace: 'nowrap' }}>{zh}</div>
    </div>
  </div>
);

export const SceneLabel = ({ index, en, zh, opacity }: { index: string; en: string; zh: string; opacity: number }) => (
  <div
    className="font-mono"
    style={{
      position: 'absolute',
      left: 72,
      top: 56,
      display: 'flex',
      alignItems: 'center',
      gap: 14,
      fontSize: 17,
      letterSpacing: 1.5,
      opacity,
    }}
  >
    <span style={{ color: color.cyan }}>{index}</span>
    <span style={{ width: 28, height: 1, backgroundColor: color.lineStrong }} />
    <span style={{ color: color.fg }}>{en.toUpperCase()}</span>
    <span className="font-sans" style={{ color: color.muted, letterSpacing: 2 }}>{zh}</span>
  </div>
);

export const Keycap = ({ children, tone = 'cyan', pressed = 0, size = 15 }: { children: ReactNode; tone?: Tone; pressed?: number; size?: number }) => (
  <span
    className="font-mono"
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 6,
      padding: `${size * 0.35}px ${size * 0.7}px`,
      borderRadius: size * 0.5,
      fontSize: size,
      fontWeight: 600,
      color: pressed > 0.5 ? color.ink : color.fg,
      backgroundColor: pressed > 0.5 ? color[tone] : alpha(color.fg, 6),
      border: `1px solid ${alpha(pressed > 0 ? color[tone] : color.fg, pressed > 0 ? 70 : 16)}`,
      boxShadow: `0 ${3 * (1 - pressed)}px 0 ${alpha(color.shadow, 14)}, 0 0 ${40 * pressed}px ${alpha(color[tone], 70)}`,
      transform: `translateY(${3 * pressed}px)`,
    }}
  >
    {children}
  </span>
);

type CodeSliceProps = {
  title: string;
  lines: Token[][];
  // Lines beyond this count are not drawn yet; fractions fade the next one in.
  reveal?: number;
  focusLine?: number;
  focus?: number;
  fontSize?: number;
  style?: CSSProperties;
};

export const CodeSlice = ({ title, lines, reveal = lines.length, focusLine, focus = 0, fontSize = 19, style }: CodeSliceProps) => (
  <div
    style={{
      borderRadius: 14,
      overflow: 'hidden',
      backgroundColor: alpha(color.surface, 94),
      border: `1px solid ${color.lineStrong}`,
      boxShadow: `0 30px 80px ${alpha(color.shadow, 14)}`,
      ...style,
    }}
  >
    <div
      className="font-mono"
      style={{ padding: '11px 18px', fontSize: 14, color: color.muted, borderBottom: `1px solid ${color.line}`, backgroundColor: color.raised }}
    >
      {title}
    </div>
    <div className="font-mono" style={{ padding: '14px 0', fontSize, lineHeight: 1.75 }}>
      {lines.map((tokens, index) => {
        const focused = index === focusLine;
        return (
          <div
            key={index}
            style={{
              display: 'flex',
              padding: '0 18px',
              whiteSpace: 'pre',
              opacity: Math.max(0, Math.min(1, reveal - index)),
              backgroundColor: focused ? alpha(color.amber, 13 * focus) : 'transparent',
              boxShadow: focused ? `inset 3px 0 0 ${alpha(color.amber, 100 * focus)}` : undefined,
            }}
          >
            <span style={{ width: 34, color: color.faint, flexShrink: 0 }}>{index + 1}</span>
            <span>
              {tokens.map((token, tokenIndex) => (
                <span key={tokenIndex} style={{ color: TOKEN_COLOR[token.kind] }}>{token.text}</span>
              ))}
            </span>
          </div>
        );
      })}
    </div>
  </div>
);

type MeterProps = { label: string; zh: string; value: number; unit: string; tone: Tone; progress: number };

// The bar fills to its documented cap: these are limits, not measurements.
export const Meter = ({ label, zh, value, unit, tone, progress }: MeterProps) => (
  <div style={{ opacity: Math.min(1, progress * 3) }}>
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
      <span className="font-sans" style={{ fontSize: 18, color: color.fg }}>
        {label}
        <span style={{ marginLeft: 10, fontSize: 15, color: color.muted }}>{zh}</span>
      </span>
      <span className="font-mono" style={{ fontSize: 22, fontWeight: 700, color: color[tone] }}>
        {Math.round(value * progress).toLocaleString('en-US')}
        <span style={{ marginLeft: 6, fontSize: 13, fontWeight: 500, color: color.muted }}>{unit}</span>
      </span>
    </div>
    <div style={{ marginTop: 8, height: 6, borderRadius: 999, backgroundColor: alpha(color.fg, 7), overflow: 'hidden' }}>
      <div
        style={{
          width: `${progress * 100}%`,
          height: '100%',
          borderRadius: 999,
          background: `linear-gradient(90deg, ${alpha(color[tone], 35)}, ${color[tone]})`,
          boxShadow: `0 0 16px ${alpha(color[tone], 70)}`,
        }}
      />
    </div>
  </div>
);

export const Chip = ({ children, tone, opacity = 1 }: { children: ReactNode; tone?: Tone; opacity?: number }) => (
  <span
    className="font-mono"
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 7,
      padding: '6px 13px',
      borderRadius: 999,
      fontSize: 16,
      color: tone ? color[tone] : color.fg,
      backgroundColor: alpha(tone ? color[tone] : color.fg, tone ? 11 : 5),
      border: `1px solid ${alpha(tone ? color[tone] : color.fg, tone ? 36 : 13)}`,
      opacity,
    }}
  >
    {children}
  </span>
);
