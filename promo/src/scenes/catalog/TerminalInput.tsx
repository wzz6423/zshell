import { Keycap } from '../../components/Hud';
import { ArrowRightIcon, FolderIcon, GlobeIcon, SearchIcon } from '../../components/Icons';
import { linear } from '../../lib/motion';
import { cursorOpacity, typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import { Action, Badge, Code, Done, Group, ListRow, Panel, Setting, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const Caret = ({ frame }: { frame: number }) => <span style={{ display: 'inline-block', width: 3, height: 28, verticalAlign: 'text-bottom', backgroundColor: color.blue, opacity: cursorOpacity(frame, false) }} />;

const Pointer = ({ x, y, down = false }: { x: number; y: number; down?: boolean }) => (
  <svg width="36" height="46" viewBox="0 0 36 46" style={{ position: 'absolute', left: x, top: y, transform: `scale(${down ? 0.85 : 1})`, filter: 'drop-shadow(0 3px 3px #17204033)', pointerEvents: 'none' }}>
    <path d="M4 3v31l8-8 7 15 6-3-7-14h11z" fill="white" stroke={color.fg} strokeWidth="2" />
  </svg>
);

const InputDemo = ({ frame }: DemoProps) => {
  const editing = frame < 72;
  const completing = frame >= 72 && frame < 168;
  const selected = frame >= 28 && frame < 53;
  const replaced = frame >= 53;
  const dismissed = frame >= 95 && frame < 115;
  const menu = frame >= 115 && frame < 146;
  const accepted = frame >= 146;
  const inserted = frame >= 197;
  const focusMoved = frame >= 55;
  const metaMoved = frame >= 202;
  const scrollOffset = 45 * linear(frame, [77, 111]);
  return (
    <Shell title="app — zsh" toolbar={<div style={{ display: 'flex', alignItems: 'center', gap: 12 }}><Badge>{editing ? 'zsh' : completing ? 'Shell completions' : 'nvim'}</Badge><Keycap size={17} pressed={menu || dismissed ? 1 : 0}>{editing ? 'Drag' : completing ? dismissed ? 'Esc' : accepted ? 'Return' : 'Tab' : 'Shift + Enter'}</Keycap></div>}>
      <div style={{ height: '100%', display: 'grid', gridTemplateColumns: '1fr 540px' }}>
        <div style={{ minWidth: 0, position: 'relative', borderRight: `1px solid ${color.line}` }}>
          {editing ? <div className="font-mono" style={{ padding: 38, fontSize: 29, lineHeight: 1.8 }}>
            <div style={{ color: color.muted, fontSize: 22, marginBottom: 40 }}>~/src/app <span style={{ color: color.violet }}>main</span></div>
            <div><span style={{ color: color.blue }}>› </span>pnpm run <span style={{ position: 'relative', backgroundColor: selected ? alpha(color.blue, 25) : 'transparent' }}>{replaced ? 'test' : 'tests'}{replaced ? <Caret frame={frame} /> : null}</span> --watch</div>
            {!replaced ? <Pointer x={240 + 82 * linear(frame, [10, 42])} y={127} down={selected} /> : null}
            <div style={{ marginTop: 38, padding: 24, borderTop: `1px solid ${color.line}`, borderBottom: `1px solid ${color.line}`, opacity: linear(frame, [35, 47]) }}>
              <div style={{ fontSize: 20, color: color.muted, marginBottom: 12 }}>Claude Code</div>
              <div>› Update the <span style={{ backgroundColor: !replaced ? alpha(color.blue, 22) : 'transparent' }}>{replaced ? 'route tests' : 'old tests'}</span></div><div style={{ paddingLeft: 30 }}>and keep the current API.</div>
            </div>
          </div> : completing ? <div className="font-mono" style={{ padding: 28, fontSize: 24, lineHeight: 1.5 }}>
            <div style={{ marginBottom: 15, color: color.muted }}>~/src/app · main</div><div style={{ color: color.green }}>On branch main</div><div>working tree clean</div>
            <div style={{ marginTop: 22 }}>› {accepted ? 'git checkout feature/browser' : 'git ch'}{!menu && !accepted && !dismissed ? <span style={{ color: color.faint }}>eckout feature/browser</span> : null}<Caret frame={frame} /></div>
            {menu ? <Panel title="git checkout" style={{ marginTop: 16 }}><ListRow active={frame >= 129}>feature/browser</ListRow><ListRow active={frame < 129}>main</ListRow></Panel> : null}
          </div> : <div className="font-mono" style={{ padding: 26, fontSize: 23, lineHeight: 1.5 }}>
            <div style={{ color: color.muted, marginBottom: 12 }}>nvim src/main.ts</div>
            <Code lines={['export function openProject(path: string) {', '  return workspace.open(path);', '}']} style={{ padding: 0, fontSize: 21, lineHeight: 1.6 }} />
            <div style={{ padding: '8px 16px', marginTop: 14, color: color.green, backgroundColor: alpha(color.green, 8) }}>{inserted ? '-- INSERT --' : '-- NORMAL --'}</div>
            <Panel title="Claude Code" style={{ marginTop: 14 }}><div style={{ padding: 16 }}>› Keep the current API{inserted ? <div style={{ paddingLeft: 28 }}>and add one focused test.<Caret frame={frame} /></div> : <Caret frame={frame} />}</div></Panel>
          </div>}
          <Panel title="zsh — input" style={{ position: 'absolute', left: 28, right: 28, bottom: 20, height: frame >= 168 ? 128 : 150, boxShadow: focusMoved ? `inset 0 0 0 2px ${alpha(color.blue, 55)}` : undefined }}>
            {frame < 168 ? <div style={{ display: 'grid', gridTemplateColumns: '1fr 180px', gap: 20, padding: '12px 20px' }}><div className="font-mono" style={{ height: 70, overflow: 'hidden', fontSize: 20, lineHeight: 1.8 }}><div style={{ transform: `translateY(${-scrollOffset}px)` }}>{['✓ main.ts', '✓ routes.ts', '✓ workspace.ts', '✓ tests.ts', '›'].map((line) => <div key={line}>{line}{line === '›' && focusMoved ? <Caret frame={frame} /> : null}</div>)}</div></div><div style={{ position: 'relative' }}><Keycap size={16} pressed={focusMoved ? 1 : 0}>{frame >= 77 ? 'Mouse wheel' : 'Mouse'}</Keycap><Pointer x={0} y={18} down={frame >= 55 && frame < 77} /></div></div> : <div className="font-mono" style={{ padding: '16px 20px', fontSize: 24, display: 'flex', gap: 24, alignItems: 'center' }}><div>› pnpm {metaMoved ? <Caret frame={frame} /> : null}run {metaMoved ? null : <Caret frame={frame} />}dev</div><Keycap size={17} pressed={metaMoved ? 1 : 0}>Option + Left</Keycap></div>}
          </Panel>
        </div>
        <div style={{ padding: 24 }}>
          {frame < 168 ? <><Group title="Settings · Terminal · Input"><Setting label="Shell completions" checked={frame >= 72} focus={completing} /><Setting label="Copy on select" checked /><Setting label="Right-click action" value="Copy or Paste" /><Setting label="Focus follows mouse" checked={focusMoved} focus={frame >= 55 && frame < 77} /><Setting label="Use Option as Alt/Meta" checked /><Setting label="Shift+Enter inserts a newline" checked /></Group><Group title="Scrolling"><Setting label="Mouse wheel" value={frame >= 77 ? '200%' : '100%'} progress={frame >= 77 ? 0.7 : 0.35} focus={frame >= 77} /><Setting label="Trackpad" value={frame >= 111 ? '50%' : '100%'} progress={frame >= 111 ? 0.18 : 0.35} /></Group></> : <><Group title="Info · VIM COMMANDS"><div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 16, fontSize: 21 }}><SearchIcon size={21} />{frame >= 216 ? 'save' : 'Search Vim commands…'}</div>{(frame >= 216 ? [':w   Save file', ':wq  Save and quit'] : inserted ? ['Esc  Return to Normal', 'Ctrl + o  One Normal command', ':w   Save file'] : [':w   Save file', ':q   Quit', 'yy   Copy line', 'p    Paste after']).map((command) => <ListRow key={command}>{command}</ListRow>)}</Group><Group title="Settings · Terminal · Input"><Setting label="Vim command hints" checked /><Setting label="Use Option as Alt/Meta" checked focus={metaMoved} /><Setting label="Shift+Enter inserts a newline" checked focus={inserted} /></Group></>}

        </div>
      </div>
    </Shell>
  );
};

