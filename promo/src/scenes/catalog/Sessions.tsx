import type { CSSProperties } from 'react';
import { Keycap } from '../../components/Hud';
import { TerminalIcon } from '../../components/Icons';
import { linear } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import { Action, Badge, Code, Done, Group, ListRow, Panel, Progress, Setting, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const PersistenceDemo = ({ frame }: DemoProps) => {
  const enabled = frame >= 31 && frame < 179;
  const quit = frame >= 98 && frame < 145;
  const reconnected = frame >= 145;
  const history = frame >= 179;
  const compile = Math.floor(24 + 72 * linear(frame, [47, 178]));
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '630px 1fr', gap: 24, height: '100%' }}>
      <Shell title="Settings — Terminal"><div style={{ padding: 26 }}><Group title="Sessions"><Setting label="Keep sessions running after quitting" checked={enabled} focus={frame < 179} /><div style={{ padding: 19, fontSize: 21, color: color.muted, lineHeight: 1.6 }}>New terminals keep shells, agents, and servers running when Zshell quits.</div></Group><Group title="History"><Setting label="Restore session history on relaunch" checked={history} focus={history} /></Group><Panel title="Zshell"><ListRow active={quit}>Quit Zshell <Keycap size={17} pressed={quit ? 1 : 0}>Cmd + Q</Keycap></ListRow><ListRow>Quit and End All Sessions</ListRow></Panel><div style={{ marginTop: 28 }}><Badge tone={quit ? 'amber' : 'blue'}>{quit ? 'App closed' : reconnected ? 'Reopened' : 'Open a new terminal'}</Badge></div></div></Shell>
      <Shell title={quit ? 'Desktop' : 'app — restored workspace'} sidebar={!quit ? <><ListRow>Work</ListRow><ListRow active>app</ListRow><ListRow indent={16}>api</ListRow><ListRow>Personal</ListRow><ListRow indent={16}>notes</ListRow></> : undefined} toolbar={!quit ? <div style={{ display: 'flex', gap: 15 }}><Badge active={!history}>server</Badge><Badge active={history}>tests</Badge><Badge active={false}>docs</Badge></div> : undefined}>
        {quit ? <div style={{ height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 28, backgroundColor: color.raised }}><div style={{ width: 116, height: 116, borderRadius: 25, display: 'flex', alignItems: 'center', justifyContent: 'center', color: color.blue, backgroundColor: color.surface, border: `1px solid ${color.lineStrong}` }}><TerminalIcon size={72} /></div><div style={{ fontSize: 34 }}>Zshell</div><Action active={frame >= 131}>Open</Action></div> : <div style={{ height: '100%', display: 'grid', gridTemplateRows: '1fr 218px' }}>
          {history ? <Panel title="tests — restored scrollback"><div className="font-mono" style={{ padding: 20, fontSize: 23, lineHeight: 1.6 }}><div style={{ color: color.faint }}>› pnpm test<br />2 tests passed · 1.28 s</div><div style={{ height: 1, backgroundColor: color.line, margin: '12px 0' }} /><div>› echo $$</div><div>4183</div><div>› <span style={{ display: 'inline-block', width: 3, height: 25, verticalAlign: 'text-bottom', backgroundColor: color.blue }} /></div></div></Panel> : <div className="font-mono" style={{ padding: 22, fontSize: 23, lineHeight: 1.6 }}>
            <div style={{ color: color.muted }}>› echo $$</div><div>3421</div><div style={{ marginTop: 12 }}>› pnpm run dev</div><div style={{ color: color.green }}>Local: http://localhost:3000</div><div style={{ marginTop: 12 }}>Compiling {compile} / 96</div>{reconnected ? <div style={{ marginTop: 15 }}><Done>Same shell · pid 3421</Done></div> : null}
          </div>}
          <Panel title="Browser — http://localhost:3000"><div style={{ display: 'flex', gap: 20, alignItems: 'center', padding: 22 }}><div style={{ fontSize: 27 }}>Workspace preview</div><Badge>app</Badge></div><div style={{ padding: '0 22px 22px', fontSize: 21, color: color.muted }}>Projects: app · api · docs</div></Panel>
        </div>}
      </Shell>
    </div>
  );
};

