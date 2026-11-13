import { GlobeIcon, SearchIcon } from '../../components/Icons';
import { linear, ramp } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import { Action, Badge, Done, Group, ListRow, Panel, Progress, Setting, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const WebPreview = ({ query = '', result = false, remote = false }: { query?: string; result?: boolean; remote?: boolean }) => (
  <div className="font-sans" style={{ height: '100%', padding: 26, boxSizing: 'border-box', backgroundColor: color.surface }}>
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 22 }}>
      <div style={{ width: 34, height: 34, borderRadius: 9, backgroundColor: color.blue, color: 'white', display: 'grid', placeItems: 'center', fontSize: 23, fontWeight: 750 }}>A</div>
      <span style={{ fontSize: 25, fontWeight: 650 }}>Atlas</span>
      <span style={{ marginLeft: 'auto', color: color.muted, fontSize: 20 }}>Projects</span>
      <span style={{ color: color.muted, fontSize: 20 }}>Docs</span>
    </div>
    <div style={{ fontSize: 36, letterSpacing: -1, fontWeight: 700, marginBottom: 10 }}>{result ? 'Workspace ready.' : 'Your next workspace.'}</div>
    <div style={{ fontSize: 23, color: color.muted, marginBottom: 22 }}>{remote ? 'Running on lab — SSH' : 'Running on localhost:3000'}</div>
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '16px 18px', borderRadius: 10, border: `1px solid ${query ? color.blue : color.lineStrong}`, fontSize: 23 }}>
      <SearchIcon size={24} color={color.muted} />
      <span style={{ color: query ? color.fg : color.faint }}>{query || 'Find a project'}</span>
      <span style={{ marginLeft: 'auto', fontSize: 20, color: color.blue }}>Search</span>
    </div>
    <div style={{ marginTop: 20, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 18 }}>
      {(result ? ['terminal-workspace', 'terminal-docs'] : ['Design system', 'API service']).map((name, index) => (
        <Panel key={name} style={{ padding: 18 }}>
          <div style={{ height: 8, width: 54, backgroundColor: index ? color.violet : color.blue, borderRadius: 8, marginBottom: 16 }} />
          <div style={{ fontSize: 23, fontWeight: 600, marginBottom: 10 }}>{name}</div>
          <div style={{ color: color.muted, fontSize: 20 }}>{result ? 'Matching project' : 'Updated just now'}</div>
        </Panel>
      ))}
    </div>
  </div>
);

