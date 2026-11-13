import type { CSSProperties } from 'react';
import { linear, mix } from '../../lib/motion';
import { alpha, color } from '../../theme';
import { Badge, Group, Panel, Setting, SettingsShell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const AppearanceDemo = ({ step, frame }: DemoProps) => {
  const p = linear(frame, [40, 160]);
  if (step === 0) {
    const contrast = mix(0.35, 1, p);
    const scheme = frame < 95 ? 'Catppuccin Latte' : 'PaperColor Light';
    return <SettingsShell category="Appearance"><div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 28 }}>
      <div><Group title="Theme"><Setting label="Appearance" value="System · Light · Dark" /><Setting label="Light theme" value={scheme} focus /><Setting label="Dark theme" value="Catppuccin Mocha" /><Setting label="Terminal theme only" checked={frame > 150} /><Setting label="Minimum contrast" progress={p} value={`${mix(1, 4.5, p).toFixed(1)}:1`} /></Group><Group title="Panes"><Setting label="Show focus ring on active pane" checked /><Setting label="Opacity" progress={0.55} /></Group></div>
      <Panel title="Live terminal theme preview"><Terminal frame={frame} style={{ backgroundColor: frame < 95 ? '#eff1f5' : '#fffef8' }} command={"printf 'ANSI colors\\n'"}><div style={{ display: 'flex', gap: 10, padding: '10px 0 28px' }}>{['#df4c4c', '#169652', '#d18a20', '#346bce', '#8750b0', '#087c99'].map((tone) => <span key={tone} style={{ height: 48, flex: 1, borderRadius: 8, backgroundColor: tone, opacity: contrast }} />)}</div><div style={{ color: frame < 95 ? '#4c4f69' : '#303a4a' }}>Build passed · 37 tests</div><div style={{ fontSize: 20, color: color.muted, marginTop: 26 }}>The shell keeps running while its theme changes.</div></Terminal></Panel>
    </div></SettingsShell>;
  }
  if (step === 1) {
    const fontSize = mix(24, 32, p);
    const spacing = mix(0, 1.5, p);
    return <SettingsShell category="Appearance"><div style={{ display: 'grid', gridTemplateColumns: '1.1fr 1fr', gap: 28 }}>
      <Group title="Font"><Setting label="Latin family" value={frame < 100 ? 'Menlo' : 'JetBrains Mono'} focus /><Setting label="CJK fallback" value="PingFang SC" /><Setting label="Size" value={`${Math.round(fontSize)} pt`} progress={p} /><Setting label="Line height" value={`${Math.round(mix(100, 120, p))}%`} progress={p} /><Setting label="Cell width" value={`${Math.round(mix(100, 112, p))}%`} /><Setting label="Font ligatures" checked={frame > 120} /><Setting label="OpenType features" value="zero=1, ss01" /><Setting label="Thicken font strokes" checked={frame > 170} />{frame > 170 ? <Setting label="Stroke strength" progress={linear(frame, [170, 210])} /> : null}</Group>
      <Panel title="One live Latin and CJK preview"><Terminal frame={frame} fontSize={fontSize} style={{ fontFamily: frame < 100 ? 'Menlo, PingFang SC, monospace' : 'JetBrains Mono Variable, PingFang SC, monospace', letterSpacing: spacing, lineHeight: mix(1.4, 1.8, p), fontWeight: frame > 170 ? 650 : 400, fontVariantLigatures: frame > 120 ? 'normal' : 'none', fontFeatureSettings: frame > 120 ? '"liga" 1, "calt" 1, "zero" 1' : '"liga" 0, "calt" 0' }} command="git diff"><div>const ready = value !== null;</div><div>const run = () =&gt; ready;</div><div>0123456789 · {'{} [] ()'}</div><div style={{ marginTop: 30 }}>终端在中心。项目在掌握。</div><div>日本語 · 한국어</div></Terminal></Panel>
    </div></SettingsShell>;
  }
  if (step === 2) {
    const shapes = ['bar', 'block', 'underline'] as const;
    const selected = Math.min(2, Math.floor(frame / 70));
    const blinking = frame < 200;
    return <SettingsShell category="Appearance"><div style={{ display: 'grid', gridTemplateColumns: '0.9fr 1.2fr', gap: 36 }}>
      <div><Group title="Cursor"><Setting label="Cursor shape" value={['Bar', 'Block', 'Underline'][selected]} focus /><Setting label="Blink cursor" checked={blinking} /></Group><div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>{shapes.map((shape, i) => <Badge key={shape} active={i === selected}>{['Bar', 'Block', 'Underline'][i]}</Badge>)}</div></div>
      <Panel title="Cursor changes immediately in the active terminal"><Terminal frame={frame} shape={shapes[selected]} blinking={blinking} fontSize={42} command="git status"><div style={{ color: color.green, fontSize: 30 }}>On branch main</div><div style={{ color: color.muted, fontSize: 28 }}>Your branch is up to date.</div></Terminal></Panel>
    </div></SettingsShell>;
  }
  const opacity = mix(1, 0.68, p);
  const previewStyle: CSSProperties = {
    backgroundColor: `rgba(255, 255, 255, ${opacity})`,
    backdropFilter: frame > 120 ? 'blur(18px)' : undefined,
    boxShadow: `inset 0 0 0 2px ${alpha(color.blue, frame > 150 ? 36 : 0)}`,
  };
  return <SettingsShell category="Appearance"><div style={{ display: 'grid', gridTemplateColumns: '1fr 1.1fr', gap: 32 }}>
    <div><Group title="Background"><Setting label="Opacity" value={`${Math.round(opacity * 100)}%`} progress={opacity} focus />{opacity < 1 ? <Setting label="Blur behind window" checked={frame > 120} /> : null}<Setting label="Padding color" value={frame > 145 ? 'Always' : 'Automatic'} /></Group><Group title="Interface"><Setting label="Interface size" value={`${Math.round(mix(100, 110, p))}%`} progress={p} /><Setting label="Sidebar font size" value={`${Math.round(mix(12, 14, p))} pt`} /><Setting label="Dock icon" value="Zshell" /></Group></div>
    <div style={{ padding: 25, borderRadius: 12, background: `repeating-linear-gradient(140deg, ${alpha(color.blue, 16)} 0 50px, ${alpha(color.violet, 10)} 50px 100px)` }}><Panel title="Translucent background"><Terminal frame={frame} style={previewStyle} command="bun test"><div style={{ padding: '8px 12px', backgroundColor: alpha(color.green, 14), color: color.green, margin: frame > 145 ? '-28px -28px 10px' : '0 0 10px' }}>37 pass · 0 fail</div><div style={{ color: color.muted }}>The font stays sharp over the desktop.</div></Terminal></Panel></div>
  </div></SettingsShell>;
};

