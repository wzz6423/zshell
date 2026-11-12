import type { ReactNode } from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Chip, CodeSlice, Meter, SceneLabel } from '../components/Hud';
import { ArrowRightIcon, BlockIcon, LockIcon } from '../components/Icons';
import { EVENTS_COMMAND, EVENTS_STREAM } from '../data/commands';
import {
  AGENT_KINDS,
  BACKEND_TRAITS,
  BACKENDS,
  BOUNDARY,
  CONFIG_FOCUS_LINE,
  CONFIG_PATH,
  CONFIG_SLICE,
  LAYERS,
  LIMITS,
} from '../data/product';
import { tokenizeJson, tokenizeShell, tokenizeToml } from '../lib/highlight';
import { during, linear, mix, pop, ramp, SPRING } from '../lib/motion';
import { alpha, color } from '../theme';
import { SCENES } from '../timeline';
import { WorkflowWindow } from './Workflow';

const CHAPTERS = [
  { id: 'A', from: 60, to: 250, en: 'One native app, four layers', zh: '一个原生应用，四层结构', label: 'Architecture', layer: null },
  { id: 'B', from: 250, to: 450, en: 'Two GPU backends, one config key', zh: '两个 GPU 终端后端，一行配置切换', label: 'Backends', layer: 2 },
  { id: 'C', from: 450, to: 650, en: 'A boundary agents cannot cross', zh: '智能体无法越过的边界', label: 'Security', layer: 1 },
  { id: 'D', from: 650, to: 840, en: 'Built to be scripted', zh: '为脚本与扩展而生', label: 'Extension', layer: 1 },
] as const;

const PLATE = { width: 1600, height: 880, gap: 300 };
const STACK_SCALE = 0.46;

const Stack = ({ frame, fps, activeLayer }: { frame: number; fps: number; activeLayer: number | null }) => {
  const tilt = pop(frame, fps, 10, SPRING.camera);
  const explode = pop(frame, fps, 50, SPRING.smooth);
  const depth = (index: number) => (1.5 - index) * PLATE.gap * explode;
  const lit = (index: number) => (activeLayer === null || activeLayer === index ? 1 : 0.38);

  return (
    <AbsoluteFill
      style={{
        alignItems: 'center',
        justifyContent: 'center',
        perspective: 3200,
        transform: `translate(${mix(0, -462, tilt)}px, ${mix(0, 36, tilt)}px) scale(${mix(1, STACK_SCALE, tilt)})`,
      }}
    >
      {/* No opacity or filter on this wrapper: either would flatten the 3D stack. */}
      <div
        style={{
          position: 'relative',
          width: PLATE.width,
          height: PLATE.height,
          transformStyle: 'preserve-3d',
          transform: `rotateX(${50 * tilt}deg) rotateZ(${-24 * tilt}deg)`,
        }}
      >
        {LAYERS.slice(1).map((layer, offset) => {
          const index = offset + 1;
          return (
            <div
              key={layer.index}
              style={{
                position: 'absolute',
                inset: 0,
                display: 'flex',
                flexDirection: 'column',
                justifyContent: 'flex-end',
                padding: '0 64px 46px',
                borderRadius: 28,
                border: `3px solid ${alpha(color[layer.tone], 70)}`,
                backgroundColor: color.surface,
                backgroundImage: `linear-gradient(${alpha(color[layer.tone], 9)}, ${alpha(color[layer.tone], 16)}), linear-gradient(${alpha(color[layer.tone], 10)} 2px, transparent 2px), linear-gradient(90deg, ${alpha(color[layer.tone], 10)} 2px, transparent 2px)`,
                backgroundSize: 'auto, 80px 80px, 80px 80px',
                boxShadow: `0 0 90px ${alpha(color[layer.tone], 22 * lit(index))}`,
                opacity: explode * lit(index),
                transform: `translateZ(${depth(index)}px)`,
              }}
            >
              <div className="font-mono" style={{ fontSize: 44, color: alpha(color[layer.tone], 85) }}>{layer.detail}</div>
              <div className="font-sans" style={{ display: 'flex', alignItems: 'baseline', gap: 30, fontSize: 88, fontWeight: 700, color: color.fg }}>
                <span className="font-mono" style={{ color: color[layer.tone] }}>{layer.index}</span>
                {layer.en}
              </div>
            </div>
          );
        })}

        <div style={{ position: 'absolute', inset: 0, transform: `translateZ(${depth(0)}px)`, opacity: mix(1, lit(0), explode) }}>
          <div
            className="font-sans"
            style={{ position: 'absolute', left: 8, top: -128, display: 'flex', alignItems: 'baseline', gap: 30, fontSize: 88, fontWeight: 700, color: color.fg, opacity: explode }}
          >
            <span className="font-mono" style={{ color: color.cyan }}>{LAYERS[0].index}</span>
            {LAYERS[0].en}
          </div>
          <WorkflowWindow frame={SCENES.workflow.duration - 1} fps={fps} />
          <div style={{ position: 'absolute', inset: 0, borderRadius: 16, border: `3px solid ${alpha(color.cyan, 70 * explode)}` }} />
        </div>
      </div>
    </AbsoluteFill>
  );
};

