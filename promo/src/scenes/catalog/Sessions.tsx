import type { CSSProperties } from 'react';
import { Img } from 'remotion';
import icon from '../../../../web/public/zshell-icon.png';
import { Keycap } from '../../components/Hud';
import { BellIcon } from '../../components/Icons';
import { ramp } from '../../lib/motion';
import { alpha, color } from '../../theme';
import {
  Action,
  Badge,
  Code,
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

const profilePalette: CSSProperties = {
  '--color-surface': '#eff1f5',
  '--color-raised': '#e6e9ef',
  '--color-fg': '#4c4f69',
  '--color-muted': '#6c6f85',
  '--color-faint': '#9ca0b0',
  '--color-blue': '#8839ef',
  '--color-line': '#ccd0da',
  '--color-line-strong': '#acb0be',
} as CSSProperties;

const PersistenceAndProfilesStep = ({ frame, fps }: DemoProps) => {
  const persistOn = revealAt(frame, fps, 24, true);
  const reconnected = revealAt(frame, fps, 76);
  const profileMatched = revealAt(frame, fps, 108);
  const killPress = pressAt(frame, 152);
  const portKilled = revealAt(frame, fps, 158);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 24, height: '100%' }}>
      <Shell title="Session Persistence & Info · Cmd+Shift+I">
        <div style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 14, height: '100%', boxSizing: 'border-box' }}>
          <Group title="Settings · Terminal · Sessions & History" style={{ marginBottom: 0 }}>
            <Setting label="Keep sessions running after quitting" checked={persistOn} focus={persistOn > 0.1 && persistOn < 0.95} />
            <Setting label="Restore session history on relaunch" checked={1} />
            <div style={{ padding: '10px 16px', display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <Badge active={false} style={{ fontSize: 14, padding: '4px 9px' }}>Quit vs Quit &amp; End All</Badge>
              <Done progress={reconnected} style={{ fontSize: 15 }}>Reconnected · live pid 3421</Done>
            </div>
          </Group>

          <Group title="Info · Processes & Listening Ports" style={{ marginBottom: 0, flex: 1 }}>
            <Setting label="CURRENT / PROJECT DIR" value="~/src/app/api → ~/src/app (AUTO)" />
            <ListRow style={{ padding: '8px 16px', fontSize: 17 }} trailing={<span style={{ color: color.muted, fontSize: 16 }}>0% · 12 MiB</span>}>
              <span className="font-mono">zsh  3418</span>
            </ListRow>
            <ListRow
              active={portKilled < 0.5}
              style={{ padding: '8px 16px', fontSize: 17 }}
              trailing={
                portKilled > 0.5 ? (
                  <Done progress={portKilled} style={{ fontSize: 14, padding: '3px 9px' }}>Terminated</Done>
                ) : (
                  <Action active press={killPress} tone="red" style={{ fontSize: 14, padding: '4px 10px' }}>Kill Process (node)</Action>
                )
              }
            >
              <span className="font-mono">3000 · node 3421</span>
              <span style={{ color: color.muted, fontSize: 15 }}>18% · 84 MiB</span>
            </ListRow>
            <div style={{ padding: '6px 16px 10px', fontSize: 15, color: color.muted }}>
              Open in Browser · Copy URL · Terminate / Force Kill · Copy PID
            </div>
          </Group>
        </div>
      </Shell>

      <Shell
        title="Terminal Profiles — Automatic Matching"
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Badge tone={profileMatched > 0.5 ? 'violet' : 'blue'}>
              {profileMatched > 0.5 ? 'Profile: Review (matched)' : 'Original Settings'}
            </Badge>
            <span style={{ marginLeft: 'auto', fontSize: 16, color: color.muted }}>Live appearance · env for new panes</span>
          </div>
        }
      >
        <div style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 16, height: '100%', boxSizing: 'border-box' }}>
          <Group title="Match conditions · wildcards * ?" style={{ marginBottom: 0 }}>
            <Setting label="Host / User" value="localhost · demo" />
            <Setting label="Directory / Program" value="*/src/app* · zsh" focus={profileMatched > 0.3} />
            <Setting label="New terminal env" value="PROJECT_MODE=review" />
          </Group>

          <Panel
            title={profileMatched > 0.5 ? 'app — Review theme · Block cursor' : 'app — Original theme · Bar cursor'}
            style={{
              flex: 1,
              ...(profileMatched > 0.5 ? profilePalette : {}),
              borderColor: profileMatched > 0.5 ? alpha(color.violet, 45) : color.line,
            }}
          >
            <Terminal
              frame={frame}
              fontSize={21}
              shape={profileMatched > 0.5 ? 'block' : 'bar'}
              command="echo $PROJECT_MODE"
              after={
                <div style={{ marginTop: 10, display: 'flex', alignItems: 'center', gap: 12 }}>
                  <span style={{ color: color.green }}>{profileMatched > 0.5 ? 'review (new pane)' : 'unset'}</span>
                  <Done progress={profileMatched} style={{ fontSize: 14 }}>Switched live · pid 3418 kept</Done>
                </div>
              }
            />
          </Panel>
        </div>
      </Shell>
    </div>
  );
};