const BrowserWorkspace = ({ frame }: { frame: number }) => {
  const search = frame < 35;
  const remote = frame >= 180;
  const detail = frame >= 38 && frame < 75 || frame >= 107 && frame < 145;
  const address = search ? frame < 18 ? 'terminal workspace' : 'https://google.com/search?q=terminal+workspace' : remote ? 'http://localhost:3000' : detail ? 'http://localhost:3000/projects' : 'http://localhost:3000';
  const menu = frame >= 145 && frame < 180;
  return (
    <Shell title={remote ? 'lab — SSH · Browser Pane' : 'atlas · Browser Tab'} toolbar={
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <Action active={frame >= 64 && frame < 75} disabled={!detail}>← Back</Action>
        <Action active={frame >= 97 && frame < 107} disabled={frame < 75 || frame >= 107}>Forward →</Action>
        <Action active={frame >= 116 && frame < 137}>{frame < 28 ? '× Stop' : '↻ Reload'}</Action>
        <div className="font-mono" style={{ flex: 1, minWidth: 0, border: `1px solid ${color.lineStrong}`, padding: '12px 18px', borderRadius: 9, fontSize: 22, display: 'flex', gap: 12 }}>
          <GlobeIcon size={24} color={color.muted} /><span style={{ overflow: 'hidden', whiteSpace: 'nowrap', textOverflow: 'ellipsis' }}>{search && frame < 18 ? address.slice(0, typedLength(address, frame, 0, 16)) : address}</span>
        </div>
        <Action active={frame >= 132 && frame < 145}>Share</Action>
        <Action>↗</Action>
      </div>
    }>
      <div style={{ display: 'grid', gridTemplateColumns: '0.85fr 1.15fr', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}`, position: 'relative' }}>
          <div style={{ padding: '16px 24px', borderBottom: `1px solid ${color.line}`, fontSize: 21, color: color.muted }}>Terminal <span style={{ color: color.fg, marginLeft: 24 }}>{remote ? 'lab' : 'atlas'}</span></div>
          <Terminal frame={frame} command="" fontSize={25}>
            <div><span style={{ color: color.blue }}>› </span>bun run dev</div>
            <div style={{ marginTop: 26, color: color.green }}>VITE ready in 180 ms</div>
            <div style={{ marginTop: 16 }}><span style={{ color: color.muted }}>Local: </span>http://localhost:3000</div>
            <div style={{ marginTop: 54 }}><Badge tone={remote ? 'green' : 'blue'}>{remote ? 'SSH port forwarding connected' : 'Browser stays beside the terminal'}</Badge></div>
            <div style={{ marginTop: 24, fontSize: 23, color: color.muted }}>{remote ? '远端 localhost，直接在面板预览' : frame >= 168 && frame < 180 ? '已在默认浏览器打开链接' : search ? '地址栏也可以直接搜索' : frame >= 75 ? '返回页面，搜索内容与历史仍在' : '在同一项目打开本地开发网页'}</div>
          </Terminal>
          {menu ? <Panel style={{ position: 'absolute', right: 22, top: 108, width: 350, boxShadow: `0 18px 44px ${alpha(color.shadow, 15)}` }}>
            <ListRow>New Browser Tab</ListRow>
            <ListRow active>New Browser Pane</ListRow>
            <ListRow active={frame >= 164}>Open in Default Browser</ListRow>
          </Panel> : null}
        </div>
        <div style={{ position: 'relative' }}>
          <div style={{ display: 'flex', gap: 20, padding: '15px 24px', borderBottom: `1px solid ${color.line}`, fontSize: 21 }}>
            <span style={{ color: color.blue }}>{search ? 'Search' : 'Atlas'}</span><span style={{ color: color.muted }}>Docs</span>
            {remote ? <span style={{ marginLeft: 'auto', color: color.green }}>SSH · lab</span> : <span style={{ marginLeft: 'auto', color: color.muted }}>localhost:3000</span>}
          </div>
          {search ? <div style={{ padding: 32 }}><div style={{ fontSize: 35, fontWeight: 650, marginBottom: 28 }}>Search</div><Panel style={{ padding: 20, fontSize: 24, marginBottom: 26 }}>terminal workspace</Panel><div style={{ opacity: linear(frame, [16, 25]) }}><div style={{ fontSize: 26, color: color.blue, marginBottom: 12 }}>Zshell — Terminal workspace for macOS</div><div style={{ fontSize: 22, color: color.muted, marginBottom: 24 }}>zshell.sh</div><div style={{ fontSize: 23, lineHeight: 1.6 }}>Projects, terminal panes, files and diffs in one workspace.</div></div></div> : <WebPreview query={frame >= 75 && !detail ? 'terminal' : ''} result={detail} remote={remote} />}
          {frame >= 132 && frame < 145 ? <Panel style={{ position: 'absolute', right: 20, top: 8, width: 305, padding: 18 }}><ListRow>Copy Link</ListRow><ListRow>Messages</ListRow><ListRow>AirDrop</ListRow></Panel> : null}
        </div>
      </div>
    </Shell>
  );
};

const ImportBrowser = ({ frame }: { frame: number }) => {
  const access = frame < 26;
  const preview = frame >= 65;
  const importing = frame >= 115 && frame < 175;
  const done = frame >= 175;
  return (
    <Shell title="Browser Data Import" sidebar={<><ListRow active>Browser</ListRow><ListRow>Manage Extensions…</ListRow><ListRow active={access}>Browser Data Access…</ListRow><ListRow>Imported Browser History</ListRow></>}>
      <div style={{ padding: 30, display: 'grid', gridTemplateColumns: '1.15fr 0.85fr', gap: 26, height: '100%', boxSizing: 'border-box' }}>
        <div>
          <div style={{ fontSize: 27, fontWeight: 650, marginBottom: 24 }}>Import Browser Data…</div>
          <Panel>
            <Setting label="Browser profile" value={<span style={{ color: color.blue }}>{access ? 'Choose Browser Data Folder…' : 'Chrome — Default ▾'}</span>} focus />
            {frame >= 26 && frame < 45 ? <><ListRow active>Chrome — Default</ListRow><ListRow>Firefox — default-release</ListRow></> : null}
            <Setting label="Cookies" checked />
            <Setting label="History" checked />
            <Setting label="Open Tabs" checked />
          </Panel>
          <div style={{ display: 'flex', gap: 14, marginTop: 24 }}><Action active={!preview && !access} disabled={access}>Preview</Action><Action active={preview && !done} disabled={!preview}>{importing ? 'Importing…' : 'Import'}</Action><Action>Refresh</Action></div>
          {access ? <div style={{ display: 'flex', gap: 14, marginTop: 20 }}><Action active>Allow Access</Action><Action>System Settings…</Action></div> : null}
          <div style={{ marginTop: 24, minHeight: 54 }}>{done ? <Done>24 cookies · 86 history entries · 3 tabs</Done> : importing ? <Progress value={ramp(frame, [115, 175])} label="Importing browser data" /> : <div style={{ color: color.muted, fontSize: 22 }}>{preview ? '预览完成，导入到当前项目' : '选择浏览器资料，先查看预览'}</div>}</div>
        </div>
        <Panel title={done ? frame >= 215 ? 'Browser — zshell.sh/docs/browser' : 'Imported Browser History' : 'Import Preview'} style={{ alignSelf: 'start', marginTop: 59, opacity: linear(frame, [48, 65]) }}>
          <div style={{ padding: 20 }}>
            {done ? frame >= 215 ? <><div style={{ fontSize: 30, fontWeight: 650, marginBottom: 24 }}>Browser panes</div><div style={{ color: color.muted, fontSize: 23, lineHeight: 1.65 }}>Open websites beside a terminal, navigate with native controls, and keep links inside the project.</div><div style={{ marginTop: 26 }}><Done>History page opened</Done></div></> : <><div style={{ fontSize: 24, color: color.blue, marginBottom: 22 }}>Search imported history</div><Panel style={{ padding: '15px 18px', fontSize: 23, marginBottom: 22 }}><SearchIcon size={23} color={color.blue} /><span style={{ marginLeft: 12 }}>{'browser'.slice(0, typedLength('browser', frame, 179, 196))}</span></Panel><ListRow active={frame >= 203}>Zshell · Browser panes</ListRow><div style={{ fontSize: 21, color: color.muted, padding: '8px 16px' }}>https://zshell.sh/docs/browser</div><div style={{ marginTop: 16 }}><Action active={frame >= 203}>Open Page</Action></div></> : <>
            <div style={{ fontSize: 24, color: color.blue, marginBottom: 18 }}>Ready to import</div>
            <ListRow style={{ padding: '8px 12px' }} trailing={<Badge>24</Badge>}>Cookies · github.com</ListRow>
            <ListRow style={{ padding: '8px 12px' }} trailing={<Badge>86</Badge>}>History entries</ListRow>
            <ListRow style={{ padding: '8px 12px' }} trailing={<Badge>3</Badge>}>Open Tabs</ListRow>
            <div style={{ borderTop: `1px solid ${color.line}`, marginTop: 14, paddingTop: 14, fontSize: 22 }}>
              <div style={{ marginBottom: 10 }}>Zshell documentation</div>
              <div style={{ color: color.muted }}>Atlas workspace</div>
            </div>
            </>}
          </div>
        </Panel>
      </div>
    </Shell>
  );
};

const BrowserExtensions = ({ frame }: { frame: number }) => {
  const installed = frame >= 58;
  const removed = frame >= 225;
  const enabled = frame < 89 || frame >= 116;
  const options = frame >= 138 && frame < 186;
  return (
    <Shell title="Settings — Browser">
      <div style={{ padding: 30, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 30, height: '100%', boxSizing: 'border-box' }}>
        <Group title="Manage Extensions…">
          <Setting label="Workspace Lens" value={removed ? <Badge active={false}>Removed</Badge> : installed ? <Badge tone={enabled ? 'green' : 'amber'}>{enabled ? 'Enabled' : 'Disabled'}</Badge> : 'workspace-lens.zip'} />
          {!installed ? <div style={{ padding: 24 }}>
            {frame < 18 ? <div style={{ marginBottom: 20 }}><Action active>Install Extension…</Action></div> : null}
            <div style={{ fontSize: 25, marginBottom: 24 }}>Review requested permissions</div>
            <ListRow>activeTab</ListRow><ListRow>storage</ListRow><ListRow>https://docs.example.com/*</ListRow>
            <div style={{ marginTop: 24 }}><Action active={frame >= 38}>Install</Action></div>
          </div> : <div style={{ padding: 24 }}>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 14, marginBottom: 26 }}><Action>Permissions…</Action><Action active={frame >= 70 && frame < 125} disabled={removed}>{enabled ? 'Disable Extension' : 'Enable Extension'}</Action><Action active={frame >= 207 && frame < 225} disabled={removed}>Remove</Action></div>
            {removed ? <Done>Extension removed</Done> : frame >= 196 ? <Panel style={{ padding: 22 }}><div style={{ fontSize: 25, fontWeight: 600, marginBottom: 18 }}>Workspace Lens</div><div style={{ color: color.muted, fontSize: 22, marginBottom: 22 }}>Installed locally · enabled</div><Action active={frame >= 207}>Remove</Action></Panel> : <>
            <div style={{ fontSize: 22, color: color.muted, marginBottom: 18 }}>Page → Extensions → {options ? 'Options' : 'Workspace Lens'}</div>
            <Panel style={{ padding: 22, opacity: linear(frame, [120, 138]) }}><div style={{ fontSize: 23, fontWeight: 600, marginBottom: 12 }}>{options ? 'Workspace Lens — Options' : 'Workspace Lens'}</div>{options ? <><Setting label="Show project title" checked={frame >= 158} /><div style={{ marginTop: 18 }}><Done>Option saved</Done></div></> : <div style={{ color: color.muted, fontSize: 22 }}>Page title: Atlas</div>}</Panel>
            </>}
          </div>}
        </Group>
        <div>
          <Group title="Block ads and trackers">
            <Setting label="Block ads and trackers" checked={frame >= 15} />
            <Setting label="EasyList" checked={frame >= 31} />
            <Setting label="EasyPrivacy" checked={frame >= 47} />
            <Setting label="Custom filter lists" value="https://example.com/filters.txt" />
          </Group>
          <div style={{ display: 'flex', gap: 16 }}><Action active={frame >= 47 && frame < 65}>Apply Lists</Action><Action active={frame >= 65 && frame < 122}>Update Lists Now</Action></div>
          <div style={{ marginTop: 18 }}>{frame >= 122 ? <Done>Rules updated</Done> : <Progress value={ramp(frame, [65, 122])} label="Updating content rules" />}</div>
          <Panel style={{ marginTop: 18, padding: 18 }}><div style={{ display: 'flex', alignItems: 'center', gap: 18 }}><span style={{ fontSize: 23 }}>Atlas · News</span><span style={{ marginLeft: 'auto' }}><Action active={frame >= 154 && frame < 179}>↻ Reload</Action></span></div><div style={{ display: 'flex', alignItems: 'center', gap: 18, marginTop: 20 }}><div style={{ flex: 1, fontSize: 22 }}>Latest workspace updates</div>{frame < 179 ? <div style={{ padding: '14px 20px', backgroundColor: alpha(color.amber, 12), color: color.amber, fontSize: 23 }}>Advertisement</div> : <Badge tone="green">Ad hidden</Badge>}</div></Panel>
        </div>
      </div>
    </Shell>
  );
};

const BrowserAgent = ({ frame }: { frame: number }) => {
  const phase = Math.min(3, Math.floor(frame / 60));
  const commands = [
    ['zshell +browser navigate http://localhost:3000 --wait', 'zshell +browser snapshot', '→ textbox #search', '→ button #submit'],
    ["zshell +browser fill --selector '#search' --text 'terminal'", "zshell +browser click --selector '#submit'", '→ action completed'],
    ['zshell +browser screenshot --output /tmp/page.png', '→ PNG viewport saved', "zshell +browser eval --script '({title: document.title})'", '→ { value: { title: "Atlas" } }'],
    ['zshell +browser state save --output /tmp/login.json', 'zshell +browser state load --input /tmp/login.json', 'zshell +browser reload --wait', '→ cookies and localStorage restored'],
  ][phase];
  return (
    <Shell title="atlas — Agent + Browser">
      <div style={{ display: 'grid', gridTemplateColumns: '1.13fr 0.87fr', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}` }}>
          <div style={{ display: 'flex', gap: 13, padding: '17px 24px', borderBottom: `1px solid ${color.line}` }}>{['Inspect', 'Actions', 'Capture + JS', 'Saved logins'].map((name, index) => <Badge key={name} active={index === phase}>{name}</Badge>)}</div>
          <Terminal frame={frame} fontSize={23} command="">
            {commands.map((command, index) => <div key={`${phase}-${index}`} style={{ marginBottom: 14, overflowWrap: 'anywhere', whiteSpace: 'pre-wrap', color: command.startsWith('→') ? color.green : color.fg, opacity: linear(frame % 60 + 8, [index * 7, index * 7 + 8]) }}>{command.startsWith('zshell') ? <span style={{ color: color.blue }}>› </span> : null}{command}</div>)}
            <div style={{ marginTop: 32, color: color.muted, fontSize: 23 }}>Agent 操作现有会话，焦点保持在终端</div>
          </Terminal>
        </div>
        <div style={{ position: 'relative' }}>
          <div className="font-mono" style={{ padding: '17px 24px', borderBottom: `1px solid ${color.line}`, fontSize: 22 }}>http://localhost:3000</div>
          <WebPreview query={frame >= 78 ? 'terminal' : ''} result={frame >= 101} />
          {phase === 2 ? <div style={{ position: 'absolute', inset: '64px 16px 16px', border: `2px solid ${color.blue}`, borderRadius: 12, opacity: linear(frame, [120, 137]), pointerEvents: 'none' }}><div style={{ position: 'absolute', bottom: 16, right: 18 }}><Done>Viewport captured</Done></div></div> : null}
          {phase === 3 && frame >= 214 ? <div style={{ position: 'absolute', bottom: 22, left: 26 }}><Done>Session restored</Done></div> : null}
        </div>
      </div>
    </Shell>
  );
};

