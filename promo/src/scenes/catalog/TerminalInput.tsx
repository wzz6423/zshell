import { Keycap } from '../../components/Hud';
import { BookmarkIcon, LockIcon, SearchIcon, ShieldIcon } from '../../components/Icons';
import { mix, ramp } from '../../lib/motion';
import { cursorOpacity, typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import {
  Action,
  Badge,
  Done,
  Group,
  ListRow,
  Overlay,
  Panel,
  Setting,
  Shell,
  Terminal,
  pressAt,
  revealAt,
  type ChapterSpec,
  type DemoProps,
} from './Frame';

const InputAndHintsStep = ({ frame, fps }: DemoProps) => {
  const completionMenu = revealAt(frame, fps, 42) * (1 - revealAt(frame, fps, 108));
  const accepted = frame >= 104;
  const hintsVisible = revealAt(frame, fps, 122);
  const copiedHint = revealAt(frame, fps, 166);
  const historyHighlight = revealAt(frame, fps, 146);
  const focusToggle = revealAt(frame, fps, 68, true);
  const wheelProgress = mix(0.35, 0.72, ramp(frame, [62, 118]));
  const typed = 'git ch'.slice(0, typedLength('git ch', frame, 8, 34));

  return (
    <Shell
      title="app — zsh"
      toolbar={
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <Badge active={!accepted}>Prompt edit &amp; zsh completion</Badge>
          <Badge active={hintsVisible > 0.3} tone="amber">Cmd+Shift+H · Keyboard Hints</Badge>
          <Badge active={historyHighlight > 0.3} tone="violet">Command History &amp; Cmd+Shift+F Logs</Badge>
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 10 }}>
            <Keycap size={15} pressed={pressAt(frame, 44)}>Tab</Keycap>
            <Keycap size={15} pressed={pressAt(frame, 102)}>Return</Keycap>
            <Keycap size={15} pressed={pressAt(frame, 158)}>s</Keycap>
          </span>
        </div>
      }
    >
      <div style={{ display: 'grid', gridTemplateColumns: '1.14fr 0.86fr', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}`, display: 'flex', flexDirection: 'column', position: 'relative' }}>
          <div className="font-mono" style={{ padding: '22px 26px', fontSize: 21, lineHeight: 1.72, flex: 1 }}>
            <div style={{ color: color.muted, fontSize: 18, marginBottom: 12 }}>~/src/app <span style={{ color: color.violet }}>main</span></div>
            <div>
              <span style={{ color: color.blue }}>› </span>
              {accepted ? 'git checkout feature/browser' : typed}
              {!accepted && completionMenu < 0.2 ? <span style={{ color: color.faint }}>eckout feature/browser</span> : null}
              <span style={{ display: 'inline-block', width: 3, height: 24, marginLeft: 2, verticalAlign: 'text-bottom', backgroundColor: color.blue, opacity: cursorOpacity(frame, frame < 34) }} />
            </div>

            <div style={{ marginTop: 22, paddingTop: 18, borderTop: `1px solid ${color.line}` }}>
              <div style={{ color: color.muted, fontSize: 18, marginBottom: 8 }}>› bun run dev</div>
              <div>
                Local: <span style={{ color: color.blue }}>http://localhost:3000</span>
                <Badge tone="amber" style={{ marginLeft: 10, padding: '2px 9px', fontSize: 15, opacity: hintsVisible, transform: `scale(${0.85 + hintsVisible * 0.15})` }}>a</Badge>
              </div>
              <div style={{ marginTop: 4 }}>
                <span style={{ backgroundColor: alpha(color.amber, 16 * copiedHint), borderRadius: 4, padding: '1px 4px' }}>src/main.ts:42:7</span>
                <Badge tone="amber" style={{ marginLeft: 10, padding: '2px 9px', fontSize: 15, opacity: hintsVisible, transform: `scale(${0.85 + hintsVisible * 0.15})` }}>s</Badge>
                <span style={{ marginLeft: 14, color: color.muted }}>7c48a91</span>
                <Badge tone="amber" style={{ marginLeft: 8, padding: '2px 9px', fontSize: 15, opacity: hintsVisible, transform: `scale(${0.85 + hintsVisible * 0.15})` }}>f</Badge>
              </div>
              <div style={{ marginTop: 12 }}>
                <Done progress={copiedHint}>Copied src/main.ts:42:7 · Cmd+Option+H opens</Done>
              </div>
            </div>
          </div>

          <Overlay progress={completionMenu} style={{ position: 'absolute', left: 26, top: 104, width: 380, zIndex: 3 }}>
            <Panel title="zsh completions · Return accepts without running" style={{ boxShadow: `0 18px 44px ${alpha(color.shadow, 18)}` }}>
              <ListRow active={frame >= 72}>feature/browser</ListRow>
              <ListRow active={frame < 72}>main</ListRow>
            </Panel>
          </Overlay>

          <Panel title="Command History · Cmd+Shift+F searches all panes" style={{ margin: '0 22px 20px' }}>
            <ListRow
              active={historyHighlight > 0.3}
              trailing={<Badge tone="green" style={{ fontSize: 15, padding: '4px 10px' }}>1.28 s · Exit 0</Badge>}
            >
              <span className="font-mono">pnpm test</span>
              <span style={{ color: color.muted, fontSize: 16 }}>~/src/app</span>
            </ListRow>
            <div style={{ padding: '8px 16px 14px', display: 'flex', gap: 10 }}>
              <Action active={historyHighlight > 0.4} style={{ padding: '6px 13px', fontSize: 16 }}>Show Output</Action>
              <Action style={{ padding: '6px 13px', fontSize: 16 }}>Insert into Terminal</Action>
              <Action style={{ padding: '6px 13px', fontSize: 16 }}>Copy Command</Action>
            </div>
          </Panel>
        </div>

        <div style={{ padding: 22, display: 'flex', flexDirection: 'column', gap: 16 }}>
          <Group title="Settings · Terminal · Input" style={{ marginBottom: 0 }}>
            <Setting label="Shell completions" checked={1} />
            <Setting label="Click & drag prompt edit" value="zsh · Claude Code" />
            <Setting label="Focus follows mouse" checked={focusToggle} focus={focusToggle > 0.1 && focusToggle < 0.95} />
            <Setting label="Option as Alt/Meta · Shift+Enter" checked={1} />
            <Setting label="Mouse wheel / Trackpad" progress={wheelProgress} value={`${Math.round(mix(100, 200, ramp(frame, [62, 118])))}%`} />
          </Group>
          <Group title="Info · VIM COMMANDS (mode-aware)" style={{ marginBottom: 0 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 16px', borderBottom: `1px solid ${color.line}`, fontSize: 17, color: color.muted }}>
              <SearchIcon size={17} /> Normal mode · Search Vim commands…
            </div>
            <ListRow style={{ padding: '8px 16px', fontSize: 17 }} trailing={<span style={{ color: color.muted, fontSize: 16 }}>Save file</span>}><span className="font-mono">:w</span></ListRow>
            <ListRow style={{ padding: '8px 16px', fontSize: 17 }} trailing={<span style={{ color: color.muted, fontSize: 16 }}>Quit editor</span>}><span className="font-mono">:q</span></ListRow>
            <ListRow style={{ padding: '8px 16px', fontSize: 17 }} trailing={<span style={{ color: color.muted, fontSize: 16 }}>Copy / paste line</span>}><span className="font-mono">yy · p</span></ListRow>
          </Group>
        </div>
      </div>
    </Shell>
  );
};

const BlocksAndSafetyStep = ({ frame, fps }: DemoProps) => {
  const menu = revealAt(frame, fps, 16) * (1 - revealAt(frame, fps, 88));
  const bookmarked = revealAt(frame, fps, 68);
  const readOnly = revealAt(frame, fps, 94);
  const redaction = revealAt(frame, fps, 104);
  const copyPress = pressAt(frame, 174);
  const copied = revealAt(frame, fps, 180);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.02fr 0.98fr', gap: 24, height: '100%' }}>
      <Shell
        title="app — zsh"
        titleTrailing={
          <Badge tone="amber" style={{ padding: '3px 9px', fontSize: 14, opacity: readOnly, transform: `scale(${0.9 + readOnly * 0.1})` }}>
            <LockIcon size={14} /> Read Only
          </Badge>
        }
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Badge active={readOnly > 0.4} tone="amber">
              <LockIcon size={15} /> {readOnly > 0.4 ? 'Pane locked · input blocked' : 'Unlocked'}
            </Badge>
            <Badge active={bookmarked > 0.4} tone="violet">
              <BookmarkIcon size={15} /> {bookmarked > 0.4 ? '1 Bookmark' : 'Bookmarks'}
            </Badge>
            <Badge active={false} style={{ marginLeft: 'auto' }}>Save Output (.txt)</Badge>
          </div>
        }
      >
        <div style={{ position: 'relative', height: '100%' }}>
          <Terminal frame={frame} fontSize={20} showPrompt={readOnly < 0.5} command="">
            <div style={{ color: color.muted }}>› bun test</div>
            <div style={{ color: color.green }}>37 pass · 0 fail</div>

            <div
              style={{
                marginTop: 18,
                padding: '12px 14px',
                borderRadius: 10,
                backgroundColor: alpha(color.blue, 8),
                border: `1px solid ${alpha(color.blue, 28)}`,
              }}
            >
              <div>› curl -H &quot;Authorization: Bearer eyJ…&quot; https://api.dev/me</div>
              <div style={{ color: color.muted, marginTop: 4 }}>HTTP/2 200 · token=ghp_9xK2mP7q…</div>
            </div>

            {readOnly > 0.3 ? (
              <div style={{ marginTop: 18, opacity: readOnly }}>
                <Badge tone="amber">Input, paste &amp; CLI blocked (terminal_read_only) · copy &amp; search stay live</Badge>
              </div>
            ) : null}

            <div style={{ marginTop: 18, fontSize: 16, color: color.muted }}>
              Multiline paste guard · Finder drops · Clipboard PNG &amp; SSH file uploads
            </div>
          </Terminal>

          <Overlay progress={menu} style={{ position: 'absolute', right: 20, top: 86, width: 320, zIndex: 4 }}>
            <Panel title="Command Block Menu" style={{ boxShadow: `0 22px 54px ${alpha(color.shadow, 22)}` }}>
              <ListRow style={{ padding: '8px 14px', fontSize: 17 }}>Copy Command · Copy Output</ListRow>
              <ListRow style={{ padding: '8px 14px', fontSize: 17 }}>Copy Command Block · Select Output</ListRow>
              <ListRow style={{ padding: '8px 14px', fontSize: 17 }}>Insert at Prompt</ListRow>
              <ListRow active={frame >= 44 && frame < 68} style={{ padding: '8px 14px', fontSize: 17 }} trailing={<BookmarkIcon size={16} />}>
                Bookmark Command
              </ListRow>
              <ListRow active={frame >= 68} style={{ padding: '8px 14px', fontSize: 17 }} trailing={<ShieldIcon size={16} />}>
                Copy Output with Redaction
              </ListRow>
              <ListRow style={{ padding: '8px 14px', fontSize: 17 }}>Read Only · Save Terminal Output…</ListRow>
            </Panel>
          </Overlay>
        </div>
      </Shell>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 20, height: '100%' }}>
        <Shell title="Terminal → Bookmarked Commands" style={{ height: 224, flexShrink: 0 }}>
          <div style={{ padding: 16 }}>
            <ListRow
              active={bookmarked > 0.3}
              trailing={
                <div style={{ display: 'flex', gap: 8 }}>
                  <Action active={bookmarked > 0.4} style={{ padding: '5px 12px', fontSize: 15 }}>Show Output</Action>
                  <Action style={{ padding: '5px 12px', fontSize: 15 }}>Remove</Action>
                </div>
              }
            >
              <BookmarkIcon size={18} color={color.violet} />
              <span className="font-mono" style={{ fontSize: 17 }}>curl … https://api.dev/me</span>
            </ListRow>
            <div style={{ padding: '8px 14px 0', fontSize: 16, color: color.muted }}>
              Session-scoped bookmarks stay attached across resizes, tab changes, Read Only &amp; Quick Terminal.
            </div>
          </div>
        </Shell>

        <Shell
          title="Share with Redaction — Preview"
          style={{
            flex: 1,
            opacity: mix(0.45, 1, redaction),
            transform: `translateY(${(1 - redaction) * 12}px)`,
          }}
        >
          <div style={{ padding: 20, display: 'flex', flexDirection: 'column', height: '100%', boxSizing: 'border-box' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
              <Badge tone="green"><ShieldIcon size={16} /> 2 suspected secrets redacted locally</Badge>
              <span style={{ marginLeft: 'auto', fontSize: 16, color: color.muted }}>Editable · up to 2 MiB</span>
            </div>
            <Panel style={{ flex: 1, backgroundColor: alpha(color.raised, 45) }}>
              <div className="font-mono" style={{ padding: 16, fontSize: 18, lineHeight: 1.75 }}>
                <div>
                  › curl -H &quot;Authorization: <span style={{ color: color.red, backgroundColor: alpha(color.red, 12), padding: '1px 6px', borderRadius: 5 }}>[REDACTED]</span>&quot; https://api.dev/me
                </div>
                <div style={{ marginTop: 6 }}>
                  HTTP/2 200 · token=<span style={{ color: color.red, backgroundColor: alpha(color.red, 12), padding: '1px 6px', borderRadius: 5 }}>[REDACTED]</span>
                </div>
              </div>
            </Panel>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 16, flexWrap: 'wrap' }}>
              <Action active press={copyPress} style={{ padding: '7px 14px', fontSize: 16 }}>Copy Preview</Action>
              <Action style={{ padding: '7px 14px', fontSize: 16 }}>Save Preview</Action>
              <Action style={{ padding: '7px 14px', fontSize: 16 }}>Include Original Secrets</Action>
              <Done progress={copied} style={{ marginLeft: 'auto', fontSize: 15 }}>Copied safely</Done>
            </div>
          </div>
        </Shell>
      </div>
    </div>
  );
};

const TerminalBody = (props: DemoProps) =>
  props.step === 0 ? <InputAndHintsStep {...props} /> : <BlocksAndSafetyStep {...props} />;

export const terminalChapter: ChapterSpec = {
  id: 'terminal-input',
  en: 'Terminal craft & safety',
  zh: '输入补全、书签与安全分享',
  nav: '终端体验',
  steps: [
    { en: 'Prompt editing, completions, hints & history', zh: '提示符编辑、zsh 补全、键盘提示与命令历史' },
    { en: 'Command blocks, bookmarks, Read-Only & redaction', zh: '命令块操作、会话书签、只读锁定与脱敏分享' },
  ],
  features: [
    'Click-to-position and drag-to-replace in zsh prompt and Claude Code input',
    'zsh inline suggestions, Tab candidate menu, Return acceptance without execution',
    'Mode-aware searchable Vim command hints in Info, Focus follows mouse, Option as Alt/Meta, Shift+Enter, independent mouse/trackpad scroll',
    'Command History search, duration/exit status, Show Output, Insert into Terminal and Cmd+Shift+F Search Terminal Logs',
    'Keyboard letter hints (Cmd+Shift+H copy / Cmd+Option+H open) for URLs, paths, IPs and commit hashes',
    'Command block context menu: Copy Command, Copy Output, Copy Command Block, Select Command Output, Insert at Prompt',
    'Session-scoped Command Bookmarks (Bookmark Command, Bookmarked Commands, Show Output, Remove/Clear)',
    'Per-pane Read Only lock blocking input, paste, drops, queues, browser access and automation (terminal_read_only)',
    'Save Terminal Output as UTF-8 text and Share with Redaction local preview ([REDACTED], Copy/Save Preview, Include Original Secrets)',
    'Multiline paste warning, Finder file drops, clipboard image PNG paste and remote SSH file/image uploads',
  ],
  sources: [
    'web/content/docs/terminal.mdx',
    'mac/zshell/TerminalAIInput.swift',
    'mac/zshell/TerminalShellCompletions.swift',
    'mac/zshell/VimCommandHints.swift',
    'mac/zshell/TerminalCommandHistoryController.swift',
    'mac/zshell/WorkspaceLogSearchController.swift',
    'mac/zshell/TerminalHintMenu.swift',
    'mac/zshell/TerminalContextMenu.swift',
    'mac/zshell/RemotePaste.swift',
  ],
  Body: TerminalBody,
};
