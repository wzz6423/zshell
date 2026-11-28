// 8 focused chapters × 2 steps × 3.75 seconds = 60 seconds (3,600 frames at 60 fps).
// Running steps in native 60 fps frames (225 frames each) avoids time-warping and
// end-of-step freezes while keeping every state readable.
export const STEP_SECONDS = 3.75;
export const CHAPTER_STEP_COUNTS = [2, 2, 2, 2, 2, 2, 2, 2] as const;
export const CATALOG_SECONDS =
  STEP_SECONDS * CHAPTER_STEP_COUNTS.reduce((total, count) => total + count, 0);
