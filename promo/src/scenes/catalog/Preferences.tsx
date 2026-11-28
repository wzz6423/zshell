import type { CSSProperties } from 'react';
import { Img } from 'remotion';
import icon from '../../../../web/public/zshell-icon.png';
import { ShieldIcon } from '../../components/Icons';
import { mix, ramp } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import {
  Action,
  Badge,
  Done,
  Group,
  ListRow,
  Panel,
  Setting,
  SettingsShell,
  Shell,
  Terminal,
  pressAt,
  revealAt,
  type ChapterSpec,
  type DemoProps,
} from './Frame';

const AppearanceStep = ({ frame, fps }: DemoProps) => {
  const contrastP = ramp(frame, [16, 84]);
  const fontP = ramp(frame, [52, 132]);
  const opacityP = ramp(frame, [132, 196]);
  const ligatures = revealAt(frame, fps, 92, true);
  const blurOn = revealAt(frame, fps, 152, true);
  const shapes = ['bar', 'block', 'underline'] as const;
  const cursorIndex = Math.min(2, Math.floor(frame / 75));
  const lightTheme = frame < 88 ? 'Catppuccin Latte' : 'PaperColor Light';
  const fontSize = mix(21, 24.5, fontP);
  const bgOpacity = mix(1, 0.72, opacityP);

  const previewStyle: CSSProperties = {
    backgroundColor: frame < 88 ? `rgba(239, 241, 245, ${bgOpacity})` : `rgba(255, 254, 248, ${bgOpacity})`,
    backdropFilter: blurOn > 0.4 ? `blur(${Math.round(16 * blurOn)}px)` : undefined,
    fontFamily: frame < 60 ? 'Menlo, "PingFang SC", monospace' : '"JetBrains Mono Variable", "PingFang SC", monospace',
    lineHeight: mix(1.48, 1.72, fontP),
    fontVariantLigatures: ligatures > 0.5 ? 'normal' : 'none',
    fontFeatureSettings: ligatures > 0.5 ? '"liga" 1, "calt" 1, "zero" 1' : '"liga" 0, "calt" 0',
  };

  return (
    <SettingsShell category="Appearance">
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.05fr', gap: 24, height: '100%' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <Group title="Theme & Background" style={{ marginBottom: 0 }}>
            <Setting label="Light / Dark theme" value={`${lightTheme} · Mocha`} focus={frame < 96} />
            <Setting label="Minimum contrast" progress={contrastP} value={`${mix(1, 4.5, contrastP).toFixed(1)}:1`} />
            <Setting label="Opacity & blur" progress={bgOpacity} value={`${Math.round(bgOpacity * 100)}%`} focus={opacityP > 0.1} />
            <Setting label="Blur behind window" checked={blurOn} />
          </Group>
          <Group title="Font & Cursor" style={{ marginBottom: 0 }}>
            <Setting label="Latin + CJK fallback" value="JetBrains Mono · PingFang SC" focus={frame >= 60 && frame < 120} />
            <Setting label="Font ligatures & OpenType" checked={ligatures} />
            <Setting label="Cursor shape" value={['Bar', 'Block', 'Underline'][cursorIndex]} focus />
            <Setting label="Interface & sidebar scale" value="105% · Padding color · Focus ring" />
          </Group>
        </div>

        <div
          style={{
            padding: 20,
            borderRadius: 14,
            background: `repeating-linear-gradient(135deg, ${alpha(color.blue, 14)} 0 42px, ${alpha(color.violet, 9)} 42px 84px)`,
            display: 'flex',
            flexDirection: 'column',
          }}
        >
          <Panel title="Live terminal preview · updates open panes immediately" style={{ flex: 1, backgroundColor: 'transparent' }}>
            <Terminal frame={frame} fontSize={fontSize} shape={shapes[cursorIndex]} style={previewStyle} command="git diff">
              <div style={{ display: 'flex', gap: 8, marginBottom: 18 }}>
                {['#df4c4c', '#169652', '#d18a20', '#346bce', '#8750b0', '#087c99'].map((tone) => (
                  <span key={tone} style={{ height: 28, flex: 1, borderRadius: 6, backgroundColor: tone, opacity: mix(0.42, 1, contrastP) }} />
                ))}
              </div>
              <div style={{ whiteSpace: 'nowrap' }}>const ready = value !== null;</div>
              <div style={{ whiteSpace: 'nowrap' }}>const run = () =&gt; ready;</div>
              <div style={{ marginTop: 16 }}>终端在中心。项目在掌握。</div>
              <div style={{ color: color.muted }}>日本語 · 한국어 · 0123456789</div>
            </Terminal>
          </Panel>
        </div>
      </div>
    </SettingsShell>
  );
};

