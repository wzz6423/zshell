import { FolderIcon, TerminalIcon } from '../../components/Icons';
import { linear, mix } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import { Action, Badge, Code, Done, ListRow, Panel, Setting, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const Side = ({ frame, grouped = false }: { frame: number; grouped?: boolean }) => (
  <>
    <div style={{ fontSize: 17, color: color.muted, padding: 12 }}>{grouped ? 'Workspace' : 'Projects'}</div>
    <ListRow active trailing={<Badge>main</Badge>}><FolderIcon /> app</ListRow>
    <ListRow indent={18}><TerminalIcon /> zsh</ListRow>
    <ListRow><FolderIcon /> website</ListRow>
    {frame > 50 ? <ListRow active={frame > 140}><FolderIcon /> design-system</ListRow> : null}
    <ListRow><FolderIcon /> devbox (SSH)</ListRow>
    {grouped ? <><div style={{ marginTop: 16, padding: 12, fontSize: 19, color: color.violet }}>{frame >= 55 && frame < 85 ? '▸ Client work' : '▾ Client work'}</div>{frame < 55 || frame >= 85 ? <><ListRow indent={18}>api · pinned</ListRow><ListRow indent={18}>docs</ListRow></> : null}</> : null}
    <div style={{ marginTop: 24, padding: 12, color: color.muted, fontSize: 18 }}>New Group · New Project</div>
  </>
);

const ProjectDemo = ({ step, frame }: DemoProps) => {
  const p = linear(frame, [40, 130]);
  if (step === 0) return (
    <Shell title="Projects — local and SSH" sidebar={<Side frame={frame} />}>
      <div style={{ display: 'grid', gridTemplateColumns: '1.05fr 1fr', gap: 28, padding: 30, height: '100%' }}>
        <Panel title="New Zshell Project Here">
          <div style={{ padding: 24, display: 'flex', alignItems: 'center', gap: 16, fontSize: 26 }}><FolderIcon size={36} color={color.blue} /> design-system</div>
          <div style={{ padding: 24, backgroundColor: alpha(color.blue, 5), borderTop: `1px solid ${color.line}` }}><Action active={frame >= 55}>Open in Zshell</Action></div>
          <Terminal frame={frame} directory="~/src/design-system" command={'bun run dev'.slice(0, typedLength('bun run dev', frame, 80, 135))}><div style={{ color: color.green, marginTop: 14, opacity: linear(frame, [150, 175]) }}>VITE ready · localhost:3000</div></Terminal>
        </Panel>
        <Panel title="New SSH Project…">
          <Setting label="Host" value="devbox" /><Setting label="User" value="developer" /><Setting label="Port" value="22" /><Setting label="Directory" value="~/src/api" /><Setting label="Authentication" value="SSH Agent" />
          <div style={{ padding: 20, display: 'flex', gap: 16 }}><Action active={frame > 120}>Connect</Action>{frame > 170 ? <Done>Connected</Done> : null}</div>
          <div style={{ padding: '0 20px', color: color.muted, fontSize: 19 }}>SSH Agent · Password · Private Key File · Private Key Text</div>
          {frame > 185 ? <div style={{ padding: 20 }}><Badge>Saved connection · Edit / Delete</Badge></div> : null}
        </Panel>
      </div>
    </Shell>
  );
  if (step === 1) return (
    <Shell title="Grouped projects and sessions" sidebar={<Side frame={frame} grouped />} toolbar={<div style={{ display: 'flex', gap: 10 }}><Badge active={frame < 48}>build · pinned</Badge>{frame < 55 || frame >= 85 ? <Badge tone="violet">{frame > 24 ? 'review' : 'frontend'}</Badge> : null}<Badge active={false}>docs</Badge><Badge tone="violet">{frame >= 55 && frame < 85 ? '▸' : '▾'} Tab group</Badge><Badge active={frame >= 85 && frame < 115}>Tab Switcher · Ctrl+Tab</Badge></div>}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 0.8fr', gap: 30, padding: 30 }}>
        <div>{frame >= 105 && frame < 145 ? <Shell title="Window 2 — website"><Terminal frame={frame} command="git status"><Badge>review tab moved · same running shell</Badge><div style={{ color: color.green, marginTop: 20 }}>On branch main</div></Terminal></Shell> : <Terminal frame={frame} command={frame >= 199 ? 'echo $$' : 'git status'}><div style={{ color: color.green }}>On branch main</div><div>working tree clean</div>{frame >= 199 ? <><div style={{ marginTop: 24 }}>5186</div><Badge>Closed tab reopened as a new shell</Badge></> : frame >= 145 ? <div style={{ marginTop: 24 }}><Badge>{frame >= 178 ? 'Automatic title · automatic directory' : 'Project root pinned'}</Badge></div> : <div style={{ marginTop: 30 }}><Badge tone="violet">{frame >= 85 ? 'Groups reordered' : frame >= 55 ? 'Group collapsed' : frame >= 25 ? 'review · color marker applied' : 'frontend'}</Badge></div>}</Terminal>}</div>
        <Panel title={frame < 145 ? 'Session and group menus' : 'Project directory'}>
          {frame < 145 ? <><ListRow active={frame < 28}>Rename…</ListRow><ListRow active={frame >= 28 && frame < 48}>Set Color Marker… · Pin Tab</ListRow><ListRow active={frame >= 48 && frame < 85}>Move to Group · Collapse</ListRow><ListRow active={frame >= 85 && frame < 105}>Move Tab to Project…</ListRow><ListRow active={frame >= 105}>Move to New Window</ListRow><ListRow>Use Automatic Title</ListRow><ListRow>Plain Group · Folder Group…</ListRow><ListRow>Reorder · Remove Group</ListRow></> : <><Setting label="Current Directory" value="~/src/app/packages/ui" /><Setting label="Project Directory" value={frame >= 178 ? '~/src/app (AUTO)' : '~/src/app · pinned'} /><ListRow active={frame < 178}>Set Project Directory…</ListRow><ListRow active={frame >= 178 && frame < 199}>Use Automatic Directory</ListRow><ListRow active={frame >= 199}>Reopen Closed Session · Cmd+Shift+T</ListRow></>}
        </Panel>
      </div>
    </Shell>
  );
  if (step === 2) {
    const zoom = frame >= 168 && frame < 215;
    const reordered = frame >= 133;
    const equalized = frame >= 100;
    const narrow = frame < 34;
    return <Shell title="Split, focus, resize, and zoom" toolbar={<div style={{ display: 'flex', gap: 12 }}><Badge active={narrow}>Command Palette · Cmd+P</Badge><Badge active={!narrow && frame < 70}>Right / Down / Left / Up</Badge><Badge active={frame >= 70 && frame < 100}>Opt+Cmd+arrows</Badge><Badge active={frame >= 100 && frame < 133}>Equalize · Ctrl+Cmd+=</Badge><Badge active={frame >= 133 && frame < 168}>Drag pane / tab</Badge><Badge active={zoom}>Zoom</Badge></div>}>
      <div style={{ display: 'grid', gridTemplateColumns: zoom || narrow ? '1fr' : `${equalized ? 1 : mix(1, 1.5, p)}fr 1fr`, gap: 4, height: '100%', padding: 20 }}>
        <div style={{ border: `2px solid ${frame > 75 ? color.blue : color.line}`, borderRadius: 9, overflow: 'hidden' }}><Terminal frame={frame} command="bun run dev"><div style={{ color: color.green }}>Local: http://localhost:3000</div><div style={{ fontSize: 20, marginTop: 25, color: color.muted }}>{zoom ? 'Active pane zoomed' : 'Focus ring follows the selected pane'}</div></Terminal></div>
        {!zoom && !narrow ? <div style={{ display: 'grid', gridTemplateRows: frame < 56 ? '1fr' : '1fr 1fr', gap: 4 }}><Panel title={reordered ? 'logs · pane moved to top' : 'tests'}>{reordered ? <Code lines={['[server] ready', '[watch] source changed', '[build] complete']} /> : <Terminal fontSize={22} frame={frame} command="bun test"><div style={{ color: color.green }}>37 pass · 0 fail</div></Terminal>}</Panel>{frame >= 56 ? <Panel title={reordered ? 'tests · tab dropped into split' : 'logs'}>{reordered ? <Terminal fontSize={22} frame={frame} command="bun test"><div style={{ color: color.green }}>37 pass · 0 fail</div></Terminal> : <Code lines={['[server] ready', '[watch] source changed', '[build] complete']} />}</Panel> : null}</div> : null}
      </div>
      {narrow ? <Panel title="Commands" style={{ position: 'absolute', left: '25%', right: '25%', top: 110, boxShadow: `0 20px 60px ${alpha(color.shadow, 20)}` }}><div className="font-mono" style={{ padding: 20, fontSize: 25, borderBottom: `1px solid ${color.line}` }}>{'split'.slice(0, typedLength('split', frame, 4, 19)) || 'Search commands…'}</div><ListRow active trailing={<Badge>Cmd+D</Badge>}>Split Right</ListRow><ListRow trailing={<Badge>Cmd+Shift+D</Badge>}>Split Down</ListRow><ListRow>Split Left</ListRow><ListRow>Split Up</ListRow><div style={{ padding: 18, textAlign: 'right' }}><Action active={frame >= 24}>Return · Split Right</Action></div></Panel> : null}
    </Shell>;
  }
  return (
    <Shell title={frame < 120 ? 'Quick Launch' : 'Workspace Templates'}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 36, padding: 36 }}>
        <Panel title="Quick Launch · Cmd+O">
          <ListRow active>Frontend dev <Badge>bun run dev</Badge></ListRow><ListRow>SSH devbox <Badge active={false}>developer@devbox</Badge></ListRow><ListRow>Build release <Badge active={false}>make build</Badge></ListRow>
          <Setting label="Working directory" value="~/src/app" /><Setting label="Group" value="Daily work" />
          <div style={{ padding: 20, display: 'flex', gap: 14 }}><Action active={frame < 80}>Launch in new project</Action><Action>New / Edit / Delete</Action></div>
          {frame >= 65 ? <div style={{ padding: '0 20px 20px' }}><Done>Frontend dev · fresh project running</Done></div> : null}
        </Panel>
        <Panel title="Save Project as Template">
          <Setting label="Name" value="Frontend workspace" /><Setting label="Project Root" value="~/src/new-app" /><Setting label="Panes" value="dev · tests · browser" /><Setting label="Startup commands" value="bun run dev / bun test --watch" /><Setting label="Browser URL" value="http://localhost:3000" />
          <div style={{ padding: 20, display: 'flex', gap: 14 }}><Action active={frame >= 100 && frame < 155}>Apply Template</Action><Action active={frame >= 155 && frame < 200}>Edit / Import / Export</Action></div>
          {frame > 150 ? <div style={{ padding: '0 20px 24px' }}>{frame >= 200 ? <><Setting label="Remote Host" value="devbox · saved host" /><Setting label="Remote Directory" value="~/src/new-app" /><Done>Remote template · new shared project</Done></> : <Done>New tabs, panes and startup commands created</Done>}</div> : null}
        </Panel>
      </div>
    </Shell>
  );
};

