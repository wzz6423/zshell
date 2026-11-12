import { linear } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { color } from '../../theme';
import { Action, Badge, Code, Done, Group, ListRow, Panel, Progress, Setting, SettingsShell, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const PreferencesDemo = ({ step, frame }: DemoProps) => {
  const p = linear(frame, [45, 170]);
  const quickCommand = frame >= 132;
  const runQuickCommand = frame >= 202;
  if (step === 0) return (
    <SettingsShell category={frame < 110 ? 'General' : 'Shortcuts'}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 30 }}>
        <div><Group title="Search Settings…"><Setting label="Search" value={'cursor'.slice(0, typedLength('cursor', frame, 15, 55))} focus /><ListRow active>Cursor shape <Badge>Appearance</Badge></ListRow><ListRow>terminal.cursor-shape</ListRow></Group><Group title="Language"><Setting label="Language" value={frame < 80 ? 'English' : '简体中文'} /><div style={{ padding: 20, fontSize: 22, color: color.muted }}>English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Français · Deutsch · Español · Português · Italiano · Nederlands · Русский · العربية · ไทย · Bahasa Indonesia · Tiếng Việt · Türkçe</div></Group></div>
        <Group title="Shortcuts"><Setting label="Command Palette" value={frame >= 137 && frame < 158 ? 'Recording… Cmd+N' : frame >= 172 && frame < 215 ? 'Cmd+Shift+P' : 'Cmd+P'} focus={frame >= 137 && frame < 215} /><Setting label="New Project" value="Cmd+N" /><Setting label="New Session" value="Cmd+T" /><Setting label="Toggle Pane Zoom" value="Cmd+Shift+Return" /><Setting label="Next Agent Needing Attention" value="Cmd+Shift+A" />{frame >= 148 && frame < 172 ? <div style={{ padding: 16, color: color.red, fontSize: 21 }}>Already used by “New Project”</div> : null}<div style={{ padding: 20 }}><Action active={frame >= 200}>Restore Default Shortcuts</Action></div>{frame >= 215 ? <div style={{ padding: '0 20px 20px' }}><Done>Default bindings restored</Done></div> : null}</Group>
      </div>
    </SettingsShell>
  );
  if (step === 1) return (
    <SettingsShell category="General">
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 30 }}>
        <Group title="Application"><Setting label="Show Zshell in" value={frame < 55 ? 'Dock Only' : frame < 90 ? 'Menu Bar Only' : 'Dock and Menu Bar'} focus /><Setting label="Toolbar" value={frame < 60 ? 'Hide' : frame < 120 ? 'Auto' : 'Always Show'} /><Setting label="Keep computer awake" value={frame < 90 ? 'Off' : frame < 140 ? 'While Zshell runs' : 'While local agents work'} focus={frame >= 90} /><Setting label="Show pull request status" checked={frame < 175} /><Setting label="Use proxy for Git" checked={frame > 150} />{frame > 150 ? <Setting label="Proxy address" value="http://127.0.0.1:7897" /> : null}<Setting label="Double-click sidebar to create a session" checked={frame > 65} /></Group>
        <div><Panel title="Menu bar"><ListRow>Zshell</ListRow><ListRow active>Open Workspace</ListRow><ListRow>New Project</ListRow><ListRow>Quick Launch…</ListRow><ListRow>Settings…</ListRow></Panel><Panel title="Local agents" style={{ marginTop: 24 }}><ListRow>codex <Badge tone={frame > 140 ? 'amber' : 'green'}>{frame > 140 ? 'Working' : 'Done'}</Badge></ListRow><div style={{ padding: 20 }}>{frame > 140 ? <Done>Keeping the Mac awake</Done> : <Badge active={false}>Last window closed · tasks continue</Badge>}</div></Panel></div>
      </div>
    </SettingsShell>
  );
  if (step === 2) return (
    <Shell title={quickCommand ? 'Quick Commands — current terminal' : 'Terminal startup and portable settings'}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 0.9fr', gap: 26, padding: 30 }}>
        {quickCommand ? <Panel title="Manage Quick Commands…"><ListRow active>Check project</ListRow><ListRow>Build release</ListRow><Setting label="Name" value="Check project" /><Setting label="Command" value="bun test" /><div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', padding: 20 }}><Action>Add</Action><Action>Remove</Action><Action active={frame < 170}>Save</Action></div>{frame >= 162 ? <div style={{ padding: '0 20px 20px' }}><Done>Command saved</Done></div> : null}</Panel> : <Group title="Terminal — new sessions"><Setting label="New session directory" value={frame < 30 ? 'Current directory' : frame < 55 ? 'Project directory' : frame < 77 ? 'Home directory' : 'Custom · ~/src'} /><Setting label="Startup" value={frame < 75 ? 'Login shell' : 'Custom program'} /><Setting label="Program" value="/bin/zsh" /><Setting label="Arguments" value="-l" /><Setting label="Terminal type" value="xterm-256color" /></Group>}
        {quickCommand ? <Panel title="Check project → current pane"><div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: 18 }}><Action active={frame >= 170 && frame < 194}>Insert into Terminal</Action><Action active={frame >= 194 && frame < 208}>Run Command</Action></div><Terminal fontSize={22} frame={frame} command={frame >= 180 && !runQuickCommand ? 'bun test' : ''}>{runQuickCommand ? <><div>› bun test</div><div style={{ color: color.green }}>37 pass · 0 fail</div><div>Exit: 0</div></> : <div style={{ color: color.muted }}>~/src/app · original pane</div>}</Terminal></Panel> : <Group title="Terminal Environment…"><Setting label="Project" value="NODE_ENV=development" /><Setting label="Tab override" value={frame < 50 ? 'Inherit Project Command' : frame < 85 ? 'Replace Project Command' : 'Disable Project Command'} /><Setting label="Initialization" value="source .envrc" /><Setting label="New tab environment" value="NODE_ENV=test" /><Terminal fontSize={20} frame={frame} command="echo $NODE_ENV"><div style={{ color: color.green }}>{frame < 80 ? 'development' : 'test'}</div></Terminal></Group>}
        <Panel title="config.toml"><Code lines={['theme-light = "Catppuccin Latte"', 'terminal.cursor-shape = "bar"', 'terminal.cursor-blinking = true', 'terminal.restore-history = true']} style={{ fontSize: 19 }} /><div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: 20 }}><Action active={frame < 60}>Export Settings…</Action><Action active={frame >= 60 && frame < 110}>Import Settings…</Action><Action active={frame >= 110 && frame < 132}>Reset to Defaults</Action>{frame > 90 ? <Done>{frame >= 110 && frame < 132 ? 'Defaults applied' : 'Settings applied live'}</Done> : null}</div></Panel>
      </div>
    </Shell>
  );
  return (
    <SettingsShell category={frame < 120 ? 'Recommendations' : 'Updates'}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 30 }}>
        <Group title="Manage Tools"><div style={{ display: 'flex', gap: 14, padding: 18, flexWrap: 'wrap' }}><Action active={frame < 80}>Install Missing</Action><Action active={frame >= 80 && frame < 120}>Update All</Action><Action active={frame >= 120 && frame < 145}>Refresh</Action></div><ListRow>Homebrew <Done>Installed</Done></ListRow><ListRow>GitHub CLI <Badge tone={frame > 70 ? 'green' : 'blue'}>{frame > 70 ? 'Ready' : 'Install'}</Badge></ListRow><ListRow>Node.js <Badge tone={frame > 120 ? 'green' : 'blue'}>{frame > 120 ? 'Updated' : 'Update'}</Badge></ListRow><ListRow>Visual Studio Code <Badge active={false}>{frame > 145 ? 'Download page opened' : 'Download'}</Badge></ListRow><ListRow>Project links <Badge active={false}>Open</Badge></ListRow><Progress value={p} label="Checking installed tools" /></Group>
        <Group title="Updates"><Setting label="Automatically check for updates" checked /><Setting label="Automatically download updates" checked={frame > 100} /><Setting label="Automatically install updates" checked={frame > 145} /><div style={{ padding: 20 }}><Action active={frame >= 160}>Check for Updates…</Action></div><Progress value={linear(frame, [160, 205])} label="Checking latest release" />{frame > 205 ? <div style={{ padding: 20 }}><Done>You’re up to date</Done></div> : null}</Group>
      </div>
    </SettingsShell>
  );
};