const CommandsAndPermissionsStep = ({ frame, fps }: DemoProps) => {
  const branchText = 'release/1.2'.slice(0, typedLength('release/1.2', frame, 18, 62));
  const envProd = frame >= 74;
  const runPress = pressAt(frame, 128);
  const inserted = revealAt(frame, fps, 134);
  const dragHelper = ramp(frame, [92, 158]);
  const permGranted = revealAt(frame, fps, 162);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.02fr 0.98fr', gap: 24, height: '100%' }}>
      <Shell
        title="Manage Quick Commands — Parameters"
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Badge active>Text &amp; Dropdown parameters</Badge>
            <Badge active={false}>Saved defaults</Badge>
            <span style={{ marginLeft: 'auto', fontSize: 16, color: color.muted }}>Literal shell args · original zsh</span>
          </div>
        }
      >
        <div style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 14, height: '100%', boxSizing: 'border-box' }}>
          <Panel title="Template · Deploy release">
            <div className="font-mono" style={{ padding: '12px 16px', fontSize: 18, color: color.blue, borderBottom: `1px solid ${color.line}` }}>
              ./deploy --environment {'{{environment}}'} --branch {'{{branch}}'}
            </div>
            <Setting
              label="environment (Dropdown)"
              focus={frame >= 62 && frame < 105}
              value={<Badge tone={envProd ? 'violet' : 'blue'} style={{ padding: '3px 10px', fontSize: 15 }}>{envProd ? 'production ▾' : 'staging ▾'}</Badge>}
            />
            <Setting
              label="branch (Text)"
              focus={frame >= 16 && frame < 64}
              value={<span className="font-mono">{branchText || 'main'}</span>}
            />
          </Panel>

          <Panel title="Command Preview" style={{ backgroundColor: alpha(color.raised, 50) }}>
            <div className="font-mono" style={{ padding: '13px 16px', fontSize: 18, color: color.fg }}>
              ./deploy --environment <span style={{ color: color.violet }}>{envProd ? 'production' : 'staging'}</span> --branch <span style={{ color: color.green }}>{branchText || 'main'}</span>
            </div>
          </Panel>

          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <Action active press={runPress} style={{ padding: '7px 14px', fontSize: 16 }}>Insert into Terminal</Action>
            <Action style={{ padding: '7px 14px', fontSize: 16 }}>Run Command</Action>
            <Done progress={inserted} style={{ marginLeft: 'auto', fontSize: 15 }}>Inserted safely</Done>
          </div>

          <div style={{ marginTop: 'auto', paddingTop: 10, borderTop: `1px solid ${color.line}`, fontSize: 16, color: color.muted }}>
            Settings search · Custom shortcuts · 17 languages · Dock/Menu Bar · Keep Mac awake
          </div>
        </div>
      </Shell>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 18, height: '100%' }}>
        <Shell title="Settings — Permissions & Draggable App Helper" style={{ flex: 1.08, position: 'relative' }}>
          <div style={{ padding: 18, position: 'relative' }}>
            <Panel>
              <Setting label="Notifications" value={<Done style={{ fontSize: 14, padding: '3px 9px' }}>Allowed</Done>} />
              <Setting
                label="Accessibility & Input Monitoring"
                focus={permGranted < 0.5 && frame >= 80}
                value={permGranted > 0.5 ? <Done progress={permGranted} style={{ fontSize: 14, padding: '3px 9px' }}>Added</Done> : <Action style={{ padding: '4px 10px', fontSize: 14 }}>Open System Settings</Action>}
              />
              <Setting label="Screen Recording · Full Disk Access" value={<Badge active={false} style={{ fontSize: 14, padding: '3px 9px' }}><ShieldIcon size={14} /> Helper ready</Badge>} />
            </Panel>

            <div
              style={{
                marginTop: 14,
                display: 'flex',
                alignItems: 'center',
                gap: 16,
                padding: '10px 16px',
                borderRadius: 10,
                border: `1px dashed ${alpha(color.blue, 45)}`,
                backgroundColor: alpha(color.blue, 5),
              }}
            >
              <div style={{ width: 52, height: 52, flexShrink: 0, display: 'grid', placeItems: 'center' }}>
                <Img
                  src={icon}
                  style={{
                    width: 44,
                    height: 44,
                    transform: `translateY(${-Math.sin(dragHelper * Math.PI) * 7}px) scale(${1 + Math.sin(dragHelper * Math.PI) * 0.09})`,
                    filter: `drop-shadow(0 ${4 + Math.sin(dragHelper * Math.PI) * 8}px ${10 + Math.sin(dragHelper * Math.PI) * 10}px ${alpha(color.blue, 28)})`,
                  }}
                />
              </div>
              <div style={{ fontSize: 16, color: color.muted, lineHeight: 1.45 }}>
                Floating helper window provides Zshell’s icon to drag directly into macOS permission lists.
              </div>
            </div>
          </div>
        </Shell>

        <Shell title="Other · Recommendations & About · Updates" style={{ flex: 0.92 }}>
          <div style={{ padding: 16 }}>
            <ListRow style={{ padding: '7px 14px', fontSize: 17 }} trailing={<Done style={{ fontSize: 14, padding: '3px 9px' }}>Installed</Done>}>
              Homebrew · GitHub CLI · Node.js
            </ListRow>
            <ListRow
              style={{ padding: '7px 14px', fontSize: 17 }}
              trailing={
                <div style={{ display: 'flex', gap: 8 }}>
                  <Action style={{ padding: '4px 10px', fontSize: 14 }}>Project</Action>
                  <Action active style={{ padding: '4px 10px', fontSize: 14 }}>Download</Action>
                </div>
              }
            >
              Quiet.md · local notes &amp; rich text
            </ListRow>
            <ListRow style={{ padding: '7px 14px', fontSize: 17 }} trailing={<Done style={{ fontSize: 14, padding: '3px 9px' }}>Up to date</Done>}>
              Controlled app updates · Export / Import settings
            </ListRow>
          </div>
        </Shell>
      </div>
    </div>
  );
};