const HistoryDemo = ({ frame }: DemoProps) => {
  const revealed = frame >= 73 && frame < 143;
  const inserted = frame >= 143 && frame < 184;
  const searchAll = frame >= 184;
  const query = 'pnpm test'.slice(0, typedLength('pnpm test', frame, 10, 43));
  return (
    <Shell title="app — Command History">
      <div style={{ display: 'grid', gridTemplateColumns: '720px 1fr', height: '100%' }}>
        <div style={{ padding: 28, borderRight: `1px solid ${color.line}` }}>
          <Panel title={searchAll ? 'Search Terminal Logs' : 'Command History'}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, margin: 18, padding: 14, border: `1px solid ${color.lineStrong}`, borderRadius: 8, fontSize: 23 }}><SearchIcon size={23} />{searchAll ? '2 tests passed' : query || <span style={{ color: color.faint }}>Search commands or directories…</span>}</div>
            {searchAll ? <><ListRow active trailing={<Badge>app · test</Badge>}>2 tests passed</ListRow><ListRow trailing={<Badge>api · build</Badge>}>2 tests passed</ListRow><ListRow trailing={<Badge>docs · check</Badge>}>2 tests passed</ListRow></> : <><ListRow active>pnpm test <span style={{ color: color.muted, fontSize: 18 }}>— ~/src/app</span></ListRow><div style={{ padding: '0 18px 22px', fontSize: 19, color: color.muted }}>10:42 · Duration: 1.28 s · Exit: 0</div>{frame < 43 ? <><ListRow>pnpm run dev</ListRow><ListRow>git status</ListRow></> : <ListRow>pnpm test --filter api</ListRow>}</>}
            <div style={{ padding: 18, display: 'flex', gap: 12, flexWrap: 'wrap' }}><Action active={revealed}>{searchAll ? 'Show Pane' : 'Show Output'}</Action>{!searchAll ? <><Action active={inserted}>Insert into Terminal</Action><Action active={frame >= 51 && frame < 72}>Copy Command</Action></> : null}</div>
          </Panel>
          {!searchAll ? <Group title="Settings · Terminal · History" style={{ marginTop: 22 }}><Setting label="Record command history" checked /><Setting label="Restore session history on relaunch" checked /></Group> : <div style={{ marginTop: 24 }}><Keycap size={18} pressed={1}>Cmd + Shift + F</Keycap></div>}
        </div>
        <div style={{ position: 'relative' }}>
          <Terminal frame={frame} fontSize={27} command={inserted ? 'pnpm test' : ''}>
            <div style={{ color: color.muted }}>› pnpm test</div>
            <div style={{ marginTop: 16, padding: '14px 16px', borderRadius: 9, backgroundColor: revealed || searchAll ? alpha(color.blue, 10) : 'transparent', border: `1px solid ${revealed || searchAll ? alpha(color.blue, 28) : 'transparent'}` }}><div>PASS src/workspace.test.ts</div><div style={{ color: color.green }}>2 tests passed</div><div style={{ color: color.muted }}>Duration: 1.28 s</div></div>
            <div style={{ marginTop: 42, color: color.faint }}>› git status<br />On branch main<br />working tree clean</div>
            {inserted ? <div style={{ marginTop: 38 }}><Badge>Inserted into the original prompt</Badge></div> : null}
          </Terminal>
          {frame >= 51 && frame < 72 ? <div style={{ position: 'absolute', right: 28, bottom: 28 }}><Panel title="Clipboard"><Code lines={['pnpm test']} /></Panel></div> : null}
        </div>
      </div>
    </Shell>
  );
};

