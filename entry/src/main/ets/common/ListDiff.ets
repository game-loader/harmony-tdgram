// Turns "old list -> new list" into the add/delete/change notifications a
// lazily rendered list needs. Reporting what moved (instead of reloading)
// lets the list keep the reading position when older messages are inserted
// above. No UI imports: unit-tested by tools/test.mjs.

export const OP_ADD = 0;
export const OP_DELETE = 1;
export const OP_CHANGE = 2;

export class DiffOp {
  type: number = OP_ADD;
  index: number = 0;

  constructor(type: number, index: number) {
    this.type = type;
    this.index = index;
  }
}

// ids identify items; keys change when an item's content changes. The ops
// are to be applied in order, each index referring to the list as it is at
// that moment. Returns null when surviving items changed their relative
// order: the caller reloads the whole list then.
export function diffLists(oldIds: number[], oldKeys: string[], newIds: number[], newKeys: string[]): DiffOp[] | null {
  const ops: DiffOp[] = [];
  const inNew = new Set<number>(newIds);
  const kept: number[] = [];
  const keptKeys: string[] = [];
  // Deletions from the end, so earlier indices stay valid.
  for (let i = oldIds.length - 1; i >= 0; i--) {
    if (inNew.has(oldIds[i])) {
      kept.unshift(oldIds[i]);
      keptKeys.unshift(oldKeys[i]);
    } else {
      ops.push(new DiffOp(OP_DELETE, i));
    }
  }
  let j = 0;
  for (let i = 0; i < newIds.length; i++) {
    if (j < kept.length && kept[j] === newIds[i]) {
      if (keptKeys[j] !== newKeys[i]) {
        ops.push(new DiffOp(OP_CHANGE, i));
      }
      j++;
    } else {
      ops.push(new DiffOp(OP_ADD, i));
    }
  }
  return j === kept.length ? ops : null;
}
