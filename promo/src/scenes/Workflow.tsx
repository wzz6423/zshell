import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { HudBubble, Keycap, SceneLabel } from '../components/Hud';
import { ReturnIcon } from '../components/Icons';
import { Cursor, JsonLines, PromptLine } from '../components/Terminal';
import { Workspace } from '../components/Workspace';
import { AGENT_RUN, AGENT_STATE_AT, DEMO_COMMANDS, HUDS, PROMPT, TEST_RUN, type StreamLine } from '../data/commands';
import { during, linear, pop, ramp, SPRING, track, type Keyframe } from '../lib/motion';
import { cursorOpacity } from '../lib/typing';
import { alpha, color } from '../theme';
import { HEIGHT, WIDTH } from '../timeline';

const FONT = 19;
const LINE = 1.7;
const SPLIT_AT = DEMO_COMMANDS[0].enterAt + 6;

const TONE = { muted: color.muted, red: color.red, green: color.green, fg: color.fg };

const Stream = ({ lines, frame }: { lines: StreamLine[]; frame: number }) => (
  <>
    {lines
      .filter((line) => frame >= line.at)
      .map((line) => (
        <div key={line.text} style={{ whiteSpace: 'pre', color: TONE[line.tone ?? 'muted'], opacity: linear(frame, [line.at, line.at + 5]) }}>
          {line.text}
        </div>
      ))}
  </>
);

const LeftPane = ({ frame }: { frame: number }) => (
  <div
    className="font-mono"
    style={{
      height: '100%',
      padding: '22px 26px',
      fontSize: FONT,
      lineHeight: LINE,
      // The invoking pane keeps focus for the whole run; the ring says so.
      boxShadow: `inset 0 0 0 1.5px ${alpha(color.cyan, 30 * linear(frame, [SPLIT_AT, SPLIT_AT + 20]))}`,
    }}
  >
    <div style={{ color: color.faint }}>
      {PROMPT.cwd} <span style={{ color: color.violet }}>{PROMPT.branch}</span>
    </div>
    {DEMO_COMMANDS.map((command, index) => {
      const previous = DEMO_COMMANDS[index - 1];
      if (previous && frame < previous.outputAt + 8) return null;
      const entered = frame >= command.enterAt;
      const printed = frame >= command.outputAt;
      return (
        <div key={command.id} style={{ marginBottom: FONT * 0.7 }}>
          <PromptLine text={command.command} frame={frame} from={command.typeFrom} to={command.typeTo} showCursor={!entered} />
          {entered && !printed ? <Cursor opacity={cursorOpacity(frame, false)} tone={color.muted} /> : null}
          {printed ? (
            <JsonLines
              lines={command.output}
              emphasize={command.emphasize}
              style={{ opacity: linear(frame, [command.outputAt, command.outputAt + 6]) }}
            />
          ) : null}
        </div>
      );
    })}
    {frame >= DEMO_COMMANDS[DEMO_COMMANDS.length - 1].outputAt + 8 ? (
      <div>
        <span style={{ color: color.cyan, fontWeight: 700 }}>{PROMPT.symbol} </span>
        <Cursor opacity={cursorOpacity(frame, false)} />
      </div>
    ) : null}
  </div>
);

const phaseAt = (frame: number): keyof typeof AGENT_STATE_AT | null => {
  if (frame >= AGENT_STATE_AT.done) return 'done';
  if (frame >= AGENT_STATE_AT.working) return 'working';
  if (frame >= AGENT_STATE_AT.created) return 'created';
  return null;
};

// Shared with the next scene, which freezes this window on its last frame
// before tilting it, so the cut between the two is invisible.
export const WorkflowWindow = ({ frame, fps }: { frame: number; fps: number }) => {
  const phase = phaseAt(frame);
  const changedAt = phase ? AGENT_STATE_AT[phase] : 0;
  return (
    <Workspace
      split={pop(frame, fps, SPLIT_AT, SPRING.snappy)}
      rightTitle={phase ? 'codex' : 'make test'}
      agent={phase}
      agentPulse={phase ? during(frame, changedAt, changedAt + 46, 12) : 0}
      left={<LeftPane frame={frame} />}
      right={
        <div className="font-mono" style={{ padding: '16px 20px', fontSize: 17, lineHeight: LINE }}>
          <Stream lines={TEST_RUN} frame={frame} />
          <Stream lines={AGENT_RUN} frame={frame} />
        </div>
      }
    />
  );
};