const PreferencesBody = (props: DemoProps) =>
  props.step === 0 ? <AppearanceStep {...props} /> : <CommandsAndPermissionsStep {...props} />;

export const preferencesChapter: ChapterSpec = {
  id: 'preferences',
  en: 'Appearance, commands & system',
  zh: '外观、参数命令与系统权限',
  nav: '外观与系统',
  steps: [
    { en: 'Live themes, typography, cursors & translucency', zh: '实时主题、最低对比度、字体连字、光标与透明模糊' },
    { en: 'Parameterized quick commands, Permissions & tools', zh: '参数化快捷命令、macOS 系统权限助手与工具更新' },
  ],
  features: [
    'Live Light/Dark themes, minimum contrast, Latin + CJK fonts, ligatures, OpenType features, Bar/Block/Underline cursors, background opacity/blur/padding and interface scale',
    'Parameterized Quick Commands with Text and Dropdown inputs, saved defaults, live Command Preview and literal-argument Insert/Run in original zsh',
    'Settings -> Permissions status overview, Request Access, Open System Settings and floating draggable app icon helper',
    'Settings search, custom shortcuts with conflict detection, 17 languages, Dock/Menu Bar presence, keep computer awake, export/import settings',
    'Recommended CLI tools (Homebrew, GitHub CLI, Node.js), Quiet.md official Project/Download links and controlled Sparkle app updates',
  ],
  sources: [
    'web/content/docs/configuration.mdx',
    'web/content/docs/terminal.mdx',
    'mac/zshell/Settings/SettingsAppearancePane.swift',
    'mac/zshell/QuickCommands.swift',
    'mac/zshell/Settings/SettingsPermissionsPane.swift',
    'mac/zshell/Settings/SettingsRecommendationsPane.swift',
    'mac/zshell/Settings/SettingsUpdatesPane.swift',
  ],
  Body: PreferencesBody,
};