const RemoteDemo = ({ frame }: DemoProps) => {
  const detached = frame >= 81 && frame < 139;
  const reattached = frame >= 139;
  const controlled = frame >= 161;
  const pairing = frame >= 71;
  const approved = frame >= 142;
  const revoked = frame >= 226;
  const quickVisible = frame >= 65 && frame < 98 || frame >= 121 && frame < 142;
  const query = 'git status'.slice(0, typedLength('git status', frame, 162, 191));
  const compiled = Math.floor(40 + 56 * linear(frame, [39, 207]));
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '760px 1fr', gap: 24, height: '100%' }}>
      <Shell title="Remote Hosts — devbox"><div style={{ padding: 22 }}>
        {frame < 63 ? <Group title="Remote Hosts"><Setting label="Name" value="devbox" /><Setting label="Address" value={frame < 37 ? 'ssh://demo@devbox:22' : 'tailscale://devbox:7373'} focus /><Setting label="Server Executable" value="~/.local/bin/zshell-server" /><Setting label="Remote Directory" value="~/src/app" /><div style={{ display: 'flex', gap: 12, padding: 16 }}><Action>Install / Update Server</Action><Action active>Connect Host</Action></div><ListRow>Open Remote Project</ListRow></Group> : <Panel title="devbox — shared remote session"><div className="font-mono" style={{ padding: 22, fontSize: 24, lineHeight: 1.8 }}><div style={{ color: color.muted }}>~/src/app · session 72f3</div><div>› go build ./...</div><div style={{ marginTop: 13 }}>Compiling {detached ? 57 : compiled} / 96</div>{reattached ? <div style={{ marginTop: 15 }}><Done>Screen and scrollback restored</Done></div> : null}</div><div style={{ display: 'flex', gap: 12, padding: '0 20px 20px' }}><Badge tone={detached ? 'amber' : 'green'}>{detached ? 'Detached' : 'Connected'}</Badge><Action active={detached ? frame >= 129 : frame >= 72 && frame < 89}>{detached ? 'Reconnect' : 'Detach Remote Session'}</Action>{reattached ? <Action active={frame >= 150 && frame < 174}>Take Terminal Control</Action> : null}</div><div style={{ padding: '0 20px 20px', fontSize: 19, lineHeight: 1.5, color: color.muted }}>Connected clients: 2<div>{controlled ? 'This client controls terminal input and size.' : 'Another client controls terminal input and size.'}</div></div></Panel>}
        <Panel title={approved ? 'Mac workspace · app — zsh' : 'Quick Terminal'} style={{ marginTop: 20 }}>
          {approved ? <div className="font-mono" style={{ padding: 18, fontSize: 22, lineHeight: 1.6 }}>› {query}{frame >= 191 ? <><div>On branch main</div><div style={{ color: color.green }}>working tree clean</div></> : null}</div> : <><div style={{ padding: 16, display: 'flex', gap: 13, alignItems: 'center' }}><Keycap size={17} pressed={frame >= 60 && frame < 76 || frame >= 96 && frame < 108 || frame >= 119 && frame < 129 ? 1 : 0}>Cmd + I</Keycap><Badge active={quickVisible}>Reuse workspace</Badge><span style={{ marginLeft: 'auto', fontSize: 18, color: color.muted }}>Pin</span></div>{quickVisible ? <div className="font-mono" style={{ padding: '0 20px 16px', fontSize: 22, lineHeight: 1.6 }}>› pnpm run dev<div style={{ color: color.green }}>Local: http://localhost:3000</div></div> : <Setting label="Session behavior" value="Reuse workspace" />}</>}
          {frame < 63 ? <Setting label="Opacity" progress={0.65} /> : null}
        </Panel>
      </div></Shell>
      <Shell title="Settings — Browser · Browser Access"><div style={{ padding: 22 }}><Group title="Browser Access"><Setting label="Enable browser access" checked={frame >= 22} /><Setting label="Listen on" value={frame >= 46 ? 'LAN · 192.168.1.12' : 'Localhost Only'} focus={frame >= 46 && frame < 71} /><Setting label="HTTPS port" value="7443" /><div style={{ display: 'flex', gap: 12, padding: 14 }}><Action>Export TLS Certificate…</Action><Action>Open Private Network Page</Action></div></Group>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 300px', gap: 20 }}>
          <div><Group title={approved ? 'Authorized Clients' : 'Pairing Requests'}>{pairing ? <><ListRow trailing={<Badge tone="blue">438221</Badge>}>Phone</ListRow><div style={{ padding: 14, display: 'flex', gap: 12 }}><Action active={frame >= 133 && frame < 152 || revoked}>{approved ? 'Revoke' : 'Approve'}</Action>{!approved ? <Action>Deny</Action> : null}</div>{approved ? <ListRow>Revoke All Clients</ListRow> : null}</> : <div style={{ height: 140 }} />}</Group><div style={{ fontSize: 20, color: color.muted, lineHeight: 1.7 }}>https://192.168.1.12:7443<div>Mac · local terminal panes</div></div></div>
          <Panel title="Phone · Zshell" style={{ borderRadius: 23, borderWidth: 3 }}>{!approved ? <div style={{ padding: 18, fontSize: 22 }}><div style={{ marginBottom: 18 }}>Browser Access</div><div style={{ color: color.muted, fontSize: 18 }}>Client name</div><ListRow>Phone</ListRow><div style={{ marginTop: 10 }}><Action active={pairing}>Request Pairing</Action></div>{pairing ? <div className="font-mono" style={{ color: color.blue, marginTop: 24, textAlign: 'center', fontSize: 30 }}>438221</div> : null}</div> : <div style={{ padding: 18, fontSize: 20 }}><Badge tone={revoked ? 'red' : 'green'}>{revoked ? 'Disconnected' : 'Connected'}</Badge><div style={{ margin: '20px 0 10px', color: color.muted }}>app — zsh</div><div className="font-mono" style={{ fontSize: 20, lineHeight: 1.8 }}>› {query}{frame >= 191 ? <><div>On branch main</div><div style={{ color: color.green }}>working tree clean</div></> : null}</div><div style={{ marginTop: 22, fontSize: 18, color: color.muted }}>Resize terminal to browser <span style={{ color: color.fg }}>Off</span></div></div>}</Panel>
        </div>
      </div></Shell>
    </div>
  );
};

