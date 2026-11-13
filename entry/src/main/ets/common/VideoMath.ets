// Arithmetic of the video player: seeking, tap zones, speeds and resume
// positions. No UI imports: unit-tested by tools/test.mjs.

export const SEEK_STEP = 10;  // seconds skipped by a double tap or the ±10 buttons
export const SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3];
const RESUME_MIN = 5;         // seconds: closer to either end the video starts over

// Target of a relative seek, kept inside the video.
export function seekTarget(time: number, delta: number, duration: number): number {
  const t = time + delta;
  if (duration <= 0) {
    return Math.max(0, t);
  }
  return Math.min(Math.max(0, t), Math.max(0, duration - 0.5));
}

// Which third of the picture a tap hit: -1 left, 0 middle, 1 right.
export function tapZone(x: number, width: number): number {
  if (width <= 0) {
    return 0;
  }
  const f = x / width;
  return f < 1 / 3 ? -1 : (f > 2 / 3 ? 1 : 0);
}

// Speed used while the picture is held down: twice the chosen speed's
// neighbourhood, at least 2x, at most 3x.
export function boostSpeed(speed: number): number {
  return speed >= 2 ? 3 : 2;
}

// Closest supported speed, for values saved by older versions or typed in.
export function normalizeSpeed(speed: number): number {
  let best = 1;
  for (const s of SPEEDS) {
    if (Math.abs(s - speed) < Math.abs(best - speed)) {
      best = s;
    }
  }
  return best;
}

export function speedLabel(speed: number): string {
  return `${speed}×`;
}

// Where to continue a video that was left at `saved` seconds; 0 starts over.
export function resumeAt(saved: number, duration: number): number {
  if (!(saved >= RESUME_MIN) || (duration > 0 && saved > duration - RESUME_MIN)) {
    return 0;
  }
  return saved;
}

// 75 -> "1:15", 3725 -> "1:02:05".
export function clock(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  const pad = (n: number): string => (n < 10 ? '0' : '') + n;
  if (s >= 3600) {
    return `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  }
  return `${Math.floor(s / 60)}:${pad(s % 60)}`;
}

// Screen brightness after a vertical drag of `dy` vp (up is negative) over
// a picture `height` vp tall, starting from `from` (0..1).
export function dragBrightness(from: number, dy: number, height: number): number {
  if (height <= 0) {
    return from;
  }
  return Math.min(1, Math.max(0.02, from - dy / height));
}