const AlertsAndForegroundStep = ({ frame, fps }: DemoProps) => {
  const armed = revealAt(frame, fps, 24);
  const progress = ramp(frame, [36, 128]);
  const finished = revealAt(frame, fps, 132);
  const blockedKeys = revealAt(frame, fps, 60, true);
  const osc52 = revealAt(frame, fps, 126) * (1 - revealAt(frame, fps, 188));
  const allowClipPress = pressAt(frame, 174);
  const clipAllowed = revealAt(frame, fps, 182);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.05fr 0.95fr', gap: 24, height: '100%' }}>
      <Shell
        title="app — Next-Command Alert & Notifications"
        titleTrailing={
          <Badge
            tone={finished > 0.5 ? 'green' : 'blue'}
            style={{ padding: '3px 9px', fontSize: 14, opacity: armed, transform: `scale(${0.9 + armed * 0.1})` }}
          >
            <BellIcon size={14} /> {finished > 0.5 ? 'Notified' : 'Armed'}
          </Badge>
        }
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Action active={armed > 0.4 && finished < 0.5} press={pressAt(frame, 20)} style={{ padding: '6px 12px', fontSize: 15 }}>
              <BellIcon size={15} /> {armed > 0.4 && finished < 0.5 ? 'Cancel Next Command Notification' : 'Notify When Next Command Finishes'}
            </Action>
          </div>
        }
      >
        <div style={{ position: 'relative', display: 'flex', flexDirection: 'column', height: '100%' }}>
          {/* Slim OSC 9;4 progress bar directly above the terminal */}
          <div style={{ height: 5, backgroundColor: alpha(color.fg, 8), flexShrink: 0 }}>
            <div style={{ height: '100%', width: `${progress * 100}%`, backgroundColor: finished > 0.5 ? color.green : color.blue }} />
          </div>

          <div style={{ flex: 1, minHeight: 0 }}>
            <Terminal frame={frame} fontSize={20} command="">
              <div>› bun run build</div>
              <div style={{ marginTop: 10, color: finished > 0.5 ? color.green : color.muted }}>
                {finished > 0.5 ? 'Build complete · 32s · Exit 0' : `Compiling modules… ${Math.round(progress * 100)}% (OSC 9;4)`}
              </div>
              <div style={{ marginTop: 18, fontSize: 16, color: color.muted }}>
                One-time local zsh reminder works even when automatic alerts are off.
              </div>
            </Terminal>
          </div>

          <Panel title="Notification History · All / Unread / Failed / Pending" style={{ margin: '0 18px 18px' }}>
            <ListRow active={finished > 0.5} style={{ padding: '9px 14px', fontSize: 17 }} trailing={<Action active={finished > 0.5} style={{ padding: '4px 10px', fontSize: 14 }}>Show Pane</Action>}>
              app · bun run build · 32s · Exit 0
            </ListRow>
            <div style={{ padding: '2px 14px 10px', fontSize: 15, color: color.muted }}>
              Long-running (5/10/30/60s) · Failed commands · Bell · OSC 777
            </div>
          </Panel>

          <Overlay progress={finished} style={{ position: 'absolute', right: 18, top: 22, width: 390, zIndex: 4 }}>
            <Panel title="macOS Notification Center" style={{ boxShadow: `0 20px 48px ${alpha(color.shadow, 18)}` }}>
              <div style={{ padding: '12px 16px' }}>
                <div style={{ fontSize: 18, fontWeight: 600 }}>Zshell — Command finished</div>
                <div style={{ fontSize: 16, color: color.muted, marginTop: 4 }}>bun finished — 32s, exit 0 · click to jump</div>
              </div>
            </Panel>
          </Overlay>
        </div>
      </Shell>

      <Shell
        title="Foreground Keys, Images & Clipboard"
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Badge active={blockedKeys > 0.5}>Block Zshell Commands</Badge>
            <Keycap size={15} pressed={pressAt(frame, 88)}>Ctrl + Return</Keycap>
            <span style={{ marginLeft: 'auto', fontSize: 15, color: color.muted }}>Per-pane shortcut routing</span>
          </div>
        }
      >
        <div style={{ position: 'relative', padding: 20, display: 'flex', flexDirection: 'column', gap: 14, height: '100%', boxSizing: 'border-box' }}>
          <Setting label="Block Zshell Commands (pane)" checked={blockedKeys} focus={blockedKeys > 0.1 && blockedKeys < 0.95} />

          <Panel title="Inline terminal image rendering (both backends)">
            <div style={{ display: 'flex', alignItems: 'center', gap: 20, padding: 18 }}>
              <Img src={icon} style={{ width: 92, height: 92 }} />
              <div style={{ fontSize: 18, lineHeight: 1.5 }}>
                <div style={{ fontWeight: 600 }}>Claude Code · foreground app</div>
                <div style={{ color: color.muted, marginTop: 4 }}>
                  Modified keys (Ctrl+Return) route cleanly to the active TUI.
                </div>
              </div>
            </div>
          </Panel>

          <Panel title="OSC 52 clipboard protection" style={{ marginTop: 'auto' }}>
            <Code lines={["printf '\\e]52;c;?\\a'", clipAllowed > 0.5 ? '→ clipboard returned after approval' : '→ awaits explicit macOS approval']} style={{ fontSize: 17 }} />
            <div style={{ padding: '0 16px 14px' }}>
              <Done progress={clipAllowed}>Approved clipboard read</Done>
            </div>
          </Panel>

          <Overlay progress={osc52} style={{ position: 'absolute', inset: 16, display: 'grid', placeItems: 'center', backgroundColor: alpha(color.surface, 76), zIndex: 5 }}>
            <Panel title="Authorize Clipboard Access" style={{ width: '92%', boxShadow: `0 22px 54px ${alpha(color.shadow, 22)}` }}>
              <div style={{ padding: '16px 18px', fontSize: 18 }}>
                A terminal program requested to read your macOS clipboard.
              </div>
              <div style={{ padding: '0 18px 16px', display: 'flex', justifyContent: 'flex-end', gap: 12 }}>
                <Action style={{ fontSize: 16, padding: '6px 14px' }}>Deny</Action>
                <Action active press={allowClipPress} style={{ fontSize: 16, padding: '6px 14px' }}>Allow</Action>
              </div>
            </Panel>
          </Overlay>
        </div>
      </Shell>
    </div>
  );
};

