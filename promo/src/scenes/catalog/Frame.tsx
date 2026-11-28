import type { CSSProperties, ReactNode } from 'react';
import { CheckIcon } from '../../components/Icons';
import { linear, mix, pop, ramp, SPRING } from '../../lib/motion';
import { cursorOpacity } from '../../lib/typing';
import { alpha, color, type Tone } from '../../theme';

export type DemoProps = { step: number; frame: number; fps: number };
export type ChapterSpec = {
  id: string;
  en: string;
  zh: string;
  nav: string;
  steps: readonly { en: string; zh: string }[];
  features: readonly string[];
  sources: readonly string[];
  Body: (props: DemoProps) => ReactNode;
};

// Smooth 0->1 progress for a state toggle or element reveal starting at `at`.
export const revealAt = (frame: number, fps: number, at: number, smooth = false) =>
  Math.max(0, Math.min(1, pop(frame, fps, at, smooth ? SPRING.smooth : SPRING.snappy)));

// Brief click-press impulse peaking right around `at` for authentic button feedback.
export const pressAt = (frame: number, at: number, span = 16) =>
  Math.min(ramp(frame, [at - 4, at + 3]), ramp(frame, [at + 3, at + span], [1, 0]));

export const Panel = ({ children, style, title, trailing }: { children: ReactNode; style?: CSSProperties; title?: string; trailing?: ReactNode }) => (
  <div style={{ minWidth: 0, border: `1px solid ${color.line}`, borderRadius: 12, overflow: 'hidden', backgroundColor: color.surface, ...style }}>
    {title ? (
      <div className="font-sans" style={{ padding: '11px 18px', backgroundColor: color.raised, borderBottom: `1px solid ${color.line}`, fontSize: 17, color: color.muted, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</span>
        {trailing}
      </div>
    ) : null}
    {children}
  </div>
);

export const Shell = ({ children, title = 'Zshell', sidebar, toolbar, style, titleTrailing }: { children: ReactNode; title?: string; sidebar?: ReactNode; toolbar?: ReactNode; style?: CSSProperties; titleTrailing?: ReactNode }) => (
  <div className="font-sans" style={{ height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden', backgroundColor: color.surface, border: `1px solid ${color.lineStrong}`, borderRadius: 16, boxShadow: `0 24px 64px ${alpha(color.shadow, 12)}`, ...style }}>
    <div style={{ height: 46, flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8, padding: '0 20px', borderBottom: `1px solid ${color.line}`, backgroundColor: color.raised }}>
      <div style={{ display: 'flex', gap: 8, minWidth: 110 }}>
        {['#ff5f57', '#febc2e', '#28c840'].map((dot) => <span key={dot} style={{ width: 12, height: 12, borderRadius: '50%', backgroundColor: dot }} />)}
      </div>
      <span style={{ flex: 1, fontSize: 18, textAlign: 'center', color: color.muted, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</span>
      <div style={{ minWidth: 110, display: 'flex', justifyContent: 'flex-end', alignItems: 'center' }}>{titleTrailing}</div>
    </div>
    {toolbar ? <div style={{ padding: '12px 20px', borderBottom: `1px solid ${color.line}`, flexShrink: 0 }}>{toolbar}</div> : null}
    <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
      {sidebar ? <div style={{ width: 256, flexShrink: 0, padding: 16, borderRight: `1px solid ${color.line}`, backgroundColor: alpha(color.raised, 58), overflow: 'hidden' }}>{sidebar}</div> : null}
      <div style={{ flex: 1, minWidth: 0, minHeight: 0, position: 'relative', overflow: 'hidden' }}>{children}</div>
    </div>
  </div>
);

export const Badge = ({ children, tone = 'blue', active = true, style }: { children: ReactNode; tone?: Tone; active?: boolean; style?: CSSProperties }) => (
  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '6px 13px', borderRadius: 8, fontSize: 17, whiteSpace: 'nowrap', color: active ? color[tone] : color.muted, backgroundColor: alpha(active ? color[tone] : color.fg, active ? 10 : 4), border: `1px solid ${alpha(active ? color[tone] : color.fg, active ? 30 : 10)}`, ...style }}>{children}</span>
);

export const Action = ({ children, active = false, disabled = false, tone = 'blue', press = 0, style }: { children: ReactNode; active?: boolean; disabled?: boolean; tone?: Tone; press?: number; style?: CSSProperties }) => (
  <span
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 8,
      padding: '9px 16px',
      borderRadius: 9,
      fontSize: 18,
      whiteSpace: 'nowrap',
      fontWeight: 550,
      color: active ? color.surface : color.fg,
      backgroundColor: active ? color[tone] : color.raised,
      border: `1px solid ${active ? color[tone] : color.lineStrong}`,
      opacity: disabled ? 0.36 : 1,
      boxShadow: press > 0 ? `0 0 ${22 * press}px ${alpha(color[tone], 42 * press)}` : undefined,
      transform: press > 0 ? `scale(${1 - press * 0.045})` : undefined,
      ...style,
    }}
  >
    {children}
  </span>
);

// Inline-flex keeps icons horizontally aligned beside labels instead of stacking onto two lines.
export const ListRow = ({ children, trailing, active = false, indent = 0, style }: { children: ReactNode; trailing?: ReactNode; active?: boolean; indent?: number; style?: CSSProperties }) => (
  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginLeft: indent, padding: '11px 14px', borderRadius: 9, fontSize: 19, color: active ? color.blue : color.fg, backgroundColor: active ? alpha(color.blue, 9) : 'transparent', ...style }}>
    <span style={{ minWidth: 0, display: 'inline-flex', alignItems: 'center', gap: 10 }}>{children}</span>
    {trailing}
  </div>
);

