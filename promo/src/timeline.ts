export const FPS = 60;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const SCENES = {
  awakening: { from: 0, duration: 420 },
  workflow: { from: 420, duration: 780 },
  underTheHood: { from: 1200, duration: 840 },
  bentoGrid: { from: 2040, duration: 540 },
  outro: { from: 2580, duration: 420 },
} as const;

export const TOTAL_FRAMES = SCENES.outro.from + SCENES.outro.duration;
