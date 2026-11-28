import { GlobeIcon, SearchIcon } from '../../components/Icons';
import { linear, ramp } from '../../lib/motion';
import { color } from '../../theme';
import {
  Action,
  Badge,
  Done,
  Group,
  Panel,
  Progress,
  Setting,
  Shell,
  Terminal,
  pressAt,
  revealAt,
  type ChapterSpec,
  type DemoProps,
} from './Frame';

const WebPreview = ({ query = '', result = false, remote = false, adBlocked = false }: { query?: string; result?: boolean; remote?: boolean; adBlocked?: boolean }) => (
  <div className="font-sans" style={{ height: '100%', padding: 20, boxSizing: 'border-box', backgroundColor: color.surface }}>
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
      <div style={{ width: 28, height: 28, borderRadius: 8, backgroundColor: color.blue, color: 'white', display: 'grid', placeItems: 'center', fontSize: 18, fontWeight: 750 }}>A</div>
      <span style={{ fontSize: 21, fontWeight: 650 }}>Atlas</span>
      {adBlocked ? <Badge tone="green" style={{ marginLeft: 'auto', fontSize: 14, padding: '3px 9px' }}>Ad hidden</Badge> : <span style={{ marginLeft: 'auto', color: color.muted, fontSize: 16 }}>Projects · Docs</span>}
    </div>
    <div style={{ fontSize: 28, letterSpacing: -0.8, fontWeight: 700, marginBottom: 6 }}>{result ? 'Workspace ready.' : 'Your next workspace.'}</div>
    <div style={{ fontSize: 18, color: color.muted, marginBottom: 14 }}>{remote ? 'Running on lab — SSH port forwarding' : 'Running on localhost:3000'}</div>
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 14px', borderRadius: 9, border: `1px solid ${query ? color.blue : color.lineStrong}`, fontSize: 19 }}>
      <SearchIcon size={19} color={color.muted} />
      <span style={{ color: query ? color.fg : color.faint }}>{query || 'Find a project'}</span>
      <span style={{ marginLeft: 'auto', fontSize: 17, color: color.blue }}>Search</span>
    </div>
    <div style={{ marginTop: 14, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
      {(result ? ['terminal-workspace', 'terminal-docs'] : ['Design system', 'API service']).map((name, index) => (
        <Panel key={name} style={{ padding: 14 }}>
          <div style={{ height: 6, width: 42, backgroundColor: index ? color.violet : color.blue, borderRadius: 8, marginBottom: 10 }} />
          <div style={{ fontSize: 18, fontWeight: 600, marginBottom: 4 }}>{name}</div>
          <div style={{ color: color.muted, fontSize: 16 }}>{result ? 'Matching project' : 'Updated just now'}</div>
        </Panel>
      ))}
    </div>
  </div>
);

const BrowserWorkspaceStep = ({ frame, fps }: DemoProps) => {
  const remote = frame >= 122;
  const imported = revealAt(frame, fps, 108);
  const blockOn = revealAt(frame, fps, 128, true);
  const rulesDone = revealAt(frame, fps, 166);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.12fr 0.88fr', gap: 24, height: '100%' }}>
      <Shell
        title={remote ? 'lab — SSH · Browser Pane' : 'atlas · Browser Pane'}
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Action style={{ padding: '6px 11px', fontSize: 15 }}>←</Action>
            <Action style={{ padding: '6px 11px', fontSize: 15 }}>→</Action>
            <Action press={pressAt(frame, 162)} style={{ padding: '6px 11px', fontSize: 15 }}>↻</Action>
            <div className="font-mono" style={{ flex: 1, minWidth: 0, border: `1px solid ${color.lineStrong}`, padding: '8px 12px', borderRadius: 8, fontSize: 17, display: 'flex', alignItems: 'center', gap: 8 }}>
              <GlobeIcon size={18} color={color.muted} />
              <span style={{ overflow: 'hidden', whiteSpace: 'nowrap', textOverflow: 'ellipsis' }}>http://localhost:3000</span>
            </div>
            <Action style={{ padding: '6px 11px', fontSize: 15 }}>Share</Action>
          </div>
        }
      >
        <div style={{ display: 'grid', gridTemplateRows: '0.44fr 0.56fr', height: '100%' }}>
          <div style={{ borderBottom: `1px solid ${color.line}` }}>
            <Terminal frame={frame} command="" fontSize={19} directory={remote ? 'lab:~/src/atlas' : '~/src/atlas'}>
              <div>› bun run dev <span style={{ color: color.green, marginLeft: 12 }}>VITE ready in 180 ms</span></div>
              <div style={{ marginTop: 10, display: 'flex', gap: 10, flexWrap: 'wrap' }}>
                <Badge tone={remote ? 'green' : 'blue'} style={{ fontSize: 15, padding: '4px 10px' }}>
                  {remote ? 'SSH port forwarding · separate remote storage' : 'New Browser Tab / Pane · address bar search'}
                </Badge>
              </div>
            </Terminal>
          </div>
          <WebPreview remote={remote} adBlocked={rulesDone > 0.5} />
        </div>
      </Shell>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 20, height: '100%' }}>
        <Shell title="Import Browser Data · Browser Data Access" style={{ flex: 1 }}>
          <div style={{ padding: 18 }}>
            <Setting label="Profile" value="Chrome — Default · Firefox" focus={imported < 0.5} />
            <Setting label="Items" value="Cookies · History · Open Tabs" />
            <div style={{ padding: '14px 16px 0', display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <Action active={imported < 0.5} press={pressAt(frame, 102)} style={{ padding: '6px 13px', fontSize: 16 }}>Import</Action>
              <Action style={{ padding: '6px 13px', fontSize: 16 }}>Browser Data Access</Action>
              <Done progress={imported} style={{ marginLeft: 'auto', fontSize: 15 }}>24 cookies · 86 history · 3 tabs</Done>
            </div>
          </div>
        </Shell>

        <Shell title="Manage Extensions & Content Blocking" style={{ flex: 1 }}>
          <div style={{ padding: 18 }}>
            <Group title="Settings · Browser" style={{ marginBottom: 10 }}>
              <Setting label="Workspace Lens (local ZIP)" value={<Badge tone="green" style={{ padding: '3px 9px', fontSize: 14 }}>Enabled · Options</Badge>} />
              <Setting label="EasyList & EasyPrivacy" checked={blockOn} focus={blockOn > 0.1 && blockOn < 0.95} />
            </Group>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              {rulesDone < 0.5 ? (
                <div style={{ flex: 1 }}>
                  <Progress value={ramp(frame, [128, 166])} label="Updating native content rules" style={{ padding: 0 }} />
                </div>
              ) : (
                <Done progress={rulesDone}>Content rules active · ads &amp; trackers blocked</Done>
              )}
            </div>
          </div>
        </Shell>
      </div>
    </div>
  );
};

