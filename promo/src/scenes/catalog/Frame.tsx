import type { CSSProperties, ReactNode } from 'react';
import { CheckIcon } from '../../components/Icons';
import { linear } from '../../lib/motion';
import { cursorOpacity } from '../../lib/typing';
import { alpha, color, type Tone } from '../../theme';

export type DemoProps = { step: number; frame: number; fps: number };
export type ChapterSpec = {
  id: string;
  en: string;
  zh: string;
  steps: readonly { en: string; zh: string }[];
  features: readonly string[];
  sources: readonly string[];
  Body: (props: DemoProps) => ReactNode;
};

export const Panel = ({ children, style, title }: { children: ReactNode; style?: CSSProperties; title?: string }) => (
  <div style={{ minWidth: 0, border: `1px solid ${color.line}`, borderRadius: 12, overflow: 'hidden', backgroundColor: color.surface, ...style }}>
    {title ? <div className="font-sans" style={{ padding: '13px 20px', backgroundColor: color.raised, borderBottom: `1px solid ${color.line}`, fontSize: 19, color: color.muted }}>{title}</div> : null}
    {children}
  </div>
);

export const Shell = ({ children, title = 'Zshell', sidebar, toolbar, style }: { children: ReactNode; title?: string; sidebar?: ReactNode; toolbar?: ReactNode; style?: CSSProperties }) => (
  <div className="font-sans" style={{ height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden', backgroundColor: color.surface, border: `1px solid ${color.lineStrong}`, borderRadius: 16, boxShadow: `0 24px 64px ${alpha(color.shadow, 12)}`, ...style }}>
    <div style={{ height: 48, flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8, padding: '0 22px', borderBottom: `1px solid ${color.line}`, backgroundColor: color.raised }}>
      {['#ff5f57', '#febc2e', '#28c840'].map((dot) => <span key={dot} style={{ width: 12, height: 12, borderRadius: '50%', backgroundColor: dot }} />)}
      <span style={{ flex: 1, fontSize: 19, textAlign: 'center', color: color.muted, paddingRight: 54 }}>{title}</span>
    </div>
    {toolbar ? <div style={{ padding: '14px 22px', borderBottom: `1px solid ${color.line}` }}>{toolbar}</div> : null}
    <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
      {sidebar ? <div style={{ width: 260, flexShrink: 0, padding: 18, borderRight: `1px solid ${color.line}`, backgroundColor: alpha(color.raised, 60) }}>{sidebar}</div> : null}
      <div style={{ flex: 1, minWidth: 0, minHeight: 0, position: 'relative', overflow: 'hidden' }}>{children}</div>
    </div>
  </div>
);

export const Badge = ({ children, tone = 'blue', active = true }: { children: ReactNode; tone?: Tone; active?: boolean }) => (
  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '7px 14px', borderRadius: 8, fontSize: 18, whiteSpace: 'nowrap', color: active ? color[tone] : color.muted, backgroundColor: alpha(active ? color[tone] : color.fg, active ? 10 : 4), border: `1px solid ${alpha(active ? color[tone] : color.fg, active ? 30 : 10)}` }}>{children}</span>
);

export const Action = ({ children, active = false, disabled = false, tone = 'blue' }: { children: ReactNode; active?: boolean; disabled?: boolean; tone?: Tone }) => (
  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 9, padding: '10px 18px', borderRadius: 9, fontSize: 20, whiteSpace: 'nowrap', fontWeight: 550, color: active ? color.surface : color.fg, backgroundColor: active ? color[tone] : color.raised, border: `1px solid ${active ? color[tone] : color.lineStrong}`, opacity: disabled ? 0.35 : 1 }}>{children}</span>
);

export const ListRow = ({ children, trailing, active = false, indent = 0, style }: { children: ReactNode; trailing?: ReactNode; active?: boolean; indent?: number; style?: CSSProperties }) => (
  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 14, marginLeft: indent, padding: '14px 16px', borderRadius: 9, fontSize: 21, color: active ? color.blue : color.fg, backgroundColor: active ? alpha(color.blue, 9) : 'transparent', ...style }}>
    <span style={{ minWidth: 0 }}>{children}</span>{trailing}
  </div>
);