export const preferencesChapter: ChapterSpec = {
  id: 'preferences', en: 'Preferences & tools', zh: '设置、快捷键与工具管理',
  steps: [
    { en: 'Find settings, change language and remap shortcuts', zh: '搜索设置、切换语言、自定义快捷键' },
    { en: 'Dock, menu bar, keep-awake and Git preferences', zh: 'Dock、菜单栏、保醒与 Git 选项' },
    { en: 'Startup environments, quick commands and configuration', zh: '启动环境、快捷命令与配置迁移' },
    { en: 'Recommended tools and controlled app updates', zh: '推荐工具与可控的应用更新' },
  ],
  features: ['settings search by label and TOML key', '17 languages', 'shortcut recording conflict and restore', 'application Dock and menu bar presence', 'toolbar visibility', 'keep awake while running or local agents work', 'Git proxy', 'PR status visibility', 'new session directory policies', 'login shell and custom startup argv', 'terminal type', 'project and tab environment inheritance', 'Quick Commands manage save insert and run in current pane', 'live TOML configuration', 'settings export import reset', 'recommended CLI and desktop tools', 'install missing update all and project links', 'automatic update check download install preferences', 'manual app update check'],
  sources: ['mac/zshell/Settings/SettingsSearch.swift', 'mac/zshell/Settings/SettingsGeneralPane.swift', 'mac/zshell/Settings/SettingsShortcutsPane.swift', 'mac/zshell/Settings/SettingsTerminalPane.swift', 'mac/zshell/Settings/SettingsRecommendationsPane.swift', 'mac/zshell/Settings/SettingsUpdatesPane.swift', 'mac/zshell/TerminalEnvironmentEditor.swift', 'mac/zshell/QuickCommands.swift'],
  Body: PreferencesDemo,
};
