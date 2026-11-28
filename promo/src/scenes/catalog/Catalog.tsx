import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { SceneLabel } from '../../components/Hud';
import { pop, ramp, SPRING } from '../../lib/motion';
import { alpha, color } from '../../theme';
import { agentsChapter } from './Agents';
import { browserChapter } from './Browser';
import { filesChapter } from './Files';
import { gitChapter } from './Git';
import { preferencesChapter } from './Preferences';
import { projectsChapter } from './Projects';
import { sessionsChapter } from './Sessions';
import { terminalChapter } from './TerminalInput';
import { CATALOG_SECONDS, CHAPTER_STEP_COUNTS, STEP_SECONDS } from './timing';

export const FEATURE_CHAPTERS = [
  projectsChapter,
  terminalChapter,
  filesChapter,
  gitChapter,
  browserChapter,
  agentsChapter,
  sessionsChapter,
  preferencesChapter,
];

const CHAPTER_START_SECONDS = CHAPTER_STEP_COUNTS.map(
  (_, index) =>
    STEP_SECONDS * CHAPTER_STEP_COUNTS.slice(0, index).reduce((total, count) => total + count, 0),
);

export const FeatureCatalog = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const totalFrames = Math.round(CATALOG_SECONDS * fps);
  const stepFrames = Math.round(STEP_SECONDS * fps);

  const chapterIndex = Math.max(
    0,
    CHAPTER_START_SECONDS.findLastIndex((start) => frame >= Math.round(start * fps)),
  );
  const chapter = FEATURE_CHAPTERS[chapterIndex];
  const chapterStartFrame = Math.round(CHAPTER_START_SECONDS[chapterIndex] * fps);
  const chapterFrames = CHAPTER_STEP_COUNTS[chapterIndex] * stepFrames;
  const local = frame - chapterStartFrame;

  const step = Math.min(chapter.steps.length - 1, Math.floor(local / stepFrames));
  const demoFrame = local - step * stepFrames;
  const Body = chapter.Body;

  // Smooth scene boundaries so entering from UnderTheHood and exiting to BentoGrid never snaps.
  const sceneOpacity = Math.min(
    ramp(frame, [0, 18]),
    ramp(frame, [totalFrames - 18, totalFrames], [1, 0]),
  );
  // Keep the chapter label steady across steps within the same chapter; crossfade only at chapter edges.
  const labelOpacity =
    sceneOpacity *
    Math.min(
      chapterIndex === 0 ? 1 : ramp(local, [0, 14]),
      chapterIndex === FEATURE_CHAPTERS.length - 1 ? 1 : ramp(local, [chapterFrames - 14, chapterFrames], [1, 0]),
    );

  const stepEnter = Math.min(1, pop(demoFrame, fps, 0, SPRING.snappy));
  const stepExit = ramp(demoFrame, [stepFrames - 16, stepFrames], [1, 0]);
  const headerEnter = ramp(demoFrame, [0, 16]);
  const headerOpacity = Math.min(headerEnter, stepExit);

  return (
    <AbsoluteFill style={{ opacity: sceneOpacity }}>
      <SceneLabel
        index={`${chapterIndex + 4}`.padStart(2, '0')}
        en={chapter.en}
        zh={chapter.zh}
        opacity={labelOpacity}
      />

      <div
        className="font-sans"
        style={{
          position: 'absolute',
          left: 96,
          right: 96,
          top: 102,
          display: 'flex',
          justifyContent: 'space-between',
          gap: 28,
          alignItems: 'baseline',
          opacity: headerOpacity,
          transform: `translateY(${(1 - headerEnter) * 10 - (1 - stepExit) * 6}px)`,
        }}
      >
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 35, letterSpacing: -0.7, fontWeight: 650, color: color.fg }}>
            {chapter.steps[step].en}
          </div>
          <div style={{ marginTop: 6, fontSize: 22, color: color.muted }}>
            {chapter.steps[step].zh}
          </div>
        </div>
        <span className="font-mono" style={{ color: color.blue, fontSize: 20, flexShrink: 0 }}>
          {step + 1} / {chapter.steps.length}
        </span>
      </div>

      {/* Unified stage bounds keep every chapter window anchored at identical margins. */}
      <div
        style={{
          position: 'absolute',
          left: 96,
          right: 96,
          top: 206,
          bottom: 96,
          opacity: Math.min(1, stepEnter * 1.35) * stepExit,
          transform: `translateY(${(1 - stepEnter) * 16 - (1 - stepExit) * 8}px) scale(${0.985 + stepEnter * 0.015})`,
        }}
      >
        <Body step={step} frame={demoFrame} fps={fps} />
      </div>

      <div
        className="font-sans"
        style={{
          position: 'absolute',
          left: 96,
          right: 96,
          bottom: 36,
          display: 'flex',
          gap: 18,
          alignItems: 'center',
        }}
      >
        {FEATURE_CHAPTERS.map((item, index) => (
          <div key={item.id} style={{ flex: 1, minWidth: 0 }}>
            <div style={{ height: 3, backgroundColor: alpha(color.fg, 8), borderRadius: 999, overflow: 'hidden' }}>
              <div
                style={{
                  width: `${index < chapterIndex ? 100 : index === chapterIndex ? Math.min(100, (local / chapterFrames) * 100) : 0}%`,
                  height: '100%',
                  backgroundColor: color.blue,
                  borderRadius: 999,
                }}
              />
            </div>
            <div
              style={{
                marginTop: 9,
                fontSize: 16,
                fontWeight: index === chapterIndex ? 600 : 400,
                color: index === chapterIndex ? color.fg : color.muted,
                whiteSpace: 'nowrap',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
              }}
            >
              {item.nav}
            </div>
          </div>
        ))}
      </div>
    </AbsoluteFill>
  );
};
