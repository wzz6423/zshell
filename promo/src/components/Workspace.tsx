import type { CSSProperties, ReactNode } from 'react';
import { alpha, color, type Tone } from '../theme';
import { AgentIcon, BranchIcon, FolderIcon, TerminalIcon } from './Icons';

export type AgentPhase = 'created' | 'working' | 'blocked' | 'done';

const PHASE: Record<AgentPhase, { label: string; tone: Tone }> = {
  created: { label: 'Created', tone: 'violet' },
  working: { label: 'Working', tone: 'amber' },
  blocked: { label: 'Blocked', tone: 'red' },
  done: { label: 'Done', tone: 'green' },
};

export const AgentBadge = ({ phase, pulse = 0 }: { phase: AgentPhase; pulse?: number }) => {
  const { label, tone } = PHASE[phase];
  return (
    <span
      className="font-mono"
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 7,
        padding: '3px 10px',
        borderRadius: 999,
        fontSize: 13,
        fontWeight: 600,
        color: color[tone],
        backgroundColor: alpha(color[tone], 14),
        border: `1px solid ${alpha(color[tone], 40)}`,
        boxShadow: `0 0 ${14 * pulse}px ${alpha(color[tone], 55)}`,
      }}
    >
      <span style={{ width: 7, height: 7, borderRadius: 999, backgroundColor: color[tone] }} />
      {label}
    </span>
  );
};

const TRAFFIC = ['#FF5F57', '#FEBC2E', '#28C840'];

const SidebarRow = ({ icon, label, active, trailing, indent = 0 }: { icon: ReactNode; label: string; active?: boolean; trailing?: ReactNode; indent?: number }) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 9,
      height: 34,
      marginLeft: indent,
      padding: '0 10px',
      borderRadius: 8,
      fontSize: 15,
      color: active ? color.fg : color.muted,
      backgroundColor: active ? alpha(color.fg, 7) : 'transparent',
    }}
  >
    {icon}
    <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{label}</span>
    {trailing}
  </div>
);

export type WorkspaceProps = {
  width?: number;
  height?: number;
  left: ReactNode;
  right?: ReactNode;
  // 0 keeps a single pane; 1 gives the right pane its full share.
  split?: number;
  rightTitle?: string;
  agent?: AgentPhase | null;
  agentPulse?: number;
  style?: CSSProperties;
};

const SIDEBAR = 224;
const TITLEBAR = 46;
const RIGHT_SHARE = 0.4;

export const Workspace = ({
  width = 1600,
  height = 880,
  left,
  right,
  split = 0,
  rightTitle = 'zsh',
  agent = null,
  agentPulse = 0,
  style,
}: WorkspaceProps) => {
  const paneArea = width - SIDEBAR;
  const rightWidth = paneArea * RIGHT_SHARE * split;

  return (
    <div
      className="font-sans"
      style={{
        width,
        height,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        borderRadius: 16,
        backgroundColor: color.surface,
        border: `1px solid ${color.lineStrong}`,
        boxShadow: `0 60px 140px ${alpha(color.shadow, 18)}, 0 0 0 1px ${alpha(color.shadow, 6)}, 0 0 120px ${alpha(color.blue, 12)}`,
        ...style,
      }}
    >
      <div
        style={{
          height: TITLEBAR,
          flexShrink: 0,
          display: 'flex',
          alignItems: 'center',
          padding: '0 18px',
          borderBottom: `1px solid ${color.line}`,
          backgroundColor: color.raised,
        }}
      >
        <div style={{ display: 'flex', gap: 9, width: SIDEBAR - 18 }}>
          {TRAFFIC.map((dot) => (
            <span key={dot} style={{ width: 13, height: 13, borderRadius: 999, backgroundColor: dot }} />
          ))}
        </div>
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', gap: 10, fontSize: 15, color: color.muted }}>
          <span style={{ color: color.fg, fontWeight: 600 }}>app</span>
          <span style={{ color: color.faint }}>/</span>
          <BranchIcon size={15} />
          <span className="font-mono" style={{ fontSize: 14 }}>main</span>
        </div>
      </div>

      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <div
          style={{
            width: SIDEBAR,
            flexShrink: 0,
            padding: '14px 10px',
            display: 'flex',
            flexDirection: 'column',
            gap: 3,
            borderRight: `1px solid ${color.line}`,
            backgroundColor: alpha(color.raised, 60),
          }}
        >
          <div style={{ padding: '2px 10px 8px', fontSize: 12, letterSpacing: 1.2, color: color.faint }}>PROJECTS</div>
          <SidebarRow icon={<FolderIcon size={17} color={color.cyan} />} label="app" active />
          <SidebarRow indent={14} icon={<TerminalIcon size={16} />} label="zsh" />
          {agent ? (
            <SidebarRow
              indent={14}
              icon={<AgentIcon size={16} color={color[PHASE[agent].tone]} />}
              label="tests"
              trailing={<span style={{ width: 8, height: 8, borderRadius: 999, backgroundColor: color[PHASE[agent].tone], boxShadow: `0 0 ${10 * agentPulse}px ${color[PHASE[agent].tone]}` }} />}
            />
          ) : null}
          <SidebarRow icon={<FolderIcon size={17} />} label="website" />
          <SidebarRow icon={<FolderIcon size={17} />} label="devbox (SSH)" />
        </div>

        <div style={{ flex: 1, display: 'flex', minWidth: 0 }}>
          <div style={{ flex: 1, minWidth: 0, position: 'relative', overflow: 'hidden' }}>{left}</div>
          {right ? (
            <div
              style={{
                width: rightWidth,
                flexShrink: 0,
                overflow: 'hidden',
                borderLeft: `1px solid ${alpha(color.fg, 14 * Math.min(1, split * 3))}`,
                backgroundColor: alpha(color.raised, 70),
              }}
            >
              {/* Fixed inner width: the pane slides open instead of reflowing its text. */}
              <div style={{ width: paneArea * RIGHT_SHARE, height: '100%', display: 'flex', flexDirection: 'column' }}>
                <div
                  style={{
                    height: 38,
                    flexShrink: 0,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    padding: '0 16px',
                    fontSize: 14,
                    color: color.muted,
                    borderBottom: `1px solid ${color.line}`,
                  }}
                >
                  <span className="font-mono">{rightTitle}</span>
                  {agent ? <AgentBadge phase={agent} pulse={agentPulse} /> : null}
                </div>
                <div style={{ flex: 1, minHeight: 0, position: 'relative' }}>{right}</div>
              </div>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
};