const SessionsBody = (props: DemoProps) =>
  props.step === 0 ? <PersistenceAndProfilesStep {...props} /> : <AlertsAndForegroundStep {...props} />;

export const sessionsChapter: ChapterSpec = {
  id: 'sessions',
  en: 'Sessions, profiles & alerts',
  zh: '会话保活、终端配置与单次提醒',
  nav: '会话与提醒',
  steps: [
    { en: 'Session persistence, Info panel & Terminal Profiles', zh: '退出保活重连、进程端口信息与自动终端配置' },
    { en: 'Next-command alerts, progress & foreground keys', zh: '单次完成提醒、OSC 进度、前台快捷键与剪贴板授权' },
  ],
  features: [
    'Keep sessions running after quitting (reconnect same live PID) vs Quit and End All Sessions, plus Restore session history on relaunch',
    'Session Info (Cmd+Shift+I): Current/Project directories, Processes PID/CPU/Memory, Terminate/Force Kill, listening Ports Open/Kill',
    'Automatic Terminal Profiles matching host, user, directory and foreground program; live theme/font/cursor updates without restarting processes',
    'Notify When Next Command Finishes one-time local zsh reminder with armed bell indicator and cancellation',
    'Long-running/failed/bell/OSC 777 notifications, OSC 9;4 progress bar and Notification History jumping to source pane',
    'Block Zshell Commands foreground shortcut routing, inline terminal images and explicit OSC 52 clipboard approval',
  ],
  sources: [
    'web/content/docs/terminal.mdx',
    'web/content/docs/session-info.mdx',
    'mac/zshell/PersistentPTY.swift',
    'mac/zshell/SessionInfoPanel.swift',
    'mac/zshell/TerminalProfiles.swift',
    'mac/zshell/TerminalNotificationService.swift',
    'mac/zshell/TerminalContextMenu.swift',
  ],
  Body: SessionsBody,
};
