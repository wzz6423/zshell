import { CATALOG_SECONDS } from './scenes/catalog/timing';

export const FPS = 60;
export const WIDTH = 1920;
export const HEIGHT = 1080;

const CATALOG_FRAMES = Math.round(CATALOG_SECONDS * FPS);

// Total length: 100 seconds (6,000 frames at 60 fps).
export const SCENES = {
  awakening: { from: 0, duration: 300 },
  workflow: { from: 300, duration: 540 },
  underTheHood: { from: 840, duration: 660 },
  catalog: { from: 1500, duration: CATALOG_FRAMES },
  bentoGrid: { from: 1500 + CATALOG_FRAMES, duration: 540 },
  outro: { from: 2040 + CATALOG_FRAMES, duration: 360 },
} as const;

export const TOTAL_FRAMES = SCENES.outro.from + SCENES.outro.duration;
