import { AbsoluteFill, Easing, useCurrentFrame, useVideoConfig } from 'remotion';
import { Lockup } from '../components/Lockup';
import { Cursor } from '../components/Terminal';
import { Workspace } from '../components/Workspace';
import { LEGACY_FILES, LEGACY_LINE_COUNT, type LegacyFile } from '../data/legacy';
import { PROMPT } from '../data/commands';
import { TOKEN_COLOR, tokenizeRc } from '../lib/highlight';
import { during, linear, mix, pop, ramp, SPRING } from '../lib/motion';
import { cursorOpacity } from '../lib/typing';
import { alpha, color } from '../theme';
import { SCENES } from '../timeline';

const COLLAPSE_FROM = 156;
const COLLAPSE_TO = 226;
const WINDOW_AT = 224;
const TITLE_AT = 278;
const FRAMES_PER_LINE = 6.5;

const LegacyPanel = ({ file, frame, fps }: { file: LegacyFile; frame: number; fps: number }) => {
  const enter = pop(frame, fps, file.at, SPRING.snappy);
  const collapse = ramp(frame, [COLLAPSE_FROM, COLLAPSE_TO], [0, 1], Easing.in(Easing.cubic));
  const shown = (frame - file.at - 6) / FRAMES_PER_LINE;

  return (
    <div
      className="font-mono"
      style={{
        position: 'absolute',
        left: '50%',
        top: '50%',
        width: 760,
        marginLeft: -380,
        marginTop: -170,
        borderRadius: 14,
        overflow: 'hidden',
        backgroundColor: alpha(color.surface, 96),
        border: `1px solid ${color.lineStrong}`,
        boxShadow: `0 40px 90px ${alpha(color.shadow, 17)}`,
        opacity: Math.min(1, enter * 1.6) * (1 - linear(frame, [COLLAPSE_TO - 20, COLLAPSE_TO])),
        filter: `blur(${collapse * 5}px)`,
        transform: `translate(${file.x * (1 - collapse)}px, ${file.y * (1 - collapse) + (1 - enter) * 60}px) rotate(${file.rotate + collapse * file.rotate * 14}deg) scale(${(0.9 + enter * 0.1) * (1 - collapse * 0.97)})`,
      }}
    >
      <div style={{ padding: '10px 18px', fontSize: 15, color: color.muted, backgroundColor: color.raised, borderBottom: `1px solid ${color.line}` }}>
        {file.name}
      </div>
      <div style={{ padding: '14px 18px', fontSize: 19, lineHeight: 1.7 }}>
        {file.lines.map((line, index) => (
          <div key={line} style={{ whiteSpace: 'pre', opacity: Math.max(0, Math.min(1, shown - index)) }}>
            {tokenizeRc(line).map((token, tokenIndex) => (
              <span key={tokenIndex} style={{ color: token.kind === 'plain' ? color.muted : TOKEN_COLOR[token.kind] }}>{token.text}</span>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
};

export const Awakening = () => {
  const rawFrame = useCurrentFrame();
  const tempo = 420 / SCENES.awakening.duration;
  const frame = rawFrame * tempo;
  const fps = useVideoConfig().fps * tempo;

  const loneCursor = 1 - linear(frame, [22, 36]);
  const caption = during(frame, 64, COLLAPSE_FROM + 10, 16);
  const flash = during(frame, COLLAPSE_TO - 24, COLLAPSE_TO + 32, 20);
  const windowIn = pop(frame, fps, WINDOW_AT, SPRING.bouncy);
  const settle = pop(frame, fps, TITLE_AT, SPRING.camera);
  const fadeOut = ramp(rawFrame, [SCENES.awakening.duration - 18, SCENES.awakening.duration], [1, 0]);

  return (
    <AbsoluteFill style={{ opacity: fadeOut }}>
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', fontSize: 64, opacity: loneCursor }}>
        <Cursor opacity={cursorOpacity(rawFrame, false)} />
      </AbsoluteFill>

      {LEGACY_FILES.map((file) => (
        <LegacyPanel key={file.name} file={file} frame={frame} fps={fps} />
      ))}

      <div
        className="font-mono"
        style={{ position: 'absolute', left: 0, right: 0, bottom: 84, textAlign: 'center', fontSize: 22, color: color.muted, opacity: caption }}
      >
        <span style={{ color: color.amber }}>{LEGACY_FILES.length} files</span>
        {' · '}
        <span style={{ color: color.amber }}>{LEGACY_LINE_COUNT} lines</span> of glue to make a terminal feel like a workspace
      </div>

      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center' }}>
        <div
          style={{
            width: 18,
            height: 18,
            borderRadius: 999,
            backgroundColor: color.cyan,
            opacity: flash,
            transform: `scale(${1 + flash * 5})`,
            boxShadow: `0 0 ${120 * flash}px ${40 * flash}px ${alpha(color.cyan, 60)}`,
          }}
        />
      </AbsoluteFill>

      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center' }}>
        <Workspace
          left={
            <div className="font-mono" style={{ padding: '26px 30px', fontSize: 20, lineHeight: 1.7 }}>
              <div style={{ color: color.faint }}>
                {PROMPT.cwd} <span style={{ color: color.violet }}>{PROMPT.branch}</span>
              </div>
              <div>
                <span style={{ color: color.cyan, fontWeight: 700 }}>{PROMPT.symbol} </span>
                <Cursor opacity={cursorOpacity(rawFrame, false)} />
              </div>
            </div>
          }
          style={{
            opacity: Math.min(1, windowIn * 1.4) * mix(1, 0.58, settle),
            transform: `translateY(${mix(0, 266, settle)}px) scale(${mix(0.3, 0.88, windowIn) * mix(1, 0.66, settle)})`,
          }}
        />
      </AbsoluteFill>

      <div style={{ position: 'absolute', left: 0, right: 0, top: 112, display: 'flex', justifyContent: 'center' }}>
        <Lockup at={(TITLE_AT + 4) / tempo} />
      </div>
    </AbsoluteFill>
  );
};
