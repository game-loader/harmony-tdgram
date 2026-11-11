// Window layout rules, kept free of UI imports so they can be unit-tested
// (tools/test.mjs). All sizes are in vp.
//
// Split view (chat list | open chat) is tuned for Huawei Pura X Max: the
// unfolded inner screen (2584x1828 px) is landscape and roughly 800-860vp
// wide, so it splits; the cover screen (1264x1848 px, about 390vp wide)
// shows one pane at a time. Upright windows split only when really wide.

export const SPLIT_MIN_LANDSCAPE = 600;
export const SPLIT_MIN_PORTRAIT = 840;
export const LIST_MIN = 280;
export const DETAIL_MIN = 340;
const SNAP_DISTANCE = 22;

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

// mode: 'auto' | 'on' | 'off' (the user's setting).
export function isSplit(w: number, h: number, mode: string): boolean {
  if (mode === 'off' || w < LIST_MIN + DETAIL_MIN) {
    return false;
  }
  if (mode === 'on') {
    return true;
  }
  return w >= SPLIT_MIN_PORTRAIT || (w >= SPLIT_MIN_LANDSCAPE && w > h);
}

export function defaultListWidth(w: number): number {
  return clamp(Math.round(w * 0.38), 300, 400);
}

// Keeps both panes usable whatever width was saved or dragged to.
export function clampListWidth(w: number, wanted: number): number {
  const max = Math.max(LIST_MIN, Math.min(w - DETAIL_MIN, Math.round(w * 0.6)));
  return clamp(Math.round(wanted), LIST_MIN, max);
}

// Width of the list pane in split view. `saved` is the user's dragged width
// (0 = none).
export function listWidth(w: number, saved: number): number {
  return clampListWidth(w, saved > 0 ? saved : defaultListWidth(w));
}

// While dragging the divider: a position close to the fold's crease snaps
// to it, so the divider can sit exactly on the hinge. creaseX/creaseW
// describe a vertical crease inside the window; creaseW <= 0 means none.
export function snapListWidth(w: number, wanted: number, creaseX: number, creaseW: number): number {
  const clamped = clampListWidth(w, wanted);
  if (creaseW <= 0) {
    return clamped;
  }
  const center = creaseX + creaseW / 2;
  if (Math.abs(clamped - center) <= SNAP_DISTANCE && clampListWidth(w, center) === Math.round(center)) {
    return Math.round(center);
  }
  return clamped;
}

// ---- Sizes inside a chat pane of the given width ----

export function bubbleMaxWidth(paneW: number): number {
  return Math.round(clamp(paneW * 0.82, 220, 560));
}

// Photos, videos, albums and other fixed-width content.
export function mediaWidth(paneW: number): number {
  return Math.round(clamp(paneW * 0.64, 200, 340));
}

export function mediaMaxHeight(paneH: number): number {
  return Math.round(clamp(paneH * 0.55, 200, 380));
}

export function stickerSide(paneW: number): number {
  return Math.round(clamp(paneW * 0.42, 120, 190));
}

// Number of columns of `cell`-wide items that fit, within [min, max].
export function columnsFor(paneW: number, cell: number, min: number, max: number): number {
  return clamp(Math.floor(paneW / cell), min, max);
}

// Height of the emoji/sticker panel: it must leave room for messages on
// short windows (the unfolded screen held sideways is only about 560vp tall).
export function panelHeight(paneH: number): number {
  return Math.round(clamp(paneH * 0.42, 150, 300));
}

// Centered column for forms and settings on wide panes.
export function contentWidth(paneW: number): number {
  return Math.min(paneW, 640);
}