const InfoDemo = ({ frame }: DemoProps) => {
  const remote = frame >= 126;
  const menu = frame >= 46 && frame < 97 || frame >= 160 && frame < 200;
  const ended = frame >= 98 && !remote;
  const copied = frame >= 174 && frame < 220;
  const controlled = frame >= 212;
  return (
    <Shell title={remote ? 'devbox — remote session info' : 'app — session info'}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 720px', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}`, position: 'relative' }}>
          <Terminal frame={frame} fontSize={25}>
            <div style={{ color: color.muted }}>{remote ? 'demo@devbox:~/src/app/api' : '~/src/app/api'}</div><div style={{ marginTop: 18 }}>› pnpm run dev</div><div style={{ color: color.green }}>Local: http://localhost:3000</div><div style={{ marginTop: 16 }}>{remote ? 'Watching changes on devbox…' : ended ? 'Terminated: 15' : 'Watching src/routes.ts…'}</div>{remote ? <div style={{ marginTop: 28 }}><Badge tone={controlled ? 'green' : 'blue'}>{controlled ? 'This client controls terminal input and size.' : 'Another client controls terminal input and size.'}</Badge></div> : null}
            {frame >= 25 && frame < 46 ? <Panel title="Default Browser" style={{ marginTop: 35 }}><div style={{ padding: 18, fontSize: 22, borderBottom: `1px solid ${color.line}` }}>http://localhost:3000</div><div style={{ padding: 22, fontSize: 30 }}>Workspace preview</div></Panel> : null}
          </Terminal>
          {copied ? <div style={{ position: 'absolute', left: 32, right: 32, bottom: 26 }}><Panel title="Clipboard"><Code lines={['5217']} /></Panel></div> : null}
        </div>
        <div style={{ padding: 26 }}>
          <Group title="Info"><Setting label="CURRENT DIRECTORY" value={remote ? '~/src/app/api' : '/Users/demo/src/app/api'} /><Setting label="PROJECT DIRECTORY" value={remote ? '~/src/app' : '/Users/demo/src/app'} /></Group>
          <Group title="PROCESSES" style={{ position: 'relative' }}><ListRow trailing={<span style={{ color: color.muted, fontSize: 20 }}>{remote ? '22% · 84 MiB' : '0% · 12 MiB'}</span>}>{remote ? 'node  5217' : 'zsh  3418'}</ListRow>{!ended && !remote ? <ListRow active trailing={<span style={{ color: color.muted, fontSize: 20 }}>18% · 84 MiB</span>}>node 3421</ListRow> : null}{menu ? <Panel style={{ position: 'absolute', right: 0, top: 83, width: 360, zIndex: 2, boxShadow: `0 18px 40px ${alpha(color.shadow, 15)}` }}>{!remote ? <><ListRow active={frame >= 84}>Terminate</ListRow><ListRow>Force Kill</ListRow></> : null}<ListRow active={remote}>Copy PID</ListRow><ListRow>Copy Executable Path</ListRow></Panel> : null}</Group>
          {!remote ? <Group title="PORTS">{ended ? <ListRow>No listening ports</ListRow> : <ListRow active={frame >= 25 && frame < 46} trailing={<Action active={frame >= 84 && frame < 98}>Kill Process (node)</Action>}>3000 node</ListRow>}<div style={{ padding: '4px 17px 16px', fontSize: 20, color: color.muted }}>Open in Browser · Copy URL</div></Group> : <Group title="Remote connection"><Setting label="Status" value="Connected · devbox" /><div style={{ padding: 15 }}><Action active={frame >= 199 && frame < 225}>Take Terminal Control</Action></div></Group>}
        </div>
      </div>
    </Shell>
  );
};

const profilePalette: CSSProperties = {
  '--color-surface': '#eff1f5', '--color-raised': '#e6e9ef', '--color-fg': '#4c4f69',
  '--color-muted': '#6c6f85', '--color-faint': '#9ca0b0', '--color-blue': '#8839ef',
  '--color-line': '#ccd0da', '--color-line-strong': '#acb0be',
} as CSSProperties;

const ProfileDemo = ({ frame }: DemoProps) => {
  const matched = frame >= 48;
  const launch = frame >= 119;
  const newPane = frame >= 186;
  const original = frame >= 218;
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '740px 1fr', gap: 24, height: '100%' }}>
      <Shell title="Terminal Profiles — Review"><div style={{ padding: 24 }}>
        {!launch ? <><Group title="Automatic matching"><Setting label="Enable automatic matching" checked /><Setting label="Host pattern" value="localhost" /><Setting label="User pattern" value="demo" /><Setting label="Directory pattern" value="*/src/app*" /><Setting label="Foreground program pattern" value="zsh" focus={matched} /></Group><Group title="Appearance"><Setting label="Light theme" value="Catppuccin Latte" /><Setting label="Font family" value="SF Mono" /><Setting label="Font size" value="27" /><Setting label="Cursor Shape" value="Block" /><Setting label="Cursor blinking" value="On" /></Group></> : <><Group title="New terminals"><Setting label="Environment Variables" value="PROJECT_MODE=review" focus={frame < 162} /><Setting label="Initialization Command" value={'printf "Ready for review\\n"'} /><Setting label="Startup program" value="Inherit" /><div style={{ padding: 14, fontSize: 20, lineHeight: 1.5, color: color.muted }}>Appearance applies immediately. Environment and startup settings apply only to new terminals.</div></Group><div style={{ textAlign: 'right', marginBottom: 16 }}><Action active={frame >= 128 && frame < 155}>Save</Action></div><Group title="Terminal context menu"><ListRow active={!original}>Automatic</ListRow><ListRow active={original}>Original Settings</ListRow><ListRow>Review</ListRow><ListRow>Manage Terminal Profiles…</ListRow></Group></>}
      </div></Shell>
      <Shell title="app — profile matching" toolbar={<div style={{ display: 'flex', gap: 14, alignItems: 'center' }}><Badge tone={matched && !original ? 'violet' : 'blue'}>{matched && !original ? 'Review' : 'Original Settings'}</Badge>{newPane ? <Action active>New Session</Action> : null}</div>}>
        <div style={{ height: '100%', display: 'grid', gridTemplateRows: newPane ? 'minmax(0, 1fr) 245px' : '1fr' }}>
          <div style={{ minHeight: 0, overflow: 'hidden', ...(matched && !original ? profilePalette : {}) }}><Terminal frame={frame} fontSize={newPane ? 23 : matched && !original ? 27 : 24} shape={matched && !original ? 'block' : 'bar'} style={{ padding: newPane ? 20 : 28, lineHeight: newPane ? 1.45 : 1.7, fontFamily: matched && !original ? '"SF Mono", Menlo, monospace' : undefined }}>
            <div style={{ color: color.muted }}>localhost · demo · zsh</div><div>pid 3418 · ~/src/app</div><div style={{ marginTop: newPane ? 12 : 30 }}>› echo $&#123;PROJECT_MODE:-unset&#125;</div><div>unset</div>{matched ? <div style={{ marginTop: newPane ? 12 : 28 }}><Badge tone="violet">{original ? 'Original Settings' : 'Review'}</Badge></div> : null}
          </Terminal></div>
          {newPane ? <Panel title="app — new terminal" style={profilePalette}><div className="font-mono" style={{ padding: 20, fontSize: 23, lineHeight: 1.65, color: color.fg }}><div>Ready for review</div><div>› echo $PROJECT_MODE</div><div style={{ color: color.green }}>review</div><div>› <span style={{ display: 'inline-block', width: 14, height: 25, backgroundColor: color.blue, verticalAlign: 'text-bottom' }} /></div></div></Panel> : null}
        </div>
      </Shell>
    </div>
  );
};