const BrowserAgentStep = ({ frame, fps }: DemoProps) => {
  const phase = Math.min(3, Math.floor(frame / 56));
  const local = frame - phase * 56;
  const commands = [
    ['zshell +browser navigate http://localhost:3000 --wait', 'zshell +browser snapshot', '→ textbox #search · button #submit'],
    ["zshell +browser fill --selector '#search' --text 'terminal'", "zshell +browser click --selector '#submit'", '→ action completed · focus stays in terminal'],
    ['zshell +browser screenshot --output /tmp/page.png', '→ PNG viewport saved', "zshell +browser eval --script '({title: document.title})'", '→ { value: { title: "Atlas" } }'],
    ['zshell +browser state save --output /tmp/login.json', 'zshell +browser state load --input /tmp/login.json', 'zshell +browser reload --wait', '→ cookies & localStorage restored'],
  ][phase];
  const captured = revealAt(frame, fps, 122);
  const restored = revealAt(frame, fps, 184);

  return (
    <Shell title="atlas — Agent + Browser Automation">
      <div style={{ display: 'grid', gridTemplateColumns: '1.14fr 0.86fr', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}`, display: 'flex', flexDirection: 'column' }}>
          <div style={{ display: 'flex', gap: 10, padding: '14px 22px', borderBottom: `1px solid ${color.line}` }}>
            {['Inspect', 'Actions', 'Capture + JS', 'Saved Logins'].map((name, index) => (
              <Badge key={name} active={index === phase}>{name}</Badge>
            ))}
          </div>
          <div style={{ flex: 1, minHeight: 0 }}>
            <Terminal frame={frame} fontSize={21} command="">
              {commands.map((command, index) => (
                <div
                  key={`${phase}-${index}`}
                  style={{
                    marginBottom: 12,
                    overflowWrap: 'anywhere',
                    whiteSpace: 'pre-wrap',
                    color: command.startsWith('→') ? color.green : color.fg,
                    opacity: linear(local, [index * 7, index * 7 + 10]),
                  }}
                >
                  {command.startsWith('zshell') ? <span style={{ color: color.blue }}>› </span> : null}
                  {command}
                </div>
              ))}
              <div style={{ marginTop: 22, color: color.muted, fontSize: 18 }}>
                Project-scoped automation drives the existing browser session without stealing focus.
              </div>
            </Terminal>
          </div>
        </div>

        <div style={{ position: 'relative' }}>
          <div className="font-mono" style={{ padding: '14px 20px', borderBottom: `1px solid ${color.line}`, fontSize: 18, color: color.muted }}>
            http://localhost:3000
          </div>
          <div style={{ height: 'calc(100% - 52px)' }}>
            <WebPreview query={frame >= 66 ? 'terminal' : ''} result={frame >= 86} />
          </div>
          {phase === 2 ? (
            <div style={{ position: 'absolute', inset: '62px 14px 14px', border: `2px solid ${color.blue}`, borderRadius: 12, opacity: captured, pointerEvents: 'none' }}>
              <div style={{ position: 'absolute', bottom: 14, right: 14 }}><Done progress={captured}>Viewport captured</Done></div>
            </div>
          ) : null}
          {phase === 3 ? (
            <div style={{ position: 'absolute', bottom: 18, left: 20 }}>
              <Done progress={restored}>Session cookies &amp; storage restored</Done>
            </div>
          ) : null}
        </div>
      </div>
    </Shell>
  );
};

const BrowserBody = (props: DemoProps) =>
  props.step === 0 ? <BrowserWorkspaceStep {...props} /> : <BrowserAgentStep {...props} />;

export const browserChapter: ChapterSpec = {
  id: 'browser',
  en: 'Project browser',
  zh: '内置浏览器与网页自动化',
  nav: '内置浏览器',
  steps: [
    { en: 'Local & SSH preview, data import & extensions', zh: '本地与 SSH 预览、资料导入、本地扩展与拦截' },
    { en: 'Let your agent inspect, drive & test the page', zh: '智能体检查、操作、截图与恢复登录态' },
  ],
  features: [
    'Browser tab and split pane in the current project with address bar search, navigation, Share and Open in Default Browser',
    'Remote localhost preview through SSH port forwarding with separate remote website storage',
    'Chrome and Firefox Browser Data Access, Cookies/History/Open Tabs preview, Import and searchable Imported Browser History',
    'Compatible local WebExtension directory/ZIP installation (Manage Extensions), permission review, Enable/Disable/Options/Remove',
    'Native content blocking with EasyList, EasyPrivacy and custom ABP filter lists',
    '+browser navigate/snapshot/fill/click/screenshot/eval/state save & load on the existing session without moving terminal focus',
  ],
  sources: [
    'web/content/docs/browser.mdx',
    'mac/zshell/BrowserView.swift',
    'mac/zshell/BrowserRemoteRouting.swift',
    'mac/zshell/BrowserProfileImportController.swift',
    'mac/zshell/BrowserWebExtensionManager.swift',
    'mac/zshell/Settings/SettingsBrowserPane.swift',
    'mac/zshell/BrowserAutomation.swift',
  ],
  Body: BrowserBody,
};
