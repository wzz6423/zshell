export const DEMO_SECONDS = 4;
export const CHAPTER_STEP_COUNTS = [4, 4, 4, 4, 4, 4, 4, 5, 4, 4] as const;
export const CATALOG_SECONDS = DEMO_SECONDS * CHAPTER_STEP_COUNTS.reduce((total, count) => total + count, 0);