export const appearanceChapter: ChapterSpec = {
  id: 'appearance', en: 'Appearance & cursor', zh: '字体、配色、背景与光标',
  steps: [
    { en: 'Live themes and readable ANSI colors', zh: '实时主题切换与文字对比度' },
    { en: 'Fonts, CJK fallback and character spacing', zh: '字体、中日韩回退与字形间距' },
    { en: 'Bar, block, underline — blinking or steady', zh: '竖线、方块、下划线，闪烁或常亮' },
    { en: 'Opacity, background blur and interface scale', zh: '透明度、背景模糊与界面缩放' },
  ],
  features: ['system light dark appearance', 'separate light and dark themes', 'terminal theme only', 'minimum contrast', 'Latin family and CJK fallback', 'font size', 'line height and cell width', 'font ligatures and OpenType features', 'font stroke strength', 'bar block underline cursor', 'cursor blink', 'background opacity and blur', 'padding color', 'interface and sidebar sizes', 'Dock icon', 'pane focus ring'],
  sources: ['mac/zshell/Settings/SettingsAppearancePane.swift', 'mac/zshell/TerminalCursorSettings.swift', 'mac/zshell/TerminalCursorSettingsView.swift', 'mac/zshell/Settings/SettingsVisibility.swift'],
  Body: AppearanceDemo,
};
