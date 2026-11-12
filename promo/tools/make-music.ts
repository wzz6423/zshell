/**
 * Synthesises the launch film's score as a 48 kHz stereo WAV.
 *
 * Synthesised voices keep the score independent of third-party samples.
 * The 132 BPM groove restarts on each scene cut to preserve the visual anchors.
 *
 * `bun run make:music` writes out/score.wav; the committed MP3 in
 * public/audio/ is that file through ffmpeg (see README).
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { FPS, TOTAL_FRAMES } from '../src/timeline';

const SR = 48_000;
const DURATION = TOTAL_FRAMES / FPS;
const TOTAL = SR * DURATION;
const BPM = 132;
const BEAT = 60 / BPM;
const BAR = BEAT * 4;

const left = new Float64Array(TOTAL);
const right = new Float64Array(TOTAL);
const musicLeft = new Float64Array(TOTAL);
const musicRight = new Float64Array(TOTAL);
const kickTimes: number[] = [];

/** Seeded so a regenerated bed is byte-identical. */
let seed = 0x9e3779b9;
const noise = () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return (((t ^ (t >>> 14)) >>> 0) / 4294967296) * 2 - 1;
};

const hz = (midi: number) => 440 * 2 ** ((midi - 69) / 12);
const at = (seconds: number) => Math.round(seconds * SR);
const write = (index: number, l: number, r: number, musical = false) => {
  if (index < 0 || index >= TOTAL) return;
  (musical ? musicLeft : left)[index] += l;
  (musical ? musicRight : right)[index] += r;
};

const panGain = (pan: number) => {
  const angle = ((pan + 1) * Math.PI) / 4;
  return [Math.cos(angle), Math.sin(angle)] as const;
};

type Wave = 'pad' | 'pluck' | 'bass' | 'stab' | 'lead';

const HARMONICS: Record<Wave, number[]> = {
  pad: [1, 0.3, 0.1],
  pluck: [1, 0.5, 0.25, 0.1],
  bass: [1, 0.55, 0.28, 0.12, 0.05],
  stab: [1, 0.62, 0.35, 0.2, 0.1, 0.04],
  lead: [1, 0.46, 0.2, 0.07],
};

const tone = (
  start: number,
  dur: number,
  freq: number | ((t: number) => number),
  amp: number,
  env: (t: number) => number,
  wave: Wave,
  pan = 0,
  detune = 0,
) => {
  const first = at(start);
  const samples = Math.max(1, Math.round(dur * SR));
  const [gl, gr] = panGain(pan);
  const partials = HARMONICS[wave];
  let phase = 0;
  for (let i = 0; i < samples; i++) {
    const t = i / SR;
    const base = (typeof freq === 'function' ? freq(t) : freq) * (1 + detune);
    phase += (2 * Math.PI * base) / SR;
    let s = 0;
    for (let h = 0; h < partials.length; h++) {
      const brightness = wave === 'stab' || wave === 'bass' ? Math.exp(-h * t * 9) : 1;
      s += partials[h] * brightness * Math.sin(phase * (h + 1));
    }
    s *= env(t) * amp;
    write(first + i, s * gl, s * gr, true);
    if (wave === 'lead' || wave === 'pluck') {
      write(first + i + at(BEAT * 0.75), s * gr * 0.2, s * gl * 0.2, true);
      write(first + i + at(BEAT * 1.5), s * gl * 0.08, s * gr * 0.08, true);
    }
  }
};

/** White noise through `passes` first differences; each pass tilts it brighter. */
const noiseBurst = (start: number, dur: number, amp: number, env: (t: number) => number, passes: 1 | 2, pan = 0) => {
  const first = at(start);
  const samples = Math.max(1, Math.round(dur * SR));
  const [gl, gr] = panGain(pan);
  let a = 0;
  let b = 0;
  for (let i = 0; i < samples; i++) {
    const raw = noise();
    let x = raw - a;
    a = raw;
    if (passes === 2) {
      const once = x;
      x = once - b;
      b = once;
    }
    const s = x * env(i / SR) * amp;
    write(first + i, s * gl, s * gr);
  }
};

const decay = (tau: number) => (t: number) => Math.exp(-t / tau);
const soft = (tau: number, attack = 0.005) => (t: number) => Math.min(1, t / attack) * Math.exp(-t / tau);
const hold = (attack: number, release: number, dur: number) => (t: number) =>
  Math.min(1, t / attack) * Math.min(1, Math.max(0, dur - t) / release);

// ── Voices ────────────────────────────────────────────────────────────────

/** Detuned in opposite directions per side, which is where the width comes from. */
const pad = (start: number, notes: number[], dur: number, amp: number) => {
  const env = hold(0.12, Math.min(0.7, dur * 0.4), dur);
  for (const note of notes) {
    tone(start, dur, hz(note), amp, env, 'pad', -0.45, 0.0016);
    tone(start, dur, hz(note), amp, env, 'pad', 0.45, -0.0016);
  }
};

const bass = (start: number, note: number, dur: number, amp: number) =>
  tone(start, dur, hz(note), amp, hold(0.004, Math.min(0.07, dur * 0.35), dur), 'bass');