// Accepts boolean or continuous 0..1 progress for `checked` so toggle thumbs glide smoothly.
export const Setting = ({ label, value, checked, progress, focus = false }: { label: string; value?: ReactNode; checked?: boolean | number; progress?: number; focus?: boolean }) => {
  const toggle = typeof checked === 'number' ? Math.max(0, Math.min(1, checked)) : checked ? 1 : 0;
  const clamped = progress === undefined ? 0 : Math.min(1, Math.max(0, progress));
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 18, padding: '11px 16px', borderBottom: `1px solid ${color.line}`, fontSize: 19, backgroundColor: focus ? alpha(color.blue, 7) : 'transparent' }}>
      <span style={{ color: color.fg }}>{label}</span>
      {checked !== undefined ? (
        <span style={{ position: 'relative', width: 43, height: 25, flexShrink: 0, borderRadius: 999, backgroundColor: toggle > 0.5 ? alpha(color.blue, mix(45, 100, (toggle - 0.5) * 2)) : alpha(color.fg, mix(16, 24, toggle * 2)) }}>
          <span style={{ position: 'absolute', left: 3, top: 3, width: 19, height: 19, borderRadius: 999, backgroundColor: color.surface, boxShadow: `0 1px 3px ${alpha(color.shadow, 22)}`, transform: `translateX(${toggle * 18}px)` }} />
        </span>
      ) : null}
      {progress !== undefined ? (
        <span style={{ width: 170, height: 5, flexShrink: 0, borderRadius: 999, backgroundColor: alpha(color.fg, 12), position: 'relative' }}>
          <span style={{ position: 'absolute', width: `${clamped * 100}%`, height: '100%', backgroundColor: color.blue, borderRadius: 999 }} />
          <span style={{ position: 'absolute', left: `calc(${clamped * 100}% - 8px)`, top: -6, width: 17, height: 17, borderRadius: 999, backgroundColor: color.surface, border: `1px solid ${color.lineStrong}`, boxShadow: `0 1px 4px ${alpha(color.shadow, 16)}` }} />
        </span>
      ) : null}
      {value !== undefined ? <span style={{ fontSize: 18, color: focus ? color.blue : color.muted, maxWidth: 460, textAlign: 'right' }}>{value}</span> : null}
    </div>
  );
};

// Matches Settings sidebar grouping in web/content/docs/configuration.mdx.
const CATEGORIES = [
  { title: 'Basics', names: ['General', 'Appearance', 'Shortcuts'] },
  { title: 'Workspace', names: ['Terminal', 'Editor', 'Browser'] },
  { title: 'AI', names: ['AI'] },
  { title: 'Permissions', names: ['Permissions'] },
  { title: 'Other', names: ['Recommendations'] },
  { title: 'About', names: ['Updates'] },
];

export const SettingsShell = ({ category, children }: { category: string; children: ReactNode }) => (
  <Shell
    title={`Settings — ${category}`}
    sidebar={CATEGORIES.map(({ title, names }) => (
      <div key={title} style={{ marginBottom: 10 }}>
        <div style={{ padding: '2px 14px 5px', fontSize: 13, letterSpacing: 0.4, color: color.muted }}>{title}</div>
        {names.map((name) => (
          <ListRow key={name} active={name === category} style={{ padding: '6px 14px', fontSize: 17 }}>
            {name}
          </ListRow>
        ))}
      </div>
    ))}
  >
    <div style={{ padding: 26, height: '100%', boxSizing: 'border-box' }}>{children}</div>
  </Shell>
);