export const Setting = ({ label, value, checked, progress, focus = false }: { label: string; value?: ReactNode; checked?: boolean; progress?: number; focus?: boolean }) => (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 20, padding: '12px 16px', borderBottom: `1px solid ${color.line}`, fontSize: 21, backgroundColor: focus ? alpha(color.blue, 7) : 'transparent' }}>
    <span style={{ color: color.fg }}>{label}</span>
    {checked !== undefined ? <span style={{ display: 'flex', alignItems: 'center', width: 43, height: 25, padding: 3, borderRadius: 999, backgroundColor: checked ? color.blue : alpha(color.fg, 16), justifyContent: checked ? 'flex-end' : 'flex-start' }}><span style={{ width: 19, height: 19, borderRadius: 999, backgroundColor: color.surface }} /></span> : null}
    {progress !== undefined ? <span style={{ width: 190, height: 5, borderRadius: 999, backgroundColor: alpha(color.fg, 12), position: 'relative' }}><span style={{ position: 'absolute', width: `${Math.min(1, Math.max(0, progress)) * 100}%`, height: '100%', backgroundColor: color.blue, borderRadius: 999 }} /><span style={{ position: 'absolute', left: `${Math.min(1, Math.max(0, progress)) * 100}%`, top: -6, width: 17, height: 17, borderRadius: 999, backgroundColor: color.surface, border: `1px solid ${color.lineStrong}` }} /></span> : null}
    {value !== undefined ? <span style={{ fontSize: 20, color: focus ? color.blue : color.muted, maxWidth: 500 }}>{value}</span> : null}
  </div>
);

const CATEGORIES = [
  { title: 'Basics', names: ['General', 'Appearance', 'Shortcuts'] },
  { title: 'Workspace', names: ['Terminal', 'Editor', 'Browser'] },
  { title: 'AI & Tools', names: ['AI', 'Recommendations'] },
  { title: 'About', names: ['Updates'] },
];

export const SettingsShell = ({ category, children }: { category: string; children: ReactNode }) => (
  <Shell title={`Settings — ${category}`} sidebar={CATEGORIES.map(({ title, names }) => <div key={title} style={{ marginBottom: 12 }}><div style={{ padding: '2px 16px 7px', fontSize: 16, color: color.muted }}>{title}</div>{names.map((name) => <ListRow key={name} active={name === category} style={{ padding: '8px 16px' }}>{name}</ListRow>)}</div>)}>
    <div style={{ padding: 30 }}>{children}</div>
  </Shell>
);

export const Group = ({ title, children, style }: { title: string; children: ReactNode; style?: CSSProperties }) => (
  <div style={{ marginBottom: 24, ...style }}>
    <div style={{ fontSize: 20, color: color.muted, fontWeight: 600, marginBottom: 12 }}>{title}</div>
    <Panel>{children}</Panel>
  </div>
);

export const Terminal = ({ children, frame = 0, command = '', shape = 'bar', fontSize = 26, style, blinking = true, directory = '~/src/app', branch = 'main' }: { children?: ReactNode; frame?: number; command?: string; shape?: 'bar' | 'block' | 'underline'; fontSize?: number; style?: CSSProperties; blinking?: boolean; directory?: string; branch?: string }) => (
  <div className="font-mono" style={{ padding: 28, fontSize, lineHeight: 1.7, height: '100%', color: color.fg, backgroundColor: color.surface, ...style }}>
    <div style={{ fontSize: fontSize * 0.8, color: color.muted, marginBottom: 18 }}>{directory} <span style={{ color: color.violet }}>{branch}</span></div>
    {children}
    <div style={{ marginTop: 12, whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}><span style={{ color: color.blue }}>› </span>{command}<span style={{ display: 'inline-block', verticalAlign: 'text-bottom', marginLeft: 2, width: shape === 'bar' ? 3 : fontSize * 0.6, height: shape === 'underline' ? 3 : fontSize * 1.2, backgroundColor: color.blue, opacity: blinking ? cursorOpacity(frame, false) : 1 }} /></div>
  </div>
);

export const Code = ({ lines, frame = 300, style }: { lines: readonly string[]; frame?: number; style?: CSSProperties }) => (
  <div className="font-mono" style={{ padding: '18px 22px', fontSize: 23, lineHeight: 1.85, ...style }}>
    {lines.map((line, index) => <div key={index} style={{ display: 'flex', gap: 22, opacity: linear(frame, [index * 7, index * 7 + 10]), color: line.startsWith('+') ? color.green : line.startsWith('-') ? color.red : color.fg, whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}><span style={{ width: 25, flexShrink: 0, color: color.faint }}>{index + 1}</span><span>{line}</span></div>)}
  </div>
);

export const Progress = ({ value, label, style }: { value: number; label?: string; style?: CSSProperties }) => (
  <div style={{ padding: 18, ...style }}>
    {label ? <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 14, fontSize: 22, color: color.muted }}>{label}<span style={{ color: color.blue }}>{Math.round(value * 100)}%</span></div> : null}
    <div style={{ height: 7, backgroundColor: alpha(color.fg, 9), borderRadius: 999, overflow: 'hidden' }}><div style={{ width: `${Math.min(1, value) * 100}%`, height: '100%', backgroundColor: color.blue, borderRadius: 999 }} /></div>
  </div>
);

export const Done = ({ children }: { children: ReactNode }) => <Badge tone="green"><CheckIcon size={20} />{children}</Badge>;
