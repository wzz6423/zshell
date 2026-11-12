import { Easing, interpolate, spring, type SpringConfig } from 'remotion';

export const SPRING = {
  smooth: { damping: 200, mass: 1, stiffness: 100 },
  snappy: { damping: 26, mass: 0.8, stiffness: 190 },
  bouncy: { damping: 13, mass: 0.9, stiffness: 150 },
  camera: { damping: 34, mass: 1.4, stiffness: 70 },
} satisfies Record<string, Partial<SpringConfig>>;

const EASE = Easing.bezier(0.22, 1, 0.36, 1);

export const ramp = (
  frame: number,
  input: readonly [number, number],
  output: readonly [number, number] = [0, 1],
  easing: (t: number) => number = EASE,
) =>
  interpolate(frame, input, output, {
    easing,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

export const linear = (
  frame: number,
  input: readonly [number, number],
  output: readonly [number, number] = [0, 1],
) => ramp(frame, input, output, Easing.linear);

export const pop = (
  frame: number,
  fps: number,
  delay = 0,
  config: Partial<SpringConfig> = SPRING.snappy,
) => spring({ frame: frame - delay, fps, config });

// Visible between `from` and `to`, with a short ease on both edges.
export const during = (frame: number, from: number, to: number, edge = 18) =>
  Math.min(ramp(frame, [from, from + edge]), ramp(frame, [to - edge, to], [1, 0]));

export type Keyframe = { at: number; to: number; config?: Partial<SpringConfig> };

// Each keyframe adds a spring from the previous target to its own, so a move
// that starts before the last one settled blends instead of snapping.
export const track = (frame: number, fps: number, initial: number, keyframes: Keyframe[]) => {
  let value = initial;
  let previous = initial;
  for (const keyframe of keyframes) {
    const progress = spring({
      frame: frame - keyframe.at,
      fps,
      config: keyframe.config ?? SPRING.camera,
    });
    value += (keyframe.to - previous) * progress;
    previous = keyframe.to;
  }
  return value;
};

export const mix = (from: number, to: number, progress: number) => from + (to - from) * progress;