const pluck = (start: number, note: number, amp: number, pan: number, tau = 0.35) =>
  tone(start, tau * 5, hz(note), amp, soft(tau), 'pluck', pan);

const kick = (start: number, amp: number) => {
  kickTimes.push(start);
  const first = at(start);
  const samples = at(0.3);
  const [gl, gr] = panGain(0);
  let previous = 0;
  let phase = 0;
  for (let i = 0; i < samples; i++) {
    const t = i / SR;
    const freq = 48 + 145 * Math.exp(-t / 0.027);
    phase += (2 * Math.PI * freq) / SR;
    const body = Math.sin(phase) * Math.exp(-t / 0.13) * Math.min(1, t / 0.002);
    const raw = noise();
    const click = (raw - previous) * Math.exp(-t / 0.006) * 0.16;
    previous = raw;
    const s = (body + click) * amp;
    write(first + i, s * gl, s * gr);
  }
};

const hat = (start: number, amp: number, pan: number, open = false) =>
  noiseBurst(start, open ? 0.18 : 0.045, amp, decay(open ? 0.065 : 0.014), 1, pan);

const clap = (start: number, amp: number) => {
  for (const offset of [0, 0.009, 0.019]) noiseBurst(start + offset, 0.045, amp * 0.55, decay(0.016), 1);
  noiseBurst(start + 0.02, 0.15, amp, decay(0.06), 1);
  tone(start, 0.12, 185, amp * 0.5, soft(0.032, 0.001), 'pad');
};

/** Noise and a rising sine, released just before the peak so the next hit lands clean. */
const riser = (start: number, dur: number, amp: number) => {
  const env = (t: number) => Math.min(1, (dur - t) / 0.03) * (t / dur) ** 2.2;
  noiseBurst(start, dur, amp, env, 2);
  tone(start, dur, (t) => 180 + 620 * (t / dur), amp * 1.4, env, 'pad');
};

const impact = (start: number, amp: number) => {
  tone(start, 1.1, (t) => 36 + 70 * Math.exp(-t / 0.05), amp, soft(0.42, 0.004), 'bass');
  noiseBurst(start, 0.5, amp * 0.25, decay(0.16), 1);
  hat(start, amp * 0.12, 0);
};

const shimmer = (start: number, notes: number[], amp: number) => {
  notes.forEach((note, index) => tone(start, 2.2, hz(note), amp, soft(0.7), 'pluck', index % 2 ? 0.5 : -0.5));
};

const tick = (start: number, note: number, amp: number) => tone(start, 0.4, hz(note), amp, soft(0.05, 0.002), 'pluck', 0.2);

// ── Harmony ───────────────────────────────────────────────────────────────
// Am – F – C – G; each scene starts a fresh phrase on its cut.
const CHORDS = [
  { notes: [57, 60, 64], root: 45, arp: [69, 72, 76] },
  { notes: [53, 57, 60], root: 41, arp: [65, 69, 72] },
  { notes: [55, 60, 64], root: 48, arp: [67, 72, 76] },
  { notes: [55, 59, 62], root: 43, arp: [67, 71, 74] },
];
const chord = (time: number, origin = 0) => CHORDS[Math.floor((time - origin) / BAR + 1e-9) % 4];

/** Steps through the chord tones on a grid: up, up, up, back. */
const arp = (from: number, to: number, step: number, amp: number, octave = 0, tau = 0.13) => {
  for (let k = 0; from + k * step < to; k++) {
    const time = from + k * step;
    pluck(time, chord(time).arp[[0, 1, 2, 1][k % 4]] + octave, amp, k % 2 ? 0.35 : -0.35, tau);
  }
};

const stab = (start: number, notes: number[], amp: number) => {
  for (const [index, note] of notes.entries()) {
    tone(start, BEAT * 0.7, hz(note + 12), amp, soft(0.065, 0.004), 'stab', (index - 1) * 0.35);
  }
};

const HOOK = [76, 0, 81, 79, 76, 74, 72, 74, 76, 0, 79, 81, 84, 81, 79, 76];
const hook = (from: number, to: number, amp: number, step = BEAT / 2) => {
  for (let k = 0; from + k * step < to; k++) {
    const note = HOOK[k % HOOK.length];
    if (note) tone(from + k * step, BEAT * 0.8, hz(note), amp, soft(0.095, 0.006), 'lead', k % 2 ? 0.2 : -0.2);
  }
};

const groove = (from: number, to: number, strength: number) => {
  for (let k = 0; from + k * BEAT < to; k++) {
    const time = from + k * BEAT;
    const harmony = chord(time, from);
    kick(time, (k % 4 === 0 ? 0.7 : 0.62) * strength);
    if (k % 2 === 1) clap(time, 0.13 * strength);
    if (time + BEAT / 2 < to) {
      bass(time + BEAT / 2, harmony.root + (k % 4 === 3 ? 12 : 0), BEAT * 0.43, 0.32 * strength);
      hat(time + BEAT / 2, 0.055 * strength, k % 2 ? 0.3 : -0.3, true);
      stab(time + BEAT / 2, harmony.notes, 0.055 * strength);
    }
    for (const fraction of [0.25, 0.75]) {
      if (time + BEAT * fraction < to) hat(time + BEAT * fraction, 0.028 * strength, fraction === 0.25 ? -0.45 : 0.45);
    }
  }
};