const Chapter = ({ chapter, frame, children }: { chapter: (typeof CHAPTERS)[number]; frame: number; children: ReactNode }) => {
  const visible = during(frame, chapter.from, chapter.to, 16);
  if (visible <= 0) return null;
  const enter = ramp(frame, [chapter.from, chapter.from + 26]);
  return (
    <div
      style={{
        position: 'absolute',
        left: 1010,
        top: 196,
        width: 838,
        opacity: visible,
        transform: `translateX(${(1 - enter) * 44}px)`,
      }}
    >
      <div className="font-sans" style={{ fontSize: 50, fontWeight: 700, letterSpacing: -1.4, lineHeight: 1.12, color: color.fg }}>{chapter.en}</div>
      <div className="font-sans" style={{ marginTop: 10, fontSize: 25, letterSpacing: 1, color: color.muted }}>{chapter.zh}</div>
      <div style={{ marginTop: 34 }}>{children}</div>
    </div>
  );
};

const Architecture = ({ frame, fps }: { frame: number; fps: number }) => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
    {LAYERS.map((layer, index) => {
      const enter = pop(frame, fps, 84 + index * 14, SPRING.snappy);
      return (
        <div
          key={layer.index}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 22,
            padding: '18px 24px',
            borderRadius: 14,
            backgroundColor: alpha(color.surface, 90),
            border: `1px solid ${alpha(color[layer.tone], 34)}`,
            boxShadow: `inset 4px 0 0 ${color[layer.tone]}`,
            opacity: Math.min(1, enter * 1.5),
            transform: `translateX(${(1 - enter) * 30}px)`,
          }}
        >
          <span className="font-mono" style={{ fontSize: 30, fontWeight: 700, color: color[layer.tone] }}>{layer.index}</span>
          <div>
            <div className="font-sans" style={{ fontSize: 27, fontWeight: 600, color: color.fg }}>
              {layer.en}
              <span style={{ marginLeft: 14, fontSize: 20, fontWeight: 400, color: color.muted }}>{layer.zh}</span>
            </div>
            <div className="font-mono" style={{ marginTop: 4, fontSize: 17, color: color.muted }}>{layer.detail}</div>
          </div>
        </div>
      );
    })}
  </div>
);

const Backends = ({ frame, fps }: { frame: number; fps: number }) => {
  const focus = pop(frame, fps, 322, SPRING.smooth);
  return (
    <>
      <CodeSlice
        title={CONFIG_PATH}
        lines={CONFIG_SLICE.map(tokenizeToml)}
        reveal={(frame - 266) / 9}
        focusLine={CONFIG_FOCUS_LINE}
        focus={focus}
      />
      <div style={{ marginTop: 20, display: 'flex', gap: 16 }}>
        {BACKENDS.map((backend, index) => {
          const enter = pop(frame, fps, 336 + index * 12, SPRING.snappy);
          const chosen = index === 1 ? focus : 1 - focus;
          return (
            <div
              key={backend.name}
              style={{
                flex: 1,
                padding: '16px 20px',
                borderRadius: 14,
                backgroundColor: alpha(color[backend.tone], mix(4, 11, chosen)),
                border: `1px solid ${alpha(color[backend.tone], mix(22, 62, chosen))}`,
                boxShadow: `0 0 ${36 * chosen}px ${alpha(color[backend.tone], 22)}`,
                opacity: Math.min(1, enter * 1.5),
                transform: `translateY(${(1 - enter) * 18}px)`,
              }}
            >
              <div className="font-mono" style={{ fontSize: 25, fontWeight: 700, color: color[backend.tone] }}>{backend.name}</div>
              <div className="font-sans" style={{ marginTop: 4, fontSize: 18, color: color.muted }}>
                {backend.note.en} · {backend.note.zh}
              </div>
            </div>
          );
        })}
      </div>
      <div style={{ marginTop: 18, display: 'flex', flexWrap: 'wrap', gap: 10 }}>
        {BACKEND_TRAITS.map((trait, index) => (
          <Chip key={trait} opacity={linear(frame, [366 + index * 7, 378 + index * 7])}>{trait}</Chip>
        ))}
      </div>
    </>
  );
};

