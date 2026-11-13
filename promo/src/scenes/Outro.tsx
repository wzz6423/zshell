import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Keycap } from '../components/Hud';
import { ReturnIcon } from '../components/Icons';
import { Lockup } from '../components/Lockup';
import { PromptLine } from '../components/Terminal';
import { PRODUCT } from '../data/product';
import { during, linear, mix, pop, ramp, SPRING } from '../lib/motion';
import { alpha, color } from '../theme';
import { SCENES } from '../timeline';

const TYPE = [30, 112] as const;
const ENTER_AT = 128;
const LOCKUP_AT = 168;

export const Outro = () => {
  const tempo = 420 / SCENES.outro.duration;
  const frame = useCurrentFrame() * tempo;
  const fps = useVideoConfig().fps * tempo;

  const promptIn = ramp(frame, [6, 30]);
  const press = during(frame, ENTER_AT - 6, ENTER_AT + 16, 6);
  const wave = ramp(frame, [ENTER_AT, ENTER_AT + 60]);
  const lift = pop(frame, fps, LOCKUP_AT - 14, SPRING.camera);
  const details = pop(frame, fps, LOCKUP_AT + 56, SPRING.smooth);

  return (
    <AbsoluteFill style={{ opacity: linear(frame, [0, 14]) }}>
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center' }}>
        <div
          style={{
            width: 240,
            height: 240,
            borderRadius: 999,
            border: `2px solid ${alpha(color.cyan, 80 * (1 - wave))}`,
            boxShadow: `0 0 ${90 * (1 - wave)}px ${alpha(color.cyan, 50 * (1 - wave))}`,
            opacity: frame >= ENTER_AT ? 1 : 0,
            transform: `translateY(${mix(0, 330, lift)}px) scale(${0.3 + wave * 8})`,
          }}
        />
      </AbsoluteFill>

      <div style={{ position: 'absolute', left: 0, right: 0, top: 232, display: 'flex', justifyContent: 'center', opacity: frame >= LOCKUP_AT ? 1 : 0 }}>
        <Lockup at={LOCKUP_AT / tempo}>
          <div
            className="font-mono"
            style={{ marginTop: 46, display: 'flex', alignItems: 'center', gap: 18, fontSize: 30, opacity: details, transform: `translateY(${(1 - details) * 16}px)` }}
          >
            <span style={{ color: color.fg, fontWeight: 600 }}>{PRODUCT.repo}</span>
            <span style={{ width: 5, height: 5, borderRadius: 999, backgroundColor: color.faint }} />
            <span style={{ fontSize: 22, color: color.muted }}>{PRODUCT.requirement}</span>
          </div>
        </Lockup>
      </div>

      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center' }}>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 30,
            opacity: promptIn,
            transform: `translateY(${mix(0, 330, lift)}px) scale(${mix(1, 0.6, lift)})`,
          }}
        >
          <div
            className="font-mono"
            style={{
              padding: '30px 44px',
              borderRadius: 22,
              fontSize: 56,
              fontWeight: 500,
              backgroundColor: alpha(color.surface, 94),
              border: `1px solid ${alpha(color.cyan, mix(22, 70, press))}`,
              boxShadow: `0 40px 100px ${alpha(color.shadow, 16)}, 0 0 ${mix(50, 130, press)}px ${alpha(color.cyan, mix(10, 34, press))}`,
            }}
          >
            <PromptLine text={PRODUCT.install} frame={frame} from={TYPE[0]} to={TYPE[1]} showCursor={frame < ENTER_AT} />
          </div>
          <Keycap pressed={press} size={34}>
            <ReturnIcon size={38} strokeWidth={2.2} />
          </Keycap>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
