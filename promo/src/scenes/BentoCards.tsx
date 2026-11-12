import type { ReactNode } from 'react';
import { CheckIcon } from '../components/Icons';
import { AgentBadge, type AgentPhase } from '../components/Workspace';
import { during, linear, mix, pop, SPRING } from '../lib/motion';
import { alpha, color, type Tone } from '../theme';

export type CardProps = { frame: number; fps: number };

type BentoCardProps = {
  span: number;
  tone: Tone;
  icon: ReactNode;
  en: string;
  zh: string;
  enter: number;
  children: ReactNode;
};

export const BentoCard = ({ span, tone, icon, en, zh, enter, children }: BentoCardProps) => (
  <div
    style={{
      gridColumn: `span ${span}`,
      position: 'relative',
      display: 'flex',
      flexDirection: 'column',
      padding: 28,
      overflow: 'hidden',
      borderRadius: 22,
      backgroundColor: alpha(color.surface, 94),
      backgroundImage: `radial-gradient(ellipse 70% 60% at 100% 0%, ${alpha(color[tone], 13)}, transparent 70%)`,
      border: `1px solid ${alpha(color[tone], mix(60, 20, enter))}`,
      boxShadow: `0 30px 70px ${alpha(color.shadow, 12)}`,
      opacity: Math.min(1, enter * 1.6),
      transform: `translateY(${(1 - enter) * 46}px) scale(${0.94 + enter * 0.06})`,
    }}
  >
    <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
      <span
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: 44,
          height: 44,
          borderRadius: 12,
          color: color[tone],
          backgroundColor: alpha(color[tone], 13),
          border: `1px solid ${alpha(color[tone], 34)}`,
        }}
      >
        {icon}
      </span>
      <div className="font-sans">
        <div style={{ fontSize: 28, fontWeight: 650, letterSpacing: -0.5, lineHeight: 1.15, color: color.fg }}>{en}</div>
        <div style={{ fontSize: 18, letterSpacing: 1, color: color.muted }}>{zh}</div>
      </div>
    </div>
    <div style={{ flex: 1, minHeight: 0, marginTop: 22, position: 'relative' }}>{children}</div>
  </div>
);

const AGENTS: { alias: string; kind: string; phases: [number, AgentPhase][] }[] = [
  { alias: 'tests', kind: 'codex', phases: [[0, 'working'], [210, 'done']] },
  { alias: 'docs', kind: 'claude', phases: [[0, 'created'], [96, 'working'], [276, 'blocked']] },
  { alias: 'refactor', kind: 'gemini', phases: [[0, 'working'], [348, 'done']] },
];

export const AgentsCard = ({ frame }: CardProps) => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
    {AGENTS.map((agent) => {
      const [changedAt, phase] = agent.phases.findLast(([at]) => frame >= at) ?? agent.phases[0];
      return (
        <div
          key={agent.alias}
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '15px 18px',
            borderRadius: 12,
            backgroundColor: alpha(color.fg, 3.5),
            border: `1px solid ${color.line}`,
          }}
        >
          <span className="font-mono" style={{ fontSize: 21, color: color.fg }}>
            {agent.alias}
            <span style={{ marginLeft: 14, fontSize: 16, color: color.faint }}>{agent.kind}</span>
          </span>
          <AgentBadge phase={phase} pulse={changedAt ? during(frame, changedAt, changedAt + 50, 12) : 0} />
        </div>
      );
    })}
  </div>
);

const SCOPES = ['Latest Turn', 'Uncommitted', 'Entire Branch'];
const HUNK = [
  { sign: ' ', text: 'fn width(glyph: &Glyph) -> usize {' },
  { sign: '-', text: '    1' },
  { sign: '+', text: '    glyph.columns' },
  { sign: ' ', text: '}' },
];
const KEEP_AT = 250;

export const ReviewCard = ({ frame, fps }: CardProps) => {
  const kept = pop(frame, fps, KEEP_AT, SPRING.snappy);
  const press = during(frame, KEEP_AT - 6, KEEP_AT + 14, 5);
  return (
    <>
      <div className="font-sans" style={{ display: 'flex', gap: 8, fontSize: 15 }}>
        {SCOPES.map((scope, index) => (
          <span
            key={scope}
            style={{
              padding: '5px 12px',
              borderRadius: 8,
              color: index === 0 ? color.fg : color.muted,
              backgroundColor: alpha(color.fg, index === 0 ? 9 : 0),
              border: `1px solid ${index === 0 ? color.lineStrong : 'transparent'}`,
            }}
          >
            {scope}
          </span>
        ))}
      </div>
      <div
        className="font-mono"
        style={{ marginTop: 14, padding: '10px 0', borderRadius: 12, fontSize: 17, lineHeight: 1.75, backgroundColor: alpha(color.raised, 70), border: `1px solid ${color.line}` }}
      >
        {HUNK.map((line, index) => {
          const tone = line.sign === '+' ? color.green : line.sign === '-' ? color.red : null;
          return (
            <div
              key={index}
              style={{
                padding: '0 16px',
                whiteSpace: 'pre',
                color: tone ?? color.muted,
                backgroundColor: tone ? alpha(tone, 11) : 'transparent',
                opacity: linear(frame, [60 + index * 9, 72 + index * 9]),
              }}
            >
              {line.sign} {line.text}
            </div>
          );
        })}
      </div>
      <div className="font-sans" style={{ marginTop: 16, display: 'flex', alignItems: 'center', gap: 10, fontSize: 16, fontWeight: 600 }}>
        <span
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 7,
            padding: '8px 15px',
            borderRadius: 9,
            color: kept > 0.5 ? color.ink : color.green,
            backgroundColor: kept > 0.5 ? color.green : alpha(color.green, 12),
            border: `1px solid ${alpha(color.green, 50)}`,
            boxShadow: `0 0 ${30 * press}px ${alpha(color.green, 70)}`,
            transform: `scale(${1 - press * 0.05})`,
          }}
        >
          {kept > 0.5 ? <CheckIcon size={17} strokeWidth={2.6} /> : null}
          Keep Hunk
        </span>
        <span style={{ padding: '8px 15px', borderRadius: 9, color: color.muted, border: `1px solid ${color.lineStrong}` }}>Revert Hunk</span>
      </div>
    </>
  );
};
