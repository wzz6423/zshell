import { BranchIcon, CheckIcon } from '../components/Icons';
import { Cursor } from '../components/Terminal';
import { during, linear, mix, pop, SPRING } from '../lib/motion';
import { cursorOpacity, typedLength } from '../lib/typing';
import { alpha, color } from '../theme';
import type { CardProps } from './BentoCards';

const OPEN_DIFF_AT = 74;
const STAGE_AT = 172;
const MESSAGE_FROM = 216;
const MESSAGE_TO = 278;
const COMMIT_AT = 328;
const COMMITTED_AT = 344;
const PUSH_AT = 428;
const PUSHED_AT = 462;
const MESSAGE = 'fix: keep scrollback';
const HUNK = [
  { number: 42, sign: ' ', text: 'function reconnect() {' },
  { number: 43, sign: '-', text: '  resetScrollback();' },
  { number: 43, sign: '+', text: '  restoreScrollback();' },
  { number: 44, sign: ' ', text: '  attachTerminal();' },
  { number: 45, sign: ' ', text: '}' },
];

export const GitCard = ({ frame, fps }: CardProps) => {
  const staged = frame >= STAGE_AT;
  const committed = frame >= COMMITTED_AT;
  const pushed = frame >= PUSHED_AT;
  const selected = pop(frame, fps, OPEN_DIFF_AT, SPRING.snappy);
  const stage = pop(frame, fps, STAGE_AT, SPRING.snappy);
  const clean = pop(frame, fps, COMMITTED_AT, SPRING.snappy);
  const stagePress = during(frame, STAGE_AT - 8, STAGE_AT + 12, 5);
  const commitPress = during(frame, COMMIT_AT - 8, COMMIT_AT + 12, 5);
  const pushPress = during(frame, PUSH_AT - 8, PUSH_AT + 12, 5);
  const commitMenu = during(frame, 296, 340, 6);
  const remoteMenu = during(frame, 392, 442, 6);
  const count = typedLength(MESSAGE, frame, MESSAGE_FROM, MESSAGE_TO);
  const typing = frame >= MESSAGE_FROM && frame < MESSAGE_TO;
  const caption = pushed
    ? ['Pushed', '已推送']
    : frame >= PUSH_AT
      ? ['Push', '推送分支']
      : committed
        ? ['Committed', '已提交，等待推送']
        : frame >= MESSAGE_FROM
          ? ['Commit Staged', '提交已暂存改动']
          : staged
            ? ['Staged', '改动已暂存']
            : frame >= OPEN_DIFF_AT
              ? ['Review diff', '查看文件差异']
              : ['Git panel', 'Git 面板'];

  return (
    <div style={{ height: 240, boxSizing: 'border-box', display: 'flex', flexDirection: 'column', overflow: 'hidden', borderRadius: 14, backgroundColor: alpha(color.surface, 95), border: `1px solid ${color.lineStrong}` }}>
      <div style={{ flex: 1, minHeight: 0, display: 'grid', gridTemplateColumns: '0.92fr 1fr' }}>
        <div style={{ minWidth: 0, position: 'relative', borderRight: `1px solid ${color.line}` }}>
          <div className="font-mono" style={{ height: 34, display: 'flex', alignItems: 'center', gap: 8, padding: '0 12px', fontSize: 14, color: color.fg, borderBottom: `1px solid ${color.line}` }}>
            <BranchIcon size={16} color={color.blue} />
            <span>feat/review</span>
            {committed && !pushed ? (
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, marginLeft: 'auto', color: color.blue }}>
                1
                <svg width="12" height="14" viewBox="0 0 12 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M6 12V2M2.5 5.5L6 2l3.5 3.5" />
                </svg>
              </span>
            ) : null}
            <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 24, height: 23, marginLeft: committed && !pushed ? 0 : 'auto', borderRadius: 5, backgroundColor: alpha(color.blue, remoteMenu * 13), color: color.muted }}>
              <svg width="18" height="18" viewBox="0 0 18 18" fill="currentColor">
                {[4, 9, 14].map((x) => <circle key={x} cx={x} cy="9" r="1.3" />)}
              </svg>
            </span>
          </div>
          <div style={{ padding: '8px 12px 10px' }}>
            <div className="font-sans" style={{ fontSize: 11.5, fontWeight: 650, letterSpacing: 0.4, color: staged ? color.green : color.muted }}>
              {committed ? 'RECENT COMMITS' : staged ? 'STAGED CHANGES' : 'CHANGES'}
              <span style={{ marginLeft: 8, color: color.faint }}>1</span>
            </div>
            <div
              className="font-mono"
              style={{ height: 30, marginTop: 6, display: 'flex', alignItems: 'center', gap: 8, padding: '0 8px', borderRadius: 6, fontSize: 14, backgroundColor: alpha(staged ? color.green : color.blue, mix(3, 10, selected)), border: `1px solid ${alpha(staged ? color.green : color.blue, mix(0, 22, selected))}`, transform: `translateY(${(1 - stage) * stage * 8}px)` }}
            >
              {committed ? <CheckIcon size={14} color={color.green} /> : <span style={{ fontSize: 12, color: color.amber }}>M</span>}
              <span style={{ color: color.fg, fontSize: committed ? 12.5 : 14 }}>{committed ? MESSAGE : 'session.ts'}</span>
              {!committed ? (
                <span style={{ width: 23, height: 23, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginLeft: 'auto', borderRadius: 5, color: staged ? color.green : color.blue, backgroundColor: alpha(color.blue, stagePress * 15), boxShadow: `0 0 ${18 * stagePress}px ${alpha(color.blue, 32)}`, transform: `scale(${1 - stagePress * 0.1})` }}>
                  <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
                    <path d="M2 6.5h9" />
                    {!staged ? <path d="M6.5 2v9" /> : null}
                  </svg>
                </span>
              ) : null}
            </div>
            <div className="font-mono" style={{ height: 39, boxSizing: 'border-box', marginTop: 8, padding: '10px 9px', fontSize: 13, borderRadius: 7, color: color.fg, border: `1px solid ${frame >= MESSAGE_FROM && !committed ? alpha(color.blue, 50) : color.line}`, backgroundColor: alpha(color.raised, 45), whiteSpace: 'nowrap' }}>
              {committed || count === 0 ? <span className="font-sans" style={{ color: color.faint }}>Commit message</span> : MESSAGE.slice(0, count)}
              {frame >= MESSAGE_FROM && !committed ? <Cursor opacity={cursorOpacity(frame, typing)} /> : null}
            </div>
            <div className="font-sans" style={{ height: 28, marginTop: 8, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontSize: 12.5, fontWeight: 600, color: staged && count > 0 && !committed ? color.blue : color.muted, borderRadius: 6, border: `1px solid ${staged && count > 0 && !committed ? alpha(color.blue, 40) : color.lineStrong}`, backgroundColor: alpha(color.blue, staged && count > 0 && !committed ? 10 : 0) }}>
              {staged && !committed ? 'Commit 1 Staged Files' : 'Commit Staged'}
              <svg width="9" height="7" viewBox="0 0 9 7" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
                <path d="M1 2l3.5 3L8 2" />
              </svg>
            </div>
          </div>
          {commitMenu > 0 ? (
            <div className="font-sans" style={{ position: 'absolute', left: 10, right: 10, top: 90, zIndex: 2, padding: 5, borderRadius: 8, fontSize: 12.5, backgroundColor: color.surface, border: `1px solid ${color.lineStrong}`, boxShadow: `0 6px 22px ${alpha(color.shadow, 17)}`, opacity: commitMenu, transform: `translateY(${(1 - commitMenu) * 5}px)` }}>
              {['Commit Staged', 'Stage All & Commit'].map((label, index) => (
                <div key={label} style={{ height: 27, padding: '0 8px', display: 'flex', alignItems: 'center', borderRadius: 4, color: index === 0 ? color.blue : color.muted, backgroundColor: index === 0 ? alpha(color.blue, 12 + commitPress * 10) : 'transparent', transform: index === 0 ? `scale(${1 - commitPress * 0.035})` : undefined }}>{label}</div>
              ))}
            </div>
          ) : null}
          {remoteMenu > 0 ? (
            <div className="font-sans" style={{ position: 'absolute', right: 8, top: 29, zIndex: 3, width: 188, padding: 5, borderRadius: 8, fontSize: 12, backgroundColor: color.surface, border: `1px solid ${color.lineStrong}`, boxShadow: `0 6px 22px ${alpha(color.shadow, 17)}`, opacity: remoteMenu, transform: `translateY(${(1 - remoteMenu) * -5}px)` }}>
              {['Fetch', 'Pull (Fast-forward Only)', 'Push'].map((label, index) => (
                <div key={label} style={{ height: 26, padding: '0 8px', display: 'flex', alignItems: 'center', borderRadius: 4, color: index === 2 ? color.blue : color.muted, backgroundColor: index === 2 ? alpha(color.blue, 12 + pushPress * 10) : 'transparent', transform: index === 2 ? `scale(${1 - pushPress * 0.035})` : undefined }}>{label}</div>
              ))}
            </div>
          ) : null}
        </div>
        <div style={{ minWidth: 0, overflow: 'hidden' }}>
          <div style={{ height: 34, display: 'flex', alignItems: 'center', gap: 6, padding: '0 12px', borderBottom: `1px solid ${color.line}`, opacity: Math.min(1, selected * 1.5) }}>
            <span className="font-mono" style={{ fontSize: 14, color: color.fg }}>session.ts</span>
            <span className="font-sans" style={{ marginLeft: 'auto', padding: '3px 6px', borderRadius: 4, fontSize: 10.5, color: color.blue, backgroundColor: alpha(color.blue, 9) }}>Review</span>
            <span className="font-sans" style={{ fontSize: 10.5, color: color.muted }}>Unified</span>
          </div>
          <div className="font-mono" style={{ padding: '9px 0', fontSize: 14, lineHeight: '26px' }}>
            {HUNK.map((line, index) => {
              const tone = line.sign === '+' ? color.green : line.sign === '-' ? color.red : null;
              return (
                <div key={index} style={{ display: 'flex', whiteSpace: 'pre', color: tone ?? color.muted, backgroundColor: tone ? alpha(tone, 10) : 'transparent', opacity: linear(frame, [OPEN_DIFF_AT + index * 7, OPEN_DIFF_AT + 14 + index * 7]), transform: `translateX(${(1 - selected) * 8}px)` }}>
                  <span style={{ width: 28, marginRight: 6, textAlign: 'right', flexShrink: 0, fontSize: 11, color: color.faint }}>{line.number}</span>
                  <span style={{ width: 16, flexShrink: 0 }}>{line.sign}</span>
                  <span>{line.text}</span>
                </div>
              );
            })}
          </div>
          <div className="font-sans" style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '0 13px', fontSize: 12, color: color.green, opacity: Math.min(1, clean * 1.5) }}>
            <CheckIcon size={13} />
            {pushed ? 'Working tree clean' : 'Working tree clean, sync is pending'}
          </div>
        </div>
      </div>
      <div className="font-sans" style={{ height: 28, flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8, padding: '0 12px', borderTop: `1px solid ${color.line}`, fontSize: 12.5, backgroundColor: alpha(color.raised, 40) }}>
        <span style={{ color: pushed ? color.green : color.blue, fontWeight: 600 }}>{caption[0]}</span>
        <span style={{ color: color.muted }}>{caption[1]}</span>
      </div>
    </div>
  );
};
