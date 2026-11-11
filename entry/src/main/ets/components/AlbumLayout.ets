// Mosaic layout for media albums, in the spirit of the official clients:
// cells keep their aspect ratios as far as possible inside a bounded box.

export class Cell {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

export class AlbumBox {
  width: number = 0;
  height: number = 0;
  cells: Cell[] = [];
}

const GAP = 2;

function cell(x: number, y: number, w: number, h: number): Cell {
  const c = new Cell();
  c.x = x;
  c.y = y;
  c.w = w;
  c.h = h;
  return c;
}

// A tall first item on the left, the rest stacked in a column on the right.
function leftAndColumn(r: number[], maxW: number, maxH: number): AlbumBox {
  const n = r.length;
  let inv = 0;
  for (let i = 1; i < n; i++) {
    inv += 1 / r[i];
  }
  // Solve for equal heights on both sides: (W - GAP - wr) / r0 = wr * inv + GAP * (n - 2).
  let wr = ((maxW - GAP) / r[0] - GAP * (n - 2)) / (1 / r[0] + inv);
  wr = Math.min(Math.max(wr, maxW * 0.33), maxW * 0.5);
  const wl = maxW - GAP - wr;
  const h = Math.min(maxH, Math.max(wl / r[0], 120));
  const box = new AlbumBox();
  box.width = maxW;
  box.height = h;
  box.cells.push(cell(0, 0, wl, h));
  const free = h - GAP * (n - 2);
  let y = 0;
  for (let i = 1; i < n; i++) {
    const ch = i === n - 1 ? h - y : free * (1 / r[i]) / inv;
    box.cells.push(cell(wl + GAP, y, wr, ch));
    y += ch + GAP;
  }
  return box;
}

// Every way to split n items into consecutive rows of 1..4 items.
function compositions(n: number): number[][] {
  if (n === 0) {
    return [[]];
  }
  const out: number[][] = [];
  for (let k = 1; k <= Math.min(4, n); k++) {
    for (const rest of compositions(n - k)) {
      out.push([k].concat(rest));
    }
  }
  return out;
}

// Justified rows: each row fills the width at the height its ratios imply.
// Picks the row split whose total height is closest to the target, avoiding
// very thin rows and preferring fewer items in the upper rows.
function rows(r: number[], maxW: number, maxH: number): AlbumBox {
  const target = Math.min(maxH, maxW * 1.15);
  let best: number[] = [r.length];
  let bestHeights: number[] = [];
  let bestScore = Number.MAX_VALUE;
  for (const split of compositions(r.length)) {
    const heights: number[] = [];
    let i = 0;
    let total = GAP * (split.length - 1);
    let score = 0;
    for (const k of split) {
      let sum = 0;
      for (let j = 0; j < k; j++) {
        sum += r[i + j];
      }
      const h = (maxW - GAP * (k - 1)) / sum;
      heights.push(h);
      total += h;
      if (h < maxW * 0.22) {
        score += 400;
      }
      i += k;
    }
    for (let j = 1; j < split.length; j++) {
      if (split[j] < split[j - 1]) {
        score += 15;
      }
    }
    score += Math.abs(total - target);
    if (score < bestScore) {
      bestScore = score;
      best = split;
      bestHeights = heights;
    }
  }
  let total = GAP * (best.length - 1);
  for (const h of bestHeights) {
    total += h;
  }
  // Squeeze rows proportionally when the mosaic is taller than allowed.
  const scale = total > maxH ? (maxH - GAP * (best.length - 1)) / (total - GAP * (best.length - 1)) : 1;
  const box = new AlbumBox();
  box.width = maxW;
  let y = 0;
  let i = 0;
  best.forEach((k: number, row: number) => {
    const h = bestHeights[row] * scale;
    let sum = 0;
    for (let j = 0; j < k; j++) {
      sum += r[i + j];
    }
    let x = 0;
    for (let j = 0; j < k; j++) {
      const w = j === k - 1 ? maxW - x : (maxW - GAP * (k - 1)) * r[i + j] / sum;
      box.cells.push(cell(x, y, w, h));
      x += w + GAP;
    }
    y += h + GAP;
    i += k;
  });
  box.height = y - GAP;
  return box;
}

// ratios: width / height of each item (0 when unknown).
export function albumLayout(ratios: number[], maxW: number, maxH: number): AlbumBox {
  const r = ratios.map((v: number) => Math.min(Math.max(v || 1, 0.4), 2.5));
  if (r.length >= 3 && r.length <= 4 && r[0] < 0.8) {
    return leftAndColumn(r, maxW, maxH);
  }
  return rows(r, maxW, maxH);
}