export const Group = ({ title, children, style }: { title: string; children: ReactNode; style?: CSSProperties }) => (
  <div style={{ marginBottom: 20, ...style }}>
    <div style={{ fontSize: 17, color: color.muted, fontWeight: 600, marginBottom: 9 }}>{title}</div>
    <Panel>{children}</Panel>
  </div>
);

export const Terminal = ({
  children,
  after,
  frame = 0,
  command = '',
  typing = false,
  shape = 'bar',
  fontSize = 23,
  style,
  blinking = true,
  directory = '~/src/app',
  branch = 'main',
  showPrompt = true,
}: {
  children?: ReactNode;
  after?: ReactNode;
  frame?: number;
  command?: string;
  typing?: boolean;
  shape?: 'bar' | 'block' | 'underline';
  fontSize?: number;
  style?: CSSProperties;
  blinking?: boolean;
  directory?: string;
  branch?: string;
  showPrompt?: boolean;
}) => (
  <div className="font-mono" style={{ padding: 24, fontSize, lineHeight: 1.65, height: '100%', boxSizing: 'border-box', color: color.fg, backgroundColor: color.surface, ...style }}>
    <div style={{ fontSize: fontSize * 0.78, color: color.muted, marginBottom: 14 }}>
      {directory} {branch ? <span style={{ color: color.violet }}>{branch}</span> : null}
    </div>
    {children}
    {showPrompt ? (
      <div style={{ marginTop: 10, whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
        <span style={{ color: color.blue }}>› </span>
        {command}
        <span
          style={{
            display: 'inline-block',
            verticalAlign: 'text-bottom',
            marginLeft: 2,
            width: shape === 'bar' ? 3 : fontSize * 0.58,
            height: shape === 'underline' ? 3 : fontSize * 1.18,
            backgroundColor: color.blue,
            opacity: blinking ? cursorOpacity(frame, typing) : 1,
          }}
        />
      </div>
    ) : null}
    {after}
  </div>
);

export const Code = ({ lines, frame = 300, style }: { lines: readonly string[]; frame?: number; style?: CSSProperties }) => (
  <div className="font-mono" style={{ padding: '14px 18px', fontSize: 20, lineHeight: 1.75, ...style }}>
    {lines.map((line, index) => (
      <div
        key={index}
        style={{
          display: 'flex',
          gap: 18,
          opacity: linear(frame, [index * 6, index * 6 + 10]),
          color: line.startsWith('+') ? color.green : line.startsWith('-') ? color.red : color.fg,
          whiteSpace: 'pre-wrap',
          overflowWrap: 'anywhere',
        }}
      >
        <span style={{ width: 24, flexShrink: 0, color: color.faint }}>{index + 1}</span>
        <span>{line}</span>
      </div>
    ))}
  </div>
);

export const Progress = ({ value, label, tone = 'blue', style }: { value: number; label?: string; tone?: Tone; style?: CSSProperties }) => (
  <div style={{ padding: 16, ...style }}>
    {label ? (
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 10, fontSize: 19, color: color.muted }}>
        <span>{label}</span>
        <span style={{ color: color[tone] }}>{Math.round(Math.min(1, Math.max(0, value)) * 100)}%</span>
      </div>
    ) : null}
    <div style={{ height: 7, backgroundColor: alpha(color.fg, 9), borderRadius: 999, overflow: 'hidden' }}>
      <div style={{ width: `${Math.min(1, Math.max(0, value)) * 100}%`, height: '100%', backgroundColor: color[tone], borderRadius: 999 }} />
    </div>
  </div>
);

export const Done = ({ children, progress = 1, style }: { children: ReactNode; progress?: number; style?: CSSProperties }) => (
  <Badge
    tone="green"
    style={{
      opacity: Math.min(1, progress * 1.4),
      transform: `translateY(${(1 - progress) * 8}px) scale(${0.95 + progress * 0.05})`,
      ...style,
    }}
  >
    <CheckIcon size={18} />
    {children}
  </Badge>
);

// Animated popover/modal wrapper so overlays never pop in or vanish on a single frame.
export const Overlay = ({ progress, children, style }: { progress: number; children: ReactNode; style?: CSSProperties }) =>
  progress <= 0.001 ? null : (
    <div
      style={{
        opacity: Math.min(1, progress * 1.35),
        transform: `translateY(${(1 - progress) * 12}px) scale(${0.96 + progress * 0.04})`,
        ...style,
      }}
    >
      {children}
    </div>
  );
