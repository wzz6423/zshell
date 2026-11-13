import { CATALOG_SECONDS } from './scenes/catalog/timing';

export const FPS = 60;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const SCENES = {
  awakening: { from: 0, duration: 300 },
  workflow: { from: 300, duration: 600 },
  underTheHood: { from: 900, duration: 720 },
  catalog: { from: 1620, duration: CATALOG_SECONDS * FPS },
  bentoGrid: { from: 1620 + CATALOG_SECONDS * FPS, duration: 420 },
  outro: { from: 2040 + CATALOG_SECONDS * FPS, duration: 360 },
} as const;

export const TOTAL_FRAMES = SCENES.outro.from + SCENES.outro.duration;
