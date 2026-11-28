import { BellOffIcon, FolderIcon, SearchIcon, TerminalIcon } from '../../components/Icons';
import { mix, ramp } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import {
  Action,
  Badge,
  Code,
  Done,
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

const ProjectsStepOne = ({ frame, fps }: DemoProps) => {
  const openPress = pressAt(frame, 42);
  const projectAdded = revealAt(frame, fps, 46);
  const sshPicker = revealAt(frame, fps, 76) * (1 - revealAt(frame, fps, 138));
  const sshPicked = frame >= 124;
  const connectPress = pressAt(frame, 148);
  const connected = revealAt(frame, fps, 154);
  const muted = revealAt(frame, fps, 118);
  const typedCmd = 'bun run dev'.slice(0, typedLength('bun run dev', frame, 56, 98));
  const typedSsh = 'dev'.slice(0, typedLength('dev', frame, 82, 102));

  return (
    <Shell
      title="Projects — local, OpenSSH & sidebar groups"
      sidebar={
        <>
          <div style={{ fontSize: 14, letterSpacing: 0.6, color: color.muted, padding: '4px 12px 10px' }}>PROJECTS</div>
          <ListRow active trailing={<Badge style={{ padding: '3px 9px', fontSize: 14 }}>main</Badge>}>
            <FolderIcon size={18} color={color.blue} /> app
          </ListRow>
          <ListRow indent={16} style={{ fontSize: 17, padding: '8px 14px' }}>
            <TerminalIcon size={16} color={color.muted} /> zsh
          </ListRow>
          <ListRow
            trailing={
              muted > 0.01 ? (
                <span style={{ display: 'inline-flex', alignItems: 'center', opacity: muted, color: color.amber }}>
                  <BellOffIcon size={17} />
                </span>
              ) : undefined
            }
          >
            <FolderIcon size={18} color={color.muted} /> website
          </ListRow>
          <div
            style={{
              maxHeight: `${projectAdded * 52}px`,
              opacity: projectAdded,
              overflow: 'hidden',
              transform: `translateY(${(1 - projectAdded) * -6}px)`,
            }}
          >
            <ListRow active={frame >= 46 && frame < 118}>
              <FolderIcon size={18} color={color.blue} /> design-system
            </ListRow>
          </div>
          <ListRow>
            <FolderIcon size={18} color={color.muted} /> devbox (SSH)
          </ListRow>
          <div style={{ marginTop: 14, padding: '6px 12px', fontSize: 16, fontWeight: 600, color: color.violet }}>
            ▾ Client work
          </div>
          <ListRow indent={14} style={{ fontSize: 17, padding: '7px 14px' }}>api · pinned</ListRow>
          <ListRow indent={14} style={{ fontSize: 17, padding: '7px 14px' }}>docs</ListRow>
          <Overlay progress={muted} style={{ marginTop: 16 }}>
            <Badge tone="amber" style={{ fontSize: 14, padding: '6px 10px', whiteSpace: 'normal', lineHeight: 1.35 }}>
              <BellOffIcon size={15} /> website muted · agent alerts kept
            </Badge>
          </Overlay>
        </>
      }
    >
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.05fr', gap: 26, padding: 26, height: '100%', boxSizing: 'border-box' }}>
        <Panel title="Finder Service · New Zshell Project Here" style={{ display: 'flex', flexDirection: 'column' }}>
          <div style={{ padding: '18px 22px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', borderBottom: `1px solid ${color.line}`, backgroundColor: alpha(color.blue, 4) }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 14, fontSize: 23, fontWeight: 600 }}>
              <FolderIcon size={30} color={color.blue} /> design-system
            </div>
            <Action active={frame >= 30} press={openPress}>Open in Zshell</Action>
          </div>
          <div style={{ flex: 1, minHeight: 0 }}>
            <Terminal
              frame={frame}
              directory="~/src/design-system"
              command={typedCmd}
              typing={frame >= 56 && frame < 98}
              fontSize={22}
              after={
                <div style={{ marginTop: 14, color: color.green, opacity: ramp(frame, [104, 120]), transform: `translateY(${(1 - ramp(frame, [104, 120])) * 6}px)` }}>
                  VITE ready · http://localhost:3000
                </div>
              }
            />
          </div>
        </Panel>

        <Panel title="New SSH Project…" style={{ position: 'relative', display: 'flex', flexDirection: 'column' }}>
          <Setting
            label="Host"
            focus={sshPicker > 0.1 || sshPicked}
            value={
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 10 }}>
                <span className="font-mono" style={{ color: sshPicked ? color.fg : color.faint }}>{sshPicked ? 'devbox' : 'Select host…'}</span>
                <Badge active={sshPicker > 0.1} style={{ padding: '4px 10px', fontSize: 15 }}>SSH Config Hosts</Badge>
              </span>
            }
          />
          <Setting label="User / Port" value="Inherit from ~/.ssh/config" />
          <Setting label="Remote Directory" value="~/work/api" />
          <Setting label="Authentication" value="SSH Agent · Key · Password" />
          <div style={{ padding: 20, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
            <Action active={sshPicked} press={connectPress}>Connect</Action>
            <Done progress={connected}>Saved SSH project connected</Done>
          </div>
          <div style={{ marginTop: 'auto', padding: '14px 20px', borderTop: `1px solid ${color.line}`, fontSize: 17, color: color.muted }}>
            Sidebar groups · Mute Notifications · Pin &amp; color markers · Saved SSH auth
          </div>

          <Overlay
            progress={sshPicker}
            style={{ position: 'absolute', left: 20, right: 20, top: 96, zIndex: 3 }}
          >
            <Panel title="SSH Config Hosts · ~/.ssh/config" style={{ boxShadow: `0 22px 50px ${alpha(color.shadow, 20)}` }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 16px', borderBottom: `1px solid ${color.line}`, fontSize: 19 }}>
                <SearchIcon size={19} color={color.blue} />
                <span className="font-mono">{typedSsh || 'Filter named Host aliases…'}</span>
              </div>
              <ListRow active={frame >= 104} trailing={<Badge style={{ fontSize: 14, padding: '3px 9px' }}>~/.ssh/config</Badge>}>
                <span className="font-mono">devbox</span>
              </ListRow>
              <ListRow trailing={<span className="font-mono" style={{ fontSize: 16, color: color.muted }}>10.0.4.18</span>}>
                <span className="font-mono">dev-staging</span>
              </ListRow>
            </Panel>
          </Overlay>
        </Panel>
      </div>
    </Shell>
  );
};

const ProjectsStepTwo = ({ frame, fps }: DemoProps) => {
  const palette = revealAt(frame, fps, 6) * (1 - revealAt(frame, fps, 54));
  const splitPress = pressAt(frame, 46);
  const splitRight = revealAt(frame, fps, 56, true);
  const splitDown = revealAt(frame, fps, 92, true);
  const equalize = revealAt(frame, fps, 118, true);
  const templatesSheet = revealAt(frame, fps, 146);
  const applyPress = pressAt(frame, 186);
  const applied = revealAt(frame, fps, 192);
  const query = 'split'.slice(0, typedLength('split', frame, 12, 34));

  // Smoothly expand right pane, then equalize proportions without snapping.
  const leftShare = mix(1, mix(1.42, 1, equalize), splitRight);
  const rightShare = splitRight;

  return (
    <Shell
      title="app — splits, tab groups & workspace templates"
      toolbar={
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <Badge active>build · pinned</Badge>
          <Badge tone="violet">▾ review · Tab group</Badge>
          <Badge active={false}>Ctrl+Tab Switcher</Badge>
          <Badge active={false}>Cmd+Shift+T Reopen</Badge>
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 10 }}>
            <Badge active={palette > 0.2}>Cmd+P Palette</Badge>
            <Badge active={equalize > 0.3 && templatesSheet < 0.2}>Ctrl+Cmd+= Equalize</Badge>
            <Badge active={templatesSheet > 0.3} tone="violet">Cmd+O Quick Launch · Templates</Badge>
          </span>
        </div>
      }
    >
      <div style={{ display: 'flex', gap: 10, height: '100%', padding: 20, boxSizing: 'border-box' }}>
        <div
          style={{
            flex: leftShare,
            minWidth: 0,
            border: `2px solid ${alpha(color.blue, mix(18, 70, splitRight))}`,
            borderRadius: 11,
            overflow: 'hidden',
          }}
        >
          <Terminal
            frame={frame}
            command="bun run dev"
            fontSize={22}
            after={
              <>
                <div style={{ color: color.green, marginTop: 12 }}>Local: http://localhost:3000</div>
                <div style={{ fontSize: 18, marginTop: 14, color: color.muted }}>
                  Focus ring · Opt+Cmd+arrows · Zoom · Move tab across windows
                </div>
              </>
            }
          />
        </div>

        {rightShare > 0.01 ? (
          <div style={{ flex: rightShare, minWidth: 0, opacity: Math.min(1, rightShare * 1.4), display: 'flex', flexDirection: 'column', gap: 10, overflow: 'hidden' }}>
            <Panel title="tests · split right" style={{ flex: 1, minHeight: 0 }}>
              <Terminal
                fontSize={20}
                frame={frame}
                command="bun test"
                after={<div style={{ color: color.green, marginTop: 10 }}>37 pass · 0 fail</div>}
              />
            </Panel>
            {splitDown > 0.01 ? (
              <Panel title="logs · split down" style={{ flex: splitDown, minHeight: 0, opacity: Math.min(1, splitDown * 1.4), overflow: 'hidden' }}>
                <Code lines={['[server] ready', '[watch] source changed', '[build] complete']} style={{ fontSize: 18 }} />
              </Panel>
            ) : null}
          </div>
        ) : null}
      </div>

      <Overlay
        progress={palette}
        style={{ position: 'absolute', left: '26%', right: '26%', top: 72, zIndex: 4 }}
      >
        <Panel title="Command Palette · Cmd+P" style={{ boxShadow: `0 24px 64px ${alpha(color.shadow, 22)}` }}>
          <div className="font-mono" style={{ padding: '14px 20px', fontSize: 22, borderBottom: `1px solid ${color.line}` }}>
            {query || <span style={{ color: color.faint }}>Search commands…</span>}
          </div>
          <ListRow active trailing={<Badge style={{ fontSize: 15, padding: '4px 10px' }}>Cmd+D</Badge>}>Split Right</ListRow>
          <ListRow trailing={<Badge active={false} style={{ fontSize: 15, padding: '4px 10px' }}>Cmd+Shift+D</Badge>}>Split Down</ListRow>
          <ListRow trailing={<Badge active={false} style={{ fontSize: 15, padding: '4px 10px' }}>Cmd+Shift+Return</Badge>}>Toggle Pane Zoom</ListRow>
          <div style={{ padding: '12px 18px', textAlign: 'right', borderTop: `1px solid ${color.line}` }}>
            <Action active press={splitPress}>Return · Split Right</Action>
          </div>
        </Panel>
      </Overlay>

      <Overlay
        progress={templatesSheet}
        style={{ position: 'absolute', inset: 22, display: 'grid', gridTemplateColumns: '0.92fr 1.08fr', gap: 22, padding: 24, borderRadius: 14, backgroundColor: alpha(color.surface, 96), border: `1px solid ${color.lineStrong}`, boxShadow: `0 24px 64px ${alpha(color.shadow, 18)}`, zIndex: 5 }}
      >
        <Panel title="Quick Launch · Cmd+O">
          <ListRow active trailing={<Badge style={{ fontSize: 15, padding: '3px 10px' }}>bun run dev</Badge>}>Frontend dev</ListRow>
          <ListRow trailing={<Badge active={false} style={{ fontSize: 15, padding: '3px 10px' }}>devbox</Badge>}>SSH devbox</ListRow>
          <ListRow trailing={<Badge active={false} style={{ fontSize: 15, padding: '3px 10px' }}>make build</Badge>}>Build release</ListRow>
          <Setting label="Directory" value="~/src/app" />
          <Setting label="Group" value="Daily work" />
          <div style={{ padding: 16, fontSize: 17, color: color.muted }}>Launch any entry in a fresh project from the app or zshell CLI.</div>
        </Panel>
        <Panel title="Workspace Templates · Local & Remote">
          <Setting label="Template" value="Frontend workspace" />
          <Setting label="Layout" value="dev · tests · browser (localhost:3000)" />
          <Setting label="Target" value="Local root or saved remote host (devbox)" />
          <Setting label="Portability" value="Save · Edit · Import / Export JSON" />
          <div style={{ padding: 18, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
            <Action active press={applyPress}>Apply Template</Action>
            <Done progress={applied}>Tabs, splits &amp; startup commands created</Done>
          </div>
        </Panel>
      </Overlay>
    </Shell>
  );
};

const ProjectBody = (props: DemoProps) =>
  props.step === 0 ? <ProjectsStepOne {...props} /> : <ProjectsStepTwo {...props} />;

export const projectsChapter: ChapterSpec = {
  id: 'projects',
  en: 'Projects & panes',
  zh: '项目、会话与分屏',
  nav: '项目与分屏',
  steps: [
    { en: 'Local folders, OpenSSH hosts & muted projects', zh: '本地项目、SSH Config 发现、分组与项目静默' },
    { en: 'Smooth splits, Command Palette & templates', zh: '命令面板分屏、标签分组、快速启动与模板' },
  ],
  features: [
    'local projects and Finder Services',
    'saved SSH connections and OpenSSH SSH Config Hosts discovery',
    'sidebar plain and folder groups, pinning, color markers and persistent project Mute Notifications',
    'command palette search, split right/down/left/up, equalize, zoom, tab groups, tab switcher and reopen closed session',
    'Quick Launch command/SSH entries and local/remote Workspace Templates',
  ],
  sources: [
    'web/content/docs/projects.mdx',
    'web/content/docs/panes.mdx',
    'web/content/docs/quick-launch.mdx',
    'web/content/docs/terminal.mdx',
    'mac/zshell/WorkspaceTemplateController.swift',
    'mac/zshell/CommandPaletteView.swift',
  ],
  Body: ProjectBody,
};