const HintDemo = ({ frame }: DemoProps) => {
  const copying = frame < 127;
  const selectedLabel = frame < 62 ? 's' : frame < 93 ? 'd' : frame < 127 ? 'f' : frame < 188 ? 'a' : 's';
  const letters = frame < 43 || frame >= 55 && frame < 73 || frame >= 87 && frame < 104 || frame >= 127 && frame < 153 || frame >= 184 && frame < 207;
  const browser = frame >= 153 && frame < 207;
  const finder = frame >= 207;
  const copies = [frame >= 43 ? 'src/main.ts:42:7' : '', frame >= 73 ? '192.168.1.12' : '', frame >= 104 ? '7c48a91' : ''].filter(Boolean);
  return (
    <Shell title="app — zsh" toolbar={<div style={{ display: 'flex', gap: 16, alignItems: 'center' }}><Action active={copying}>Copy Terminal Hint…</Action><Action active={!copying}>Open Terminal Hint…</Action><Keycap size={18} pressed={letters ? 1 : 0}>{copying ? 'Cmd + Shift + H' : 'Cmd + Option + H'}</Keycap></div>}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 640px', height: '100%' }}>
        <div className="font-mono" style={{ position: 'relative', padding: 30, fontSize: 24, lineHeight: 1.85, borderRight: `1px solid ${color.line}` }}>
          <div style={{ color: color.muted, fontSize: 21 }}>~/src/app</div><div>› pnpm run dev</div><div>Local: <span style={{ color: color.blue }}>http://localhost:3000</span>{letters ? <Badge tone="amber">a</Badge> : null}</div><div>src/main.ts:42:7{letters ? <Badge tone="amber">s</Badge> : null}</div><div>192.168.1.12{letters ? <Badge tone="amber">d</Badge> : null}</div><div>7c48a91{letters ? <Badge tone="amber">f</Badge> : null}</div>
          <div style={{ marginTop: 25 }}>› <Caret frame={frame} /></div>
          <div style={{ display: 'flex', gap: 12, marginTop: 24 }}><Keycap size={19} pressed={letters ? 1 : 0}>{selectedLabel}</Keycap><Keycap size={19} pressed={frame >= 120 && frame < 139 ? 1 : 0}>Tab</Keycap><Keycap size={19}>Esc</Keycap></div>
        </div>
        <div style={{ padding: 26 }}>
          {copying ? <><Panel title="Clipboard"><div className="font-mono" style={{ padding: 22, fontSize: 25, minHeight: 47 }}>{copies.at(-1) || ''}</div></Panel><Panel title="Copied values" style={{ marginTop: 18 }}>{copies.map((value) => <ListRow key={value} trailing={<Done>Copied</Done>}>{value}</ListRow>)}</Panel></> : null}
          {browser ? <Panel title="Default Browser" style={{ marginTop: 22 }}><div style={{ padding: 16, borderBottom: `1px solid ${color.line}`, fontSize: 22, display: 'flex', gap: 12 }}><GlobeIcon />http://localhost:3000</div><div style={{ padding: 24, fontSize: 33 }}>Workspace preview</div></Panel> : finder ? <Panel title="Finder — src" style={{ marginTop: 22 }}><ListRow active trailing={<Badge>Revealed</Badge>}><FolderIcon /> main.ts</ListRow><ListRow>workspace.ts</ListRow></Panel> : null}
          {frame >= 184 && frame < 207 ? <Panel title="Command-right-click · src/main.ts" style={{ marginTop: 22 }}><ListRow>New File Tab</ListRow><ListRow active>New File Pane</ListRow></Panel> : frame >= 127 && frame < 153 ? <Panel title="Command-right-click · localhost:3000" style={{ marginTop: 22 }}><ListRow>New Browser Tab</ListRow><ListRow active>New Browser Pane</ListRow></Panel> : null}
        </div>
      </div>
    </Shell>
  );
};

const PasteDemo = ({ frame }: DemoProps) => {
  const copied = frame >= 27 && frame < 75;
  const fileDrop = frame >= 75 && frame < 124;
  const imagePaste = frame >= 124 && frame < 173;
  const warning = frame >= 194 && frame < 224;
  const insertedPath = frame >= 224 ? '' : frame >= 97 && frame < 124 ? "'/Users/demo/Desktop/design notes.md'" : imagePaste ? "'/tmp/zshell-clipboard-a1b2c3/clipboard-72f3.png'" : frame >= 49 && frame < 75 ? '2 tests passed' : '';
  return (
    <Shell title="app — clipboard and file input">
      <div style={{ height: '100%', display: 'grid', gridTemplateColumns: '1fr 590px' }}>
        <div style={{ position: 'relative', borderRight: `1px solid ${color.line}` }}>
          <Terminal frame={frame} command={insertedPath} fontSize={23}>
            <div>Build complete in 1.28 s</div><div style={{ width: 'max-content', maxWidth: '100%', backgroundColor: copied ? alpha(color.blue, 22) : 'transparent' }}>2 tests passed</div>
            {frame >= 173 ? <><div style={{ marginTop: 22, color: color.muted }}>devbox · SSH</div><div style={{ display: 'flex', gap: 14, alignItems: 'center' }}><Action active={frame < 187}>Upload Files…</Action>{frame >= 187 ? <Done>design.png</Done> : null}</div>{frame >= 187 ? <div style={{ marginTop: 18, fontSize: 21 }}>› '/tmp/zshell-paste-18ab/design.png'</div> : null}</> : null}
            {frame >= 49 && frame < 75 ? <div style={{ marginTop: 22 }}><Keycap size={18} pressed={1}>Right-click</Keycap></div> : null}
          </Terminal>
          {fileDrop ? <div style={{ position: 'absolute', left: 210 + 260 * linear(frame, [76, 95]), top: 280, opacity: 1 - linear(frame, [94, 102]) }}><Panel><div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 20, fontSize: 23 }}><FolderIcon />design notes.md</div></Panel></div> : null}
          {warning ? <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: alpha(color.surface, 72) }}><Panel title="Warning: Potentially Unsafe Paste" style={{ width: 820 }}><div style={{ padding: 24, fontSize: 22, lineHeight: 1.5 }}>Pasting this text to the terminal may be dangerous because it looks like one or more commands may execute.</div><Code lines={['printf "preview only\\n"', 'printf "keep this as a draft\\n"']} /><div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12, padding: 22 }}><Action active={frame >= 220}>Cancel</Action><Action>Paste</Action></div></Panel></div> : null}
        </div>
        <div style={{ padding: 26 }}>
          <Group title="Settings · Terminal · Input"><Setting label="Copy on select" checked focus={copied} /><Setting label="Right-click action" value="Copy or Paste" /></Group>
          <Panel title={imagePaste ? 'Clipboard · Screenshot' : fileDrop ? 'Finder' : 'Clipboard'}><div style={{ padding: 24, fontSize: 23, minHeight: 110 }}>{imagePaste ? <div style={{ height: 90, display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: color.raised, border: `1px solid ${color.lineStrong}` }}>Workspace screenshot.png</div> : copied ? <span className="font-mono">2 tests passed</span> : fileDrop ? <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}><FolderIcon />design notes.md <ArrowRightIcon /></div> : null}</div></Panel>
          <Group title="Settings · Terminal · Remote files" style={{ marginTop: 24 }}><Setting label="Upload copied files and images" checked /><Setting label="Upload dropped files" checked /></Group>
          {imagePaste ? <div style={{ marginTop: 16 }}><Keycap size={18} pressed={1}>Cmd + V</Keycap></div> : null}
        </div>
      </div>
    </Shell>
  );
};

