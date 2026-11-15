export interface SpringSpec {
  readonly responseSec: number;
  readonly dampingFraction: number;
  readonly durationMs: number;
}

export const APPLE_SPRINGS = {
  snappy: { responseSec: 0.26, dampingFraction: 0.94, durationMs: 280 },
  control: { responseSec: 0.24, dampingFraction: 0.86, durationMs: 280 },
  reveal: { responseSec: 0.34, dampingFraction: 0.86, durationMs: 380 },
  glassLens: { responseSec: 0.20, dampingFraction: 0.88, durationMs: 220 },
  stack: { responseSec: 0.38, dampingFraction: 0.84, durationMs: 420 },
  orbBounce: { responseSec: 0.30, dampingFraction: 0.68, durationMs: 360 },
} as const satisfies Readonly<Record<string, SpringSpec>>;

const round2 = (n: number): number => Math.round(n * 100) / 100;
const round3 = (n: number): number => Math.round(n * 1000) / 1000;
const round4 = (n: number): number => Math.round(n * 10000) / 10000;

export function sampleSpringProgress(spec: SpringSpec, steps = 17): readonly number[] {
  const count = Math.max(1, Math.trunc(steps));
  if (count === 1) return [1];
  if (spec.responseSec <= 0 || spec.durationMs <= 0) return [0, ...new Array<number>(count - 1).fill(1)];
  const omega0 = (2 * Math.PI) / spec.responseSec;
  const zeta = Math.max(0.01, Math.min(2, spec.dampingFraction));
  const totalSec = spec.durationMs / 1000;
  const samples: number[] = new Array<number>(count);
  samples[0] = 0;
  samples[count - 1] = 1;
  for (let i = 1; i < count - 1; i += 1) {
    const t = (totalSec * i) / (count - 1);
    let x: number;
    if (zeta < 1) {
      const omegaD = omega0 * Math.sqrt(1 - zeta * zeta);
      x = 1 - Math.exp(-zeta * omega0 * t) * (Math.cos(omegaD * t) + ((zeta * omega0) / omegaD) * Math.sin(omegaD * t));
    } else if (zeta === 1) {
      x = 1 - Math.exp(-omega0 * t) * (1 + omega0 * t);
    } else {
      const s = Math.sqrt(zeta * zeta - 1), r1 = -omega0 * (zeta - s), r2 = -omega0 * (zeta + s);
      x = 1 - (r2 * Math.exp(r1 * t) - r1 * Math.exp(r2 * t)) / (r2 - r1);
    }
    samples[i] = round4(x);
  }
  return samples;
}

export function formatSpringCssLinear(spec: SpringSpec, steps = 17): string {
  return `linear(${sampleSpringProgress(spec, steps).join(", ")})`;
}

export function buildSpringTranslateKeyframes(fromDx: number, fromDy: number, spec: SpringSpec, steps = 17): Keyframe[] {
  const progress = sampleSpringProgress(spec, steps), last = progress.length - 1;
  return progress.map((p, idx) =>
    idx === last
      ? { transform: "translate3d(0px, 0px, 0)" }
      : { transform: `translate3d(${round2(fromDx * (1 - p))}px, ${round2(fromDy * (1 - p))}px, 0)` },
  );
}

export function buildSpringSurfaceKeyframes(options: {
  readonly tx: number;
  readonly ty: number;
  readonly fromScale?: number;
  readonly direction?: "enter" | "exit";
  readonly spec: SpringSpec;
  readonly steps?: number;
}): Keyframe[] {
  const fromScale = Math.max(0.5, options.fromScale ?? 0.94);
  const progress = sampleSpringProgress(options.spec, options.steps ?? 17), last = progress.length - 1;
  const tx = round2(options.tx), ty = round2(options.ty);
  if (options.direction === "exit") {
    return progress.map((p, idx) => {
      if (idx === 0) return { opacity: 1, transform: "translate3d(0px, 0px, 0) scale(1)" };
      if (idx === last) return { opacity: 0, transform: `translate3d(${tx}px, ${ty}px, 0) scale(${fromScale})` };
      const opacity = round3(Math.max(0, Math.min(1, 1 - Math.max(0, Math.min(1, p)) * 1.1)));
      return { opacity, transform: `translate3d(${round2(tx * p)}px, ${round2(ty * p)}px, 0) scale(${round4(1 - (1 - fromScale) * p)})` };
    });
  }
  return progress.map((p, idx) => {
    if (idx === 0) return { opacity: 0, transform: `translate3d(${tx}px, ${ty}px, 0) scale(${fromScale})` };
    if (idx === last) return { opacity: 1, transform: "translate3d(0px, 0px, 0) scale(1)" };
    const rem = 1 - p, opacity = round3(Math.max(0, Math.min(1, p * 1.15)));
    return { opacity, transform: `translate3d(${round2(tx * rem)}px, ${round2(ty * rem)}px, 0) scale(${round4(fromScale + (1 - fromScale) * p)})` };
  });
}

export function buildOrbBounceKeyframes(spec: SpringSpec = APPLE_SPRINGS.orbBounce, steps = 17): Keyframe[] {
  const progress = sampleSpringProgress(spec, steps), count = progress.length;
  const omega0 = (2 * Math.PI) / Math.max(0.05, spec.responseSec);
  const zeta = Math.max(0.01, Math.min(0.99, spec.dampingFraction));
  const omegaD = omega0 * Math.sqrt(1 - zeta * zeta), totalSec = spec.durationMs / 1000;
  return progress.map((p, idx) => {
    if (idx === 0) return { transform: "scale(0.92)" };
    if (idx === count - 1) return { transform: "scale(1)" };
    const t = (totalSec * idx) / (count - 1);
    const impulse = 0.22 * Math.exp(-zeta * omega0 * t) * Math.sin(omegaD * t);
    return { transform: `scale(${round4(0.92 + 0.08 * p + impulse)})` };
  });
}
