import { Keycap } from '../components/Hud';
import { Cursor } from '../components/Terminal';
import { during, linear, mix, pop, SPRING } from '../lib/motion';
import { cursorOpacity, typedLength } from '../lib/typing';
import { alpha, color } from '../theme';
import type { CardProps } from './BentoCards';

const Keys = ({ keys, pressed = 0 }: { keys: string[]; pressed?: number }) => (
  <span style={{ display: 'inline-flex', gap: 5 }}>
    {keys.map((key) => (
      <Keycap key={key} size={13} pressed={pressed}>{key}</Keycap>
    ))}
  </span>
);

const WORKTREES = [
  { branch: 'feat/task', at: 150, tone: color.amber },
  { branch: 'fix/parser', at: 240, tone: color.violet },
];

const BRANCH_TOP = 52;
const BRANCH_GAP = 50;
// Half the height of a branch label, so the trunk meets each connector.
const BRANCH_MID = 18;

export const WorktreeCard = ({ frame, fps }: CardProps) => {
  const branches = WORKTREES.map((worktree) => ({ ...worktree, grow: pop(frame, fps, worktree.at, SPRING.snappy) }));
  // The trunk stops at the newest branch instead of running into the shortcut row.
  const trunk = branches.reduce((reach, branch, index) => mix(reach, BRANCH_TOP + BRANCH_MID + index * BRANCH_GAP, branch.grow), 41);
  return (
    <>
      <div style={{ position: 'relative', height: 150 }}>
        <div style={{ position: 'absolute', left: 9, top: 10, height: trunk - 10, width: 2, backgroundColor: alpha(color.cyan, 50) }} />
        <div className="font-mono" style={{ position: 'absolute', left: 0, top: 0, display: 'flex', alignItems: 'center', gap: 12, fontSize: 18, color: color.fg }}>
          <span style={{ width: 20, height: 20, borderRadius: 999, backgroundColor: color.ink, border: `2px solid ${color.cyan}` }} />
          main
        </div>
        {branches.map((branch, index) => (
          <div key={branch.branch} style={{ position: 'absolute', left: 10, top: BRANCH_TOP + index * BRANCH_GAP, display: 'flex', alignItems: 'center' }}>
            <span style={{ width: 34 * branch.grow, height: 2, backgroundColor: branch.tone }} />
            <span
              className="font-mono"
              style={{
                padding: '6px 13px',
                borderRadius: 9,
                fontSize: 17,
                color: branch.tone,
                backgroundColor: alpha(branch.tone, 11),
                border: `1px solid ${alpha(branch.tone, 42)}`,
                opacity: Math.min(1, branch.grow * 1.5),
                transform: `translateX(${(1 - branch.grow) * -10}px)`,
              }}
            >
              {branch.branch}
            </span>
          </div>
        ))}
      </div>
      <div className="font-sans" style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 16, color: color.muted }}>
        <Keys keys={['Cmd', 'Opt', 'T']} pressed={Math.max(...WORKTREES.map((worktree) => during(frame, worktree.at - 8, worktree.at + 12, 5)))} />
        New Session in Worktree
      </div>
    </>
  );
};

const DROP_AT = 190;
const REATTACH_AT = 330;
const REMOTE_JOB = ['Compiling 41 / 96', 'Compiling 58 / 96', 'Compiling 77 / 96', 'Compiling 96 / 96'];

