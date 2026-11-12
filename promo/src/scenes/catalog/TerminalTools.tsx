import { Img } from 'remotion';
import icon from '../../../../web/public/zshell-icon.png';
import { Keycap } from '../../components/Hud';
import { linear } from '../../lib/motion';
import { alpha, color } from '../../theme';
import { Action, Badge, Code, Done, Group, ListRow, Panel, Setting, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const FindAndClear = ({ frame }: DemoProps) => {
  const found = frame >= 38;
  const next = frame >= 90;
  const cleared = frame >= 175;
  const recordDeleted = frame >= 215;
  return <Shell title="app — terminal search" toolbar={<div style={{ display: 'flex', gap: 14 }}><Badge active={!cleared}>Cmd+F · Find</Badge><Badge active={next && !cleared}>Cmd+G · Next</Badge><Badge active={cleared}>Cmd+K · Clear</Badge></div>}>
    <div style={{ display: 'grid', gridTemplateColumns: '1.1fr 0.9fr', height: '100%' }}>
      <div style={{ borderRight: `1px solid ${color.line}` }}>
        {!cleared ? <div style={{ display: 'flex', gap: 18, alignItems: 'center', padding: 24, borderBottom: `1px solid ${color.line}`, fontSize: 24 }}><span style={{ color: color.blue }}>{found ? 'PASS' : 'Find…'}</span><span style={{ marginLeft: 'auto', color: color.muted }}>{found ? `${next ? 2 : 1} / 2` : ''}</span><Action active={next}>↓ Next</Action></div> : null}
        <Terminal frame={frame} command={cleared ? 'git status' : ''}>{!cleared ? <><div>› bun test</div><div style={{ backgroundColor: found && !next ? alpha(color.amber, 20) : 'transparent' }}>PASS src/projects.test.ts</div><div style={{ backgroundColor: found && next ? alpha(color.amber, 20) : 'transparent' }}>PASS src/panes.test.ts</div><div style={{ color: color.green }}>37 pass · 0 fail</div></> : <Badge>Visible terminal buffer cleared</Badge>}</Terminal>
      </div>
      <div style={{ padding: 28 }}><Group title="Command History"><ListRow active>git status</ListRow>{!recordDeleted ? <ListRow>bun test</ListRow> : null}<div style={{ padding: 18, display: 'flex', gap: 12 }}><Action active={frame >= 194 && frame < 215}>Delete</Action><Action>Clear History…</Action></div>{recordDeleted ? <div style={{ padding: 18 }}><Done>Selected history record removed</Done></div> : null}</Group><Panel title="Find controls"><ListRow>Use Selection for Find · Cmd+E</ListRow><ListRow>Find Previous · Shift+Return</ListRow><ListRow>Search Terminal Logs · Cmd+Shift+F</ListRow></Panel></div>
    </div>
  </Shell>;
};

const ForegroundKeys = ({ frame }: DemoProps) => {
  const blocked = frame >= 45 && frame < 145;
  const captured = frame >= 82;
  const request = frame >= 155 && frame < 215;
  const allowed = frame >= 215;
  return <Shell title="app — foreground application" toolbar={<div style={{ display: 'flex', gap: 16, alignItems: 'center' }}><Badge active={blocked}>Block Zshell Commands</Badge><Keycap size={18} pressed={frame >= 70 && frame < 95 ? 1 : 0}>Ctrl+Return</Keycap><span style={{ color: color.muted, fontSize: 22 }}>{blocked ? 'Keys go to the foreground application' : 'Zshell shortcuts enabled'}</span></div>}>
    <div style={{ display: 'grid', gridTemplateColumns: '1.1fr 0.9fr', height: '100%' }}>
      <div style={{ position: 'relative', borderRight: `1px solid ${color.line}` }}><Terminal frame={frame} command="" fontSize={25}><div style={{ color: color.violet }}>Claude Code</div><div style={{ marginTop: 18 }}>› Inspect the project and preserve its API.</div><Panel title="Terminal image rendering" style={{ marginTop: 25 }}><div style={{ display: 'flex', alignItems: 'center', gap: 28, padding: 24 }}><Img src={icon} style={{ width: 140, height: 140 }} /><div style={{ fontSize: 25 }}>{captured ? 'Foreground application received Ctrl+Return' : 'Project preview'}</div></div></Panel>{allowed ? <div style={{ marginTop: 24 }}><Done>Clipboard returned after approval</Done></div> : null}</Terminal>{request ? <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', backgroundColor: alpha(color.surface, 75) }}><Panel title="Authorize Clipboard Access" style={{ width: 780 }}><div style={{ padding: 24, fontSize: 24 }}>A program is attempting to read from the clipboard.</div><Code lines={['Project preview']} /><div style={{ padding: 24, display: 'flex', justifyContent: 'flex-end', gap: 16 }}><Action>Deny</Action><Action active={frame >= 196}>Allow</Action></div></Panel></div> : null}</div>
      <div style={{ padding: 28 }}><Panel title="Terminal context menu"><ListRow active={blocked}>{blocked ? '✓' : ''} Block Zshell Commands</ListRow><ListRow>Copy · Paste · Select All</ListRow><ListRow>Terminal Profiles</ListRow><ListRow>Show Terminal Context Menu · Shift+F10</ListRow></Panel><div style={{ marginTop: 24 }}><Badge tone={captured ? 'green' : 'blue'}>{captured ? 'Foreground shortcut handled' : 'Pane-specific shortcut control'}</Badge></div><Panel title="Clipboard request" style={{ marginTop: 24 }}><Code lines={["printf '\\e]52;c;?\\a'", allowed ? '→ approved clipboard read' : '→ macOS approval dialog']} style={{ fontSize: 23 }} /></Panel></div>
    </div>
  </Shell>;
};

const QuickModes = ({ frame }: DemoProps) => {
  const fresh = frame >= 162;
  const hidden = frame >= 97 && frame < 120 || frame >= 204 && frame < 225;
  const shownAgain = frame >= 225;
  const split = frame >= 65 && !fresh;
  return <div style={{ display: 'grid', gridTemplateColumns: '650px 1fr', gap: 28, height: '100%' }}>
    <Shell title="Settings — Quick Terminal"><div style={{ padding: 28 }}><Group title="Quick Terminal"><Setting label="Enable Quick Terminal" checked /><Setting label="Session behavior" value={fresh ? 'New workspace each time' : 'Reuse workspace'} focus /><Setting label="Shortcut" value="Cmd+I" /><Setting label="Size" value={`${Math.round(45 + linear(frame, [22, 65]) * 15)}%`} progress={0.6} /><Setting label="Opacity" value="85%" progress={0.85} /></Group><div style={{ color: color.muted, fontSize: 23, lineHeight: 1.6 }}>{fresh ? 'Hiding ends this workspace and its tasks.' : 'Hiding keeps the same panes and running tasks.'}</div><div style={{ marginTop: 26 }}><Keycap size={20} pressed={hidden ? 1 : 0}>Cmd+I · show / hide</Keycap></div></div></Shell>
    <Panel title="Desktop" style={{ position: 'relative', height: '100%', backgroundColor: color.raised }}><div style={{ padding: 28, fontSize: 26, color: color.muted }}>Your current application</div>{hidden ? <div style={{ position: 'absolute', top: '45%', left: 38 }}><Badge tone={fresh ? 'amber' : 'green'}>{fresh ? 'Workspace ended' : 'Server continues in hidden workspace'}</Badge></div> : <div style={{ position: 'absolute', left: 28, right: 28, top: 135, height: 460 }}><Shell title={fresh ? 'Quick Terminal — new workspace' : 'Quick Terminal — reusable workspace'} toolbar={<div style={{ display: 'flex', gap: 14 }}><Action active={split}>Split Right</Action><Action>Split Down</Action><Badge active={!fresh && frame >= 80}>{!fresh && frame >= 80 ? 'Pinned' : 'Pin'}</Badge></div>}><div style={{ display: 'grid', gridTemplateColumns: split ? '1fr 1fr' : '1fr', height: '100%' }}><Terminal fontSize={22} frame={frame} command={fresh ? '' : 'bun run dev'}>{fresh ? <><div>› echo $$</div><div>{shownAgain ? '5598' : '5472'}</div><Badge>Fresh shell · empty workspace</Badge></> : <><div>pid 3417</div><div style={{ color: color.green, marginTop: 15 }}>Local: localhost:3000</div>{frame >= 120 ? <div style={{ marginTop: 20 }}><Done>Same shell and split layout</Done></div> : null}</>}</Terminal>{split ? <Panel title="tests"><Terminal fontSize={20} frame={frame} command="bun test --watch"><div style={{ color: color.green }}>37 pass · watching</div></Terminal></Panel> : null}</div></Shell></div>}</Panel>
  </div>;
};

const Notifications = ({ frame }: DemoProps) => {
  const failed = frame >= 104;
  const history = frame >= 172;
  const returned = frame >= 214;
  const mode = frame < 65 ? 'Normal' : frame < 104 ? 'Paused' : 'Error';
  const tone = mode === 'Error' ? 'red' : mode === 'Paused' ? 'amber' : 'blue';
  return <Shell title="app — progress and notifications">
    <div style={{ display: 'grid', gridTemplateColumns: '620px 1fr', height: '100%' }}>
      <div style={{ padding: 28, borderRight: `1px solid ${color.line}` }}><Group title="Terminal · Notifications"><Setting label="Long-running commands" value={frame < 35 ? 'Off' : '30s'} focus /><Setting label="Failed commands" checked /><Setting label="Terminal bell" checked /><div style={{ padding: 18 }}><Action active={history}>Notification History…</Action></div></Group><Group title="Program progress · OSC 9;4"><Code lines={[mode === 'Normal' ? "printf '\\e]9;4;1;60\\a'" : mode === 'Paused' ? "printf '\\e]9;4;4;60\\a'" : "printf '\\e]9;4;2;60\\a'"]} style={{ fontSize: 21 }} /><Badge tone={tone}>{mode}</Badge></Group><div style={{ fontSize: 22, color: color.muted }}>Completion settings apply to new zsh sessions.</div></div>
      <div style={{ padding: 28, position: 'relative' }}>{history && !returned ? <Panel title="Notification History"><div style={{ padding: 18, display: 'flex', gap: 12 }}><Badge active={false}>All</Badge><Badge tone="red">Failed</Badge><Badge active={false}>Pending</Badge></div><ListRow active trailing={<Badge tone="red">Exit 1</Badge>}>app · tests</ListRow><ListRow>app · build · 32s · Exit 0</ListRow><div style={{ padding: 22 }}><Action active={frame >= 195}>Show Pane</Action></div></Panel> : <><div style={{ height: 7, borderRadius: 999, backgroundColor: alpha(color.fg, 8) }}><div style={{ height: '100%', width: '60%', backgroundColor: color[tone] }} /></div><Terminal frame={frame} style={{ height: 340 }} command=""><div>› {failed ? 'bun test' : 'bun run build'}</div><div style={{ marginTop: 20, color: failed ? color.red : color.green }}>{failed ? '1 test failed · Exit 1' : 'Build complete · 32s · Exit 0'}</div>{returned ? <div style={{ marginTop: 28 }}><Done>Returned to the source pane</Done></div> : null}</Terminal><Panel title="macOS Notification Center" style={{ position: 'absolute', right: 28, top: 205, width: 590, boxShadow: `0 20px 50px ${alpha(color.shadow, 12)}` }}><div style={{ padding: 24, fontSize: 25 }}>Zshell — {failed ? 'Command failed' : 'Command finished'}</div><div style={{ padding: '0 24px 24px', fontSize: 23, color: color.muted }}>{failed ? 'bun failed — exit 1' : 'bun finished — 32s, exit 0'}</div></Panel></>}</div>
    </div>
  </Shell>;
};

const ToolsBody = (props: DemoProps) => props.step === 0 ? <FindAndClear {...props} /> : props.step === 1 ? <ForegroundKeys {...props} /> : props.step === 2 ? <QuickModes {...props} /> : <Notifications {...props} />;

export const terminalToolsChapter: ChapterSpec = {
  id: 'terminal-tools', en: 'Everyday terminal controls', zh: '查找、快捷键、快速终端与通知',
  steps: [
    { en: 'Find output, clear the screen, manage history', zh: '定位输出、清屏与历史管理' },
    { en: 'Foreground shortcuts, terminal images and clipboard access', zh: '前台快捷键、终端图片与剪贴板授权' },
    { en: 'Quick Terminal: reuse or start fresh', zh: '快速终端：复用保留任务，隐藏新建工作区时结束任务' },
    { en: 'Command notifications and reported progress', zh: '命令完成通知与程序进度' },
  ],
  features: ['per-pane Find next previous and selection search', 'clear terminal buffer', 'delete command history record and clear history', 'Block Zshell Commands routes modified shortcuts to foreground app', 'terminal images', 'OSC 52 clipboard reads with explicit approval', 'Quick Terminal split pin resize opacity shortcut', 'reuse preserves hidden jobs and layout; fresh workspace terminates on hide', 'long-running and failed command notifications', 'terminal bell and OSC 777 notifications', 'OSC 9;4 normal paused error progress', 'notification history jumps to source pane'],
  sources: ['web/content/docs/terminal.mdx', 'mac/zshell/TerminalContextMenu.swift', 'mac/zshell/TerminalCommandHistoryController.swift', 'mac/zshell/GlobalTerminalOverlay.swift', 'mac/zshell/QuickTerminalWorkspaceView.swift', 'mac/zshell/TerminalNotificationService.swift', 'mac/zshell/Settings/SettingsTerminalPane.swift'],
  Body: ToolsBody,
};
