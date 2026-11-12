import { CATALOG_SECONDS } from './scenes/catalog/timing';

export const FPS = 60;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const SCENES = {
  awakening: { from: 0, duration: 420 },
  workflow: { from: 420, duration: 780 },
  underTheHood: { from: 1200, duration: 840 },
  catalog: { from: 2040, duration: CATALOG_SECONDS * FPS },
  bentoGrid: { from: 2040 + CATALOG_SECONDS * FPS, duration: 540 },
  outro: { from: 2580 + CATALOG_SECONDS * FPS, duration: 420 },
} as const;

export const TOTAL_FRAMES = SCENES.outro.from + SCENES.outro.duration;