export const RemoteCard = ({ frame, fps }: CardProps) => {
  const link = 1 - pop(frame, fps, DROP_AT, SPRING.snappy) + pop(frame, fps, REATTACH_AT, SPRING.snappy);
  const attached = link > 0.5;
  const tone = attached ? color.green : color.amber;
  // The job keeps advancing through the gap: that is the whole point.
  const step = Math.min(REMOTE_JOB.length - 1, Math.floor(linear(frame, [120, 400]) * REMOTE_JOB.length));
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center' }}>
        <div className="font-sans" style={{ padding: '12px 16px', borderRadius: 12, fontSize: 19, fontWeight: 600, color: color.fg, backgroundColor: alpha(color.fg, 4), border: `1px solid ${color.lineStrong}`, opacity: mix(0.4, 1, link) }}>
          Zshell
        </div>
        <div style={{ flex: 1, height: 2, margin: '0 10px', background: `repeating-linear-gradient(90deg, ${tone} 0 8px, transparent 8px 16px)`, backgroundPositionX: frame * 0.8, opacity: mix(0.12, 1, link) }} />
        <div className="font-mono" style={{ padding: '12px 16px', borderRadius: 12, fontSize: 17, color: color.cyan, backgroundColor: alpha(color.cyan, 9), border: `1px solid ${alpha(color.cyan, 42)}` }}>
          zshell-server
        </div>
      </div>
      <div className="font-mono" style={{ marginTop: 14, fontSize: 15.5, color: color.faint }}>tailscale://devbox:7373</div>
      <div
        className="font-mono"
        style={{ marginTop: 14, padding: '12px 16px', borderRadius: 12, fontSize: 17, backgroundColor: alpha(color.raised, 70), border: `1px solid ${color.line}`, color: color.muted }}
      >
        {REMOTE_JOB[step]}
        <div style={{ marginTop: 10, height: 5, borderRadius: 999, backgroundColor: alpha(color.fg, 7) }}>
          <div style={{ width: `${linear(frame, [120, 400], [30, 100])}%`, height: '100%', borderRadius: 999, backgroundColor: color.cyan }} />
        </div>
      </div>
      <div className="font-sans" style={{ marginTop: 14, display: 'flex', alignItems: 'center', gap: 9, fontSize: 16.5, color: tone }}>
        <span style={{ width: 8, height: 8, borderRadius: 999, backgroundColor: tone }} />
        {attached ? (frame >= REATTACH_AT ? 'Reattached · screen and scrollback restored' : 'Attached') : 'Client closed · remote work continues'}
      </div>
    </>
  );
};

const QUERY = 'split';
const RESULTS = [
  { label: 'Split right', keys: ['Cmd', 'D'] },
  { label: 'Split down', keys: ['Cmd', 'Shift', 'D'] },
  { label: 'Git panel', keys: ['Cmd', 'Shift', 'G'] },
  { label: 'Files panel', keys: ['Cmd', 'Shift', 'E'] },
];
const TYPE = [140, 200] as const;
const MOVE_AT = 300;

export const PaletteCard = ({ frame, fps }: CardProps) => {
  const typed = typedLength(QUERY, frame, TYPE[0], TYPE[1]);
  const filtering = linear(frame, [TYPE[1] - 20, TYPE[1] + 6]);
  const selection = pop(frame, fps, MOVE_AT, SPRING.snappy);
  const ROW = 46;
  return (
    <div style={{ borderRadius: 14, overflow: 'hidden', backgroundColor: alpha(color.raised, 70), border: `1px solid ${color.lineStrong}` }}>
      <div className="font-sans" style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 16px', fontSize: 19, borderBottom: `1px solid ${color.line}` }}>
        <Keys keys={['Cmd', 'P']} pressed={during(frame, 96, 122, 6)} />
        <span className="font-mono" style={{ color: color.fg }}>
          {QUERY.slice(0, typed)}
          <Cursor opacity={cursorOpacity(frame, frame > TYPE[0] && frame < TYPE[1])} />
        </span>
      </div>
      <div style={{ position: 'relative', padding: 6 }}>
        <div
          style={{
            position: 'absolute',
            left: 6,
            right: 6,
            top: 6,
            height: ROW,
            borderRadius: 9,
            backgroundColor: alpha(color.cyan, 12),
            border: `1px solid ${alpha(color.cyan, 42)}`,
            transform: `translateY(${selection * ROW}px)`,
          }}
        />
        {RESULTS.map((result, index) => (
          <div
            key={result.label}
            className="font-sans"
            style={{
              position: 'relative',
              height: ROW,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              padding: '0 14px',
              fontSize: 19,
              color: color.fg,
              // Rows that do not match the query dim once it is typed.
              opacity: index < 2 ? 1 : mix(1, 0.28, filtering),
            }}
          >
            {result.label}
            <Keys keys={result.keys} />
          </div>
        ))}
      </div>
    </div>
  );
};