const Security = ({ frame, fps }: { frame: number; fps: number }) => {
  // One request travels the chain and stops at the project boundary.
  const travel = linear(frame, [482, 566]) * (BOUNDARY.chain.length - 1);
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'stretch', gap: 8 }}>
        {BOUNDARY.chain.map((node, index) => {
          const enter = pop(frame, fps, 468 + index * 10, SPRING.snappy);
          const reached = Math.max(0, Math.min(1, travel - index + 1));
          const last = index === BOUNDARY.chain.length - 1;
          return (
            <div key={node.label} style={{ display: 'flex', alignItems: 'center', gap: 8, flex: 1, opacity: Math.min(1, enter * 1.5) }}>
              <div
                style={{
                  flex: 1,
                  alignSelf: 'stretch',
                  padding: '16px 14px',
                  borderRadius: 14,
                  backgroundColor: alpha(color.cyan, mix(3, 11, reached)),
                  border: `1px solid ${alpha(color.cyan, mix(16, 62, reached))}`,
                  boxShadow: `0 0 ${30 * reached}px ${alpha(color.cyan, 20)}`,
                }}
              >
                <div className="font-sans" style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 21, fontWeight: 600, color: color.fg }}>
                  {index === 2 ? <LockIcon size={18} color={color.cyan} /> : null}
                  {node.label}
                </div>
                <div className="font-mono" style={{ marginTop: 6, fontSize: 13.5, lineHeight: 1.4, color: color.muted }}>{node.sub}</div>
              </div>
              {last ? null : <ArrowRightIcon size={20} color={alpha(color.cyan, mix(30, 100, reached))} />}
            </div>
          );
        })}
      </div>
      <div style={{ marginTop: 26, display: 'flex', flexDirection: 'column', gap: 12 }}>
        {BOUNDARY.rules.map((rule, index) => {
          const enter = pop(frame, fps, 556 + index * 14, SPRING.snappy);
          return (
            <div
              key={rule.en}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 16,
                padding: '14px 20px',
                borderRadius: 12,
                backgroundColor: alpha(color.red, 6),
                border: `1px solid ${alpha(color.red, 28)}`,
                opacity: Math.min(1, enter * 1.5),
                transform: `translateX(${(1 - enter) * 26}px)`,
              }}
            >
              <BlockIcon size={24} color={color.red} />
              <div className="font-sans">
                <div style={{ fontSize: 22, fontWeight: 500, color: color.fg }}>{rule.en}</div>
                <div style={{ marginTop: 2, fontSize: 17, color: color.muted }}>{rule.zh}</div>
              </div>
            </div>
          );
        })}
      </div>
    </>
  );
};

const Extension = ({ frame, fps }: { frame: number; fps: number }) => (
  <>
    <CodeSlice
      title="NDJSON event stream · it does not poll"
      lines={[tokenizeShell(EVENTS_COMMAND), ...EVENTS_STREAM.map(tokenizeJson)]}
      reveal={(frame - 664) / 14}
      fontSize={18}
    />
    <div style={{ marginTop: 18, display: 'flex', flexWrap: 'wrap', gap: 9 }}>
      {AGENT_KINDS.map((kind, index) => (
        <Chip key={kind} tone="violet" opacity={linear(frame, [704 + index * 4, 714 + index * 4])}>{kind}</Chip>
      ))}
    </div>
    <div style={{ marginTop: 24, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '18px 34px' }}>
      {LIMITS.map((limit, index) => (
        <Meter key={limit.label} {...limit} progress={pop(frame, fps, 736 + index * 8, SPRING.smooth)} />
      ))}
    </div>
  </>
);

export const UnderTheHood = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const active = CHAPTERS.find((chapter) => frame >= chapter.from && frame < chapter.to);
  const chrome = during(frame, 40, 830, 16);
  const [architecture, backends, security, extension] = CHAPTERS;

  return (
    <AbsoluteFill style={{ opacity: linear(frame, [824, 840], [1, 0]) }}>
      <Stack frame={frame} fps={fps} activeLayer={active?.layer ?? null} />

      <SceneLabel index="03" en="Under the hood" zh="底层架构" opacity={chrome} />

      <div style={{ position: 'absolute', left: 1010, top: 132, width: 838, display: 'flex', gap: 10, opacity: chrome }}>
        {CHAPTERS.map((chapter) => (
          <div key={chapter.id} style={{ flex: 1 }}>
            <div style={{ height: 3, borderRadius: 999, backgroundColor: alpha(color.fg, 10), overflow: 'hidden' }}>
              <div style={{ width: `${linear(frame, [chapter.from, chapter.to]) * 100}%`, height: '100%', backgroundColor: color.cyan }} />
            </div>
            <div
              className="font-mono"
              style={{ marginTop: 9, fontSize: 14, letterSpacing: 1.2, color: chapter === active ? color.fg : color.faint }}
            >
              {chapter.id} · {chapter.label.toUpperCase()}
            </div>
          </div>
        ))}
      </div>

      <Chapter chapter={architecture} frame={frame}><Architecture frame={frame} fps={fps} /></Chapter>
      <Chapter chapter={backends} frame={frame}><Backends frame={frame} fps={fps} /></Chapter>
      <Chapter chapter={security} frame={frame}><Security frame={frame} fps={fps} /></Chapter>
      <Chapter chapter={extension} frame={frame}><Extension frame={frame} fps={fps} /></Chapter>
    </AbsoluteFill>
  );
};