const TerminalBody = (props: DemoProps) => {
  if (props.step === 0) return <InputDemo {...props} />;
  if (props.step === 1) return <HistoryDemo {...props} />;
  if (props.step === 2) return <HintDemo {...props} />;
  return <PasteDemo {...props} />;
};

export const terminalChapter: ChapterSpec = {
  id: 'terminal-input', en: 'A terminal you can work with', zh: '输入、历史、提示，顺手完成',
  steps: [
    { en: 'Edit the prompt · accept a completion', zh: '点击与拖选编辑，补全命令' },
    { en: 'Find a command · return to its output', zh: '查命令历史，回到原输出' },
    { en: 'Choose a letter · copy or open', zh: '用字母选中路径和链接' },
    { en: 'Copy, drop, paste · keep control', zh: '复制、拖放与粘贴确认' },
  ],
  features: [
    'Click-to-position and drag-to-replace in the original zsh prompt and supported Claude Code input',
    'zsh inline suggestions, Tab candidates, arrows, Return acceptance without execution, Esc cancellation',
    'Vim and Neovim mode-aware searchable command hints in Info',
    'Option as Alt/Meta, Shift+Enter newline, right-click action, copy-on-select and focus-follows-mouse settings',
    'Persistent command history search by command and directory, duration and exit status, Show Output, Copy Command',
    'Insert into Terminal only at an empty original zsh prompt, without executing the command',
    'Search Terminal Logs across projects, tabs and panes in the current window',
    'Keyboard letter hints copy paths, URLs, IP addresses and commit hashes; Tab switches copy/open',
    'Command-right-click opens New Browser Tab/Pane or New File Tab/Pane; plain opening uses default browser/Finder',
    'Selection copying, quoted Finder file drops, clipboard screenshot as a private PNG path',
    'Remote copied file and image uploads, dropped file uploads and explicit Upload Files',
    'Multiline paste warning requires a user decision; the demo cancels and executes no pasted commands',
  ],
  sources: [
    'mac/zshell/TerminalAIInput.swift', 'mac/zshell/TerminalShellCompletions.swift',
    'mac/zshell/Settings/SettingsTerminalPane.swift', 'mac/zshell/VimCommandHints.swift',
    'mac/zshell/TerminalCommandHistoryController.swift', 'mac/zshell/TerminalCommandHistoryActions.swift',
    'mac/zshell/WorkspaceLogSearchController.swift', 'mac/zshell/TerminalHintMenu.swift',
    'mac/zshell/TerminalContextMenu.swift', 'mac/zshell/TerminalSession.swift',
    'mac/zshell/RemotePaste.swift', 'mac/zshell/LocalClipboardImageStore.swift',
  ],
  Body: TerminalBody,
};
