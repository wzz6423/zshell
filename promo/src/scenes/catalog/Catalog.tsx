import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { SceneLabel } from '../../components/Hud';
import { linear, pop, SPRING } from '../../lib/motion';
import { alpha, color } from '../../theme';
import { appearanceChapter } from './Appearance';
import { projectsChapter } from './Projects';
import { preferencesChapter } from './Preferences';
import { browserChapter } from './Browser';
import { filesChapter } from './Files';
import { gitChapter } from './Git';
import { terminalChapter } from './TerminalInput';
import { agentsChapter } from './Agents';
import { sessionsChapter } from './Sessions';
import { terminalToolsChapter } from './TerminalTools';
import { CHAPTER_STEP_COUNTS, DEMO_SECONDS } from './timing';

export const FEATURE_CHAPTERS = [projectsChapter, appearanceChapter, terminalChapter, terminalToolsChapter, filesChapter, gitChapter, browserChapter, agentsChapter, sessionsChapter, preferencesChapter];
const CHAPTER_START_SECONDS = CHAPTER_STEP_COUNTS.map((_, index) => DEMO_SECONDS * CHAPTER_STEP_COUNTS.slice(0, index).reduce((total, count) => total + count, 0));

export const FeatureCatalog = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const chapterIndex = CHAPTER_START_SECONDS.findLastIndex((start) => frame >= start * fps);
  const chapter = FEATURE_CHAPTERS[chapterIndex];
  const chapterFrames = CHAPTER_STEP_COUNTS[chapterIndex] * DEMO_SECONDS * fps;
  const local = frame - CHAPTER_START_SECONDS[chapterIndex] * fps;
  const stepFrames = DEMO_SECONDS * fps;
  const step = Math.min(chapter.steps.length - 1, Math.floor(local / stepFrames));
  const demoFrame = local - step * stepFrames;
  const actionFrame = Math.min(239, demoFrame * 239 / (stepFrames - fps * 0.65));
  const Body = chapter.Body;
  const enter = Math.min(1, pop(demoFrame, fps, 0, SPRING.smooth));
  const fade = linear(demoFrame, [stepFrames - 6, stepFrames], [1, 0]);

  return (
    <AbsoluteFill>
      <SceneLabel index={`${chapterIndex + 4}`.padStart(2, '0')} en={chapter.en} zh={chapter.zh} opacity={1} />
      <div className="font-sans" style={{ position: 'absolute', left: 96, right: 96, top: 108, display: 'flex', justifyContent: 'space-between', gap: 28, alignItems: 'baseline' }}>
        <div style={{ minWidth: 0 }}><div style={{ fontSize: 35, letterSpacing: -0.7, fontWeight: 650, color: color.fg }}>{chapter.steps[step].en}</div><div style={{ marginTop: 7, fontSize: 23, color: color.muted }}>{chapter.steps[step].zh}</div></div>
        <span className="font-mono" style={{ color: color.blue, fontSize: 21 }}>{step + 1} / {chapter.steps.length}</span>
      </div>
      <div style={{ position: 'absolute', left: 128, right: 128, top: 218, bottom: 100, opacity: enter * fade, transform: `translateY(${(1 - enter) * 14}px)` }}>
        <Body step={step} frame={actionFrame} fps={fps} />
      </div>
      <div className="font-sans" style={{ position: 'absolute', left: 96, right: 96, bottom: 40, display: 'flex', gap: 17, alignItems: 'center' }}>
        {FEATURE_CHAPTERS.map((item, index) => <div key={item.id} style={{ flex: 1, minWidth: 0 }}><div style={{ height: 3, backgroundColor: alpha(color.fg, 8), borderRadius: 999 }}><div style={{ width: `${index < chapterIndex ? 100 : index === chapterIndex ? local / chapterFrames * 100 : 0}%`, height: '100%', backgroundColor: color.blue }} /></div><div style={{ marginTop: 10, fontSize: 16, color: index === chapterIndex ? color.fg : color.muted }}>{['项目与分屏', '外观与光标', '终端输入', '终端工具', '文件与编辑', 'Git 与审查', '内置浏览器', 'AI 与会话', '保活与访问', '设置与工具'][index]}</div></div>)}
      </div>
    </AbsoluteFill>
  );
};