const BrowserBody = ({ step, frame, fps }: DemoProps) => {
  const tick = frame * 60 / fps;
  return <div style={{ height: '100%', padding: 24, boxSizing: 'border-box' }}>{step === 0 ? <BrowserWorkspace frame={tick} /> : step === 1 ? <ImportBrowser frame={tick} /> : step === 2 ? <BrowserExtensions frame={tick} /> : <BrowserAgent frame={tick} />}</div>;
};

export const browserChapter: ChapterSpec = {
  id: 'browser', en: 'A browser in your workspace.', zh: '网页和终端，在同一个项目',
  steps: [
    { en: 'Preview beside your terminal', zh: '本地与 SSH 网页，直接预览' },
    { en: 'Bring your browser session', zh: '预览并导入浏览器资料' },
    { en: 'Extensions and content blocking', zh: '本地扩展、广告与跟踪控制' },
    { en: 'Let your agent test the page', zh: '检查、操作、截图与恢复登录' },
  ],
  features: [
    'Browser tab and split pane in the current project; localhost development preview',
    'Address field accepts URLs, hostnames, local hosts and search terms',
    'Back, Forward, Stop/Reload, Share and Open in Default Browser',
    'New Browser Tab / New Browser Pane; page-link New Tab / New Pane',
    'Tab/project switching keeps navigation history, scroll position, form and page state; relaunch restores current URL and layout',
    'Remote localhost through SSH port forwarding with separate remote-project website storage',
    'Chrome / Firefox profile discovery; Cookies / History / Open Tabs selection; Preview then Import',
    'Browser Data Access, Allow Access / System Settings / Refresh; disabled preview before a profile is available',
    'Imported history search; counts and examples without exposing cookie values; current-project import destination',
    'Imported history query filters results and opens a selected page in the project browser',
    'Compatible local WebExtension directory / ZIP installation; requested API / website permissions',
    'Installed-extension permission review, Enable / Disable / Remove; page Extensions actions and options',
    'Native content blocking; independent EasyList / EasyPrivacy; custom ABP lists; Apply Lists / Update Lists Now / Reload',
    'Extension Options page setting result and removal; page reload reflects refreshed ad-hiding rules',
    '+browser existing-session snapshot, click, fill, wait and PNG viewport capture without moving terminal focus',
    '+browser navigate / back / forward / reload / stop; project-and-window scoped commands',
    '+browser eval main-frame JavaScript and JSON return values',
    '+browser state save / load for cookies and matching-origin localStorage; reload after import',
  ],
  sources: [
    'web/content/docs/browser.mdx', 'mac/zshell/BrowserView.swift', 'mac/zshell/BrowserRemoteRouting.swift',
    'mac/zshell/BrowserProfileImportController.swift', 'mac/zshell/BrowserImportedHistory.swift', 'mac/zshell/BrowserWebExtensionManager.swift',
    'mac/zshell/Settings/SettingsBrowserPane.swift', 'mac/zshell/ZshellBrowserAutomationCommandLine.swift', 'mac/zshell/BrowserAutomation.swift',
  ],
  Body: BrowserBody,
};