export const projectsChapter: ChapterSpec = {
  id: 'projects', en: 'Projects & panes', zh: '项目、会话与分屏',
  steps: [
    { en: 'Local folders and saved SSH connections', zh: '从 Finder 开项目，保存 SSH 连接' },
    { en: 'Group, pin, rename and move your sessions', zh: '分组、固定、标色与跨窗口移动' },
    { en: 'Split, focus, resize and zoom', zh: '分屏、焦点、调整大小与放大' },
    { en: 'Launch entries and reusable workspace templates', zh: '快速启动与可复用工作区模板' },
  ],
  features: ['local projects', 'Finder Services', 'saved SSH authentication', 'plain and folder groups', 'group reorder and color', 'project pin and directory', 'session rename and automatic titles', 'tab groups and pin', 'tab switcher', 'move sessions across projects and windows', 'reopen closed session', 'command palette search and command execution', 'split both directions', 'pane focus ring and keyboard navigation', 'resize equalize and zoom', 'Quick Launch command and SSH entries', 'workspace template save edit apply import export'],
  sources: ['web/content/docs/projects.mdx', 'web/content/docs/panes.mdx', 'web/content/docs/quick-launch.mdx', 'mac/zshell/WorkspaceTemplateController.swift', 'mac/zshell/TerminalManager.swift', 'mac/zshell/CommandPaletteView.swift'],
  Body: ProjectDemo,
};