const CAMERA_AT = [26, 186, 300, 462, 496, 628];
const keyframes = (values: number[]): Keyframe[] => values.map((to, index) => ({ at: CAMERA_AT[index], to }));
// Push in while a command is typed, pull back when its result lands.
const ZOOM = keyframes([1.3, 1, 1.22, 1.06, 1.22, 1]);
const FOCUS_X = keyframes([800, 960, 860, 960, 860, 960]);
const FOCUS_Y = keyframes([415, 540, 440, 540, 470, 540]);

const HUD_PLACEMENT: Record<string, { left: number; top: number }> = {
  background: { left: 1250, top: 596 },
  status: { left: 1292, top: 318 },
  agents: { left: 1310, top: 650 },
  lifecycle: { left: 1250, top: 690 },
};

const STEPS = ['+pane split --wait', '+agent start', '+agent prompt'];

export const Workflow = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const zoom = track(frame, fps, 1, ZOOM);
  const focusX = track(frame, fps, WIDTH / 2, FOCUS_X);
  const focusY = track(frame, fps, HEIGHT / 2, FOCUS_Y);
  const enter = ramp(frame, [0, 26]);
  const chrome = during(frame, 10, 770, 14);
  const active = DEMO_COMMANDS.findLastIndex((command) => frame >= command.typeFrom - 14);
  const pressed = Math.max(...DEMO_COMMANDS.map((command) => during(frame, command.enterAt - 3, command.enterAt + 16, 5)));

  return (
    <AbsoluteFill>
      <AbsoluteFill
        style={{
          alignItems: 'center',
          justifyContent: 'center',
          opacity: enter,
          transform: `translate(${(WIDTH / 2 - focusX) * zoom}px, ${(HEIGHT / 2 - focusY) * zoom}px) scale(${zoom * (0.94 + enter * 0.06)})`,
        }}
      >
        <WorkflowWindow frame={frame} fps={fps} />
      </AbsoluteFill>

      <SceneLabel index="02" en="Core workflow" zh="核心工作流" opacity={chrome} />

      {HUDS.map((hud) => (
        <HudBubble
          key={hud.id}
          en={hud.en}
          zh={hud.zh}
          tone={hud.tone}
          progress={Math.min(pop(frame, fps, hud.from, SPRING.snappy), linear(frame, [hud.to - 12, hud.to], [1, 0]))}
          style={HUD_PLACEMENT[hud.id]}
        />
      ))}

      <div
        style={{
          position: 'absolute',
          left: 56,
          bottom: 32,
          display: 'flex',
          alignItems: 'center',
          gap: 18,
          padding: '12px 16px',
          borderRadius: 16,
          // The zoomed window slides underneath, so the strip needs its own ground.
          backgroundColor: alpha(color.surface, 92),
          border: `1px solid ${color.line}`,
          boxShadow: `0 14px 40px ${alpha(color.shadow, 12)}`,
          opacity: chrome,
        }}
      >
        <Keycap pressed={pressed} size={17}>
          <ReturnIcon size={19} />
          return
        </Keycap>
        {STEPS.map((step, index) => (
          <span
            key={step}
            className="font-mono"
            style={{
              fontSize: 16,
              padding: '6px 12px',
              borderRadius: 8,
              color: index === active ? color.fg : color.faint,
              backgroundColor: alpha(color.cyan, index === active ? 12 : 0),
              border: `1px solid ${alpha(color.cyan, index === active ? 40 : 0)}`,
            }}
          >
            <span style={{ color: index <= active ? color.cyan : color.faint }}>0{index + 1}</span> {step}
          </span>
        ))}
      </div>
    </AbsoluteFill>
  );
};