const fill = (end: number) => {
  for (let k = 0; k < 8; k++) {
    const time = end - BEAT * 2 + k * BEAT / 4;
    clap(time, 0.035 + k * 0.009);
    hat(time + BEAT / 8, 0.035, k % 2 ? 0.3 : -0.3);
  }
};

// ── Arrangement ───────────────────────────────────────────────────────────
// Every anchor below is a frame in src/scenes, converted to seconds.

// The intro builds from a short hook into the window reveal.
impact(0, 0.2);
pad(0, CHORDS[0].notes, 2.4, 0.035);
arp(0.5, 4.07, BEAT / 2, 0.035);
riser(2.87, 1.2, 0.03);
impact(4.07, 0.3);
groove(4.07, 6.7, 0.6);
shimmer(5.35, [81, 88], 0.025);
riser(5.8, 1.2, 0.035);
fill(7);

groove(7, 20, 0.92);
hook(7 + BAR, 18.7, 0.085);
riser(18.2, 1.8, 0.035);
fill(20);

// Keep the pulse under the architecture chapters, with less lead density.
groove(20, 34, 0.82);
hook(20 + BAR, 32.8, 0.055, BEAT);
riser(32.2, 1.8, 0.04);
fill(34);

groove(34, 43, 1);
hook(34, 40, 0.1);
hook(40, 42.75, 0.075, BEAT / 4);
riser(40.8, 2.2, 0.045);
fill(43);

// Carry the groove through the install command, then resolve on the logo.
groove(43, 45.13, 0.78);
hook(43, 45.1, 0.07);
impact(45.13, 0.16);
tick(45.13, 93, 0.045);
impact(45.8, 0.32);
pad(45.8, [45, 57, 60, 64], 3.8, 0.065);
bass(45.8, 45, 1, 0.16);
shimmer(45.8, [81, 88, 93], 0.055);
shimmer(46.73, [81, 88], 0.025);

// ── Master ────────────────────────────────────────────────────────────────
// A short fade in avoids a click; the two-stage tail leaves the file silent at 50 s.
const master = (t: number) =>
  Math.min(1, t / 0.12) * Math.exp(-Math.max(0, t - 46.5) / 1.8) * Math.min(1, Math.max(0, 49.8 - t) / 1.2);

let rawPeak = 0;
let peak = 0;
const kicks = kickTimes.map(at).sort((a, b) => a - b);
let kickIndex = 0;
let lastKick = -SR;
for (let i = 0; i < TOTAL; i++) {
  while (kickIndex < kicks.length && kicks[kickIndex] <= i) lastKick = kicks[kickIndex++];
  // Duck only the synth bus so every kick retains a clear transient.
  const duck = 1 - 0.6 * Math.exp(-(i - lastKick) / (SR * 0.075));
  left[i] += musicLeft[i] * duck;
  right[i] += musicRight[i] * duck;
  const gain = master(i / SR);
  rawPeak = Math.max(rawPeak, Math.abs(left[i] * gain), Math.abs(right[i] * gain));
  // tanh rounds the kick-plus-bass peaks off instead of letting them clip.
  left[i] = Math.tanh(left[i] * gain);
  right[i] = Math.tanh(right[i] * gain);
  peak = Math.max(peak, Math.abs(left[i]), Math.abs(right[i]));
}

const headroom = 0.85 / (peak || 1);
const pcm = Buffer.alloc(44 + TOTAL * 4);
pcm.write('RIFF', 0);
pcm.writeUInt32LE(36 + TOTAL * 4, 4);
pcm.write('WAVE', 8);
pcm.write('fmt ', 12);
pcm.writeUInt32LE(16, 16);
pcm.writeUInt16LE(1, 20);
pcm.writeUInt16LE(2, 22);
pcm.writeUInt32LE(SR, 24);
pcm.writeUInt32LE(SR * 4, 28);
pcm.writeUInt16LE(4, 32);
pcm.writeUInt16LE(16, 34);
pcm.write('data', 36);
pcm.writeUInt32LE(TOTAL * 4, 40);
for (let i = 0; i < TOTAL; i++) {
  pcm.writeInt16LE(Math.round(left[i] * headroom * 32767), 44 + i * 4);
  pcm.writeInt16LE(Math.round(right[i] * headroom * 32767), 46 + i * 4);
}

const out = resolve(process.argv[2] ?? 'out/score.wav');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, pcm);
console.log(
  `wrote ${out} · ${DURATION} s · ${BPM} BPM · 48 kHz stereo · mix peak ${rawPeak.toFixed(2)} · output peak ${(20 * Math.log10(peak * headroom)).toFixed(2)} dBFS · ${(pcm.length / 1e6).toFixed(1)} MB`,
);
