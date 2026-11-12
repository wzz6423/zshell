import { AbsoluteFill, random, useCurrentFrame, useVideoConfig } from 'remotion';
import { alpha, color } from '../theme';

const GRID = 64;
const COUNT = 240;

// Rise speed, sway and soft falloff follow the website's ambient particles
// (web/src/components/site-particles.tsx). Seeded once at module scope: every
// frame and every render pass draws the same field, only the drift changes
// with time.
const PARTICLES = Array.from({ length: COUNT }, (_, index) => ({
  x: random(`promo-particle-x-${index}`),
  // Share of the frame height a particle climbs before it is gone. Weighted low,
  // which keeps the field dense at the floor for the whole video: one that merely
  // wrapped around would be spread evenly within seconds.
  rise: 0.18 + 0.62 * Math.pow(random(`promo-particle-rise-${index}`), 1.6),
  near: random(`promo-particle-depth-${index}`),
  offset: random(`promo-particle-offset-${index}`),
  // Frame heights per second, inside the website's 0.012–0.021 range.
  speed: 0.012 + random(`promo-particle-speed-${index}`) * 0.009,
  sway: 0.32 + random(`promo-particle-sway-${index}`) * 0.24,
  phase: random(`promo-particle-phase-${index}`) * Math.PI * 2,
}));

// One backdrop spans every scene so cuts between them never flash the grid.
export const Backdrop = () => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const seconds = frame / fps;

  return (
    <AbsoluteFill style={{ backgroundColor: color.ink }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(ellipse 90% 60% at 50% -10%, ${alpha(color.surface, 85)}, transparent 70%)`,
        }}
      />

      <AbsoluteFill>
        {PARTICLES.map((particle, index) => {
          // Constant screen size, like the website: depth reads through opacity.
          const size = 9;
          const travel = particle.rise * height;
          const life = (particle.offset + (seconds * particle.speed * height) / travel) % 1;
          const drift = (particle.x + seconds * 0.0048) % 1;
          // Zero at both ends of a life, so the jump back to the floor is never seen.
          const fade = Math.min(1, life / 0.08) * Math.pow(1 - life, 1.4);
          const strength = (30 + particle.near * 36) * fade;
          return (
            <span
              key={index}
              style={{
                position: 'absolute',
                left: drift * width - size / 2 + Math.sin(seconds * particle.sway + particle.phase) * (8 + particle.near * 10),
                top: height - life * travel,
                width: size,
                height: size,
                // The website's sprite is a soft radial falloff, not a hard dot.
                background: `radial-gradient(circle closest-side, ${alpha(color.blue, strength)} 0%, ${alpha(color.blue, strength * 0.45)} 45%, transparent 100%)`,
              }}
            />
          );
        })}
      </AbsoluteFill>

      <AbsoluteFill
        style={{
          backgroundImage: `linear-gradient(${alpha(color.shadow, 6)} 1px, transparent 1px), linear-gradient(90deg, ${alpha(color.shadow, 6)} 1px, transparent 1px)`,
          backgroundSize: `${GRID}px ${GRID}px`,
          backgroundPosition: `${(frame * 0.08) % GRID}px ${(frame * 0.05) % GRID}px`,
          maskImage: 'radial-gradient(ellipse 75% 70% at 50% 45%, black 20%, transparent 100%)',
        }}
      />
    </AbsoluteFill>
  );
};