const SessionsBody = (props: DemoProps) => {
  if (props.step === 0) return <PersistenceDemo {...props} />;
  if (props.step === 1) return <RemoteDemo {...props} />;
  if (props.step === 2) return <InfoDemo {...props} />;
  return <ProfileDemo {...props} />;
};

export const sessionsChapter: ChapterSpec = {
  id: 'sessions', en: 'Keep your session in reach', zh: '会话、设备和运行状态，一直在手边',
  steps: [
    { en: 'Return to a live shell · restore the layout', zh: '重连同一进程，恢复布局与历史' },
    { en: 'Detach remotely · pair another screen', zh: '远程接续，在 Mac 批准浏览器配对' },
    { en: 'Inspect processes, directories and ports', zh: '查看目录、进程用量与端口' },
    { en: 'Match a profile · start a fresh environment', zh: '按场景匹配外观，新终端应用环境' },
  ],
  features: [
    'Keep sessions running after quitting applies to newly opened local terminals and reconnects to the same live PID',
    'Project/tab/pane layout restoration is independent of process preservation and static scrollback restoration',
    'Restore session history on relaunch presents old output above a fresh shell when the original process is unavailable',
    'Normal Quit versus Quit and End All Sessions; host restarts end live processes',
    'Remote Hosts saved SSH and Tailscale connections, Install / Update Server, Connect Host and Open Remote Project',
    'Shared remote sessions detach and reconnect to the same host job, output screen and scrollback',
    'Remote controller/client state and Take Terminal Control; ordinary SSH is not claimed to preserve shared jobs',
    'Global Quick Terminal Cmd+I, reusable shell, hide/reopen preservation, pin and opacity',
    'Browser settings include Browser Access, Enable browser access, Listen on private interface, HTTPS port, TLS certificate export',
    'Phone Request Pairing, matching code, Mac Approve/Deny, shared local-terminal input and Revoke/Revoke All Clients',
    'Browser Access attaches existing main-window local panes only and does not expose the independent Quick Terminal',
    'Info current/project directories, process PID, CPU percentage and memory, local Terminate/Force Kill and listening ports',
    'Open in Browser, Copy URL, local Kill Process; remote process inspection permits copies without local PID signalling',
    'Automatic Terminal Profiles match host/user/directory/foreground-program conditions and apply theme/font/cursor live',
    'Profile environment and initialization apply only to newly opened terminals; Original Settings preserves current processes',
  ],
  sources: [
    'mac/zshell/Settings/SettingsTerminalPane.swift', 'mac/zshell/PersistentPTY.swift',
    'mac/zshell/SessionStore.swift', 'mac/zshell/TerminalHistory.swift', 'mac/zshell/RemoteHostsController.swift',
    'mac/zshell/RemoteSessionConnection.swift', 'mac/zshell/RemoteProjectInfoView.swift',
    'mac/zshell/GlobalTerminalOverlay.swift', 'mac/zshell/QuickTerminalWorkspaceView.swift',
    'mac/zshell/Settings/SettingsBrowserAccessPane.swift', 'mac/zshell/BrowserAccessController.swift', 'mac/zshell/Settings/SettingsBrowserPane.swift',
    'mac/zshell/SessionInfoPanel.swift', 'mac/zshell/TerminalProfiles.swift',
    'mac/zshell/TerminalProfileEditor.swift', 'mac/zshell/TerminalProfileSession.swift', 'mac/zshell/TerminalSession.swift',
  ],
  Body: SessionsBody,
};
