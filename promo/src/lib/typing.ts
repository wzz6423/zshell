import { random } from 'remotion';

const PAUSE_AFTER = new Set([' ', '-', ',', '"', '/']);

// Fits the whole string between `from` and `to` while letting individual
// keystrokes vary, so the rhythm reads as a hand rather than a metronome.
// Seeded by the text: every render of a frame types the same characters.
export const typedLength = (text: string, frame: number, from: number, to: number) => {
  if (frame <= from) return 0;
  if (frame >= to) return text.length;

  const weights = Array.from(text, (char, index) => {
    const jitter = 0.55 + random(`${text}:${index}`) * 0.9;
    return PAUSE_AFTER.has(text[index - 1] ?? '') ? jitter * 1.7 : jitter;
  });
  const total = weights.reduce((sum, weight) => sum + weight, 0);
  const budget = ((frame - from) / (to - from)) * total;

  let spent = 0;
  for (let index = 0; index < weights.length; index++) {
    spent += weights[index];
    if (spent > budget) return index;
  }
  return text.length;
};

// Solid while keys are landing, blinking once the line is at rest.
export const cursorOpacity = (frame: number, typing: boolean) =>
  typing || frame % 60 < 34 ? 1 : 0.12;
