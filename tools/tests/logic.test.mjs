import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const load = (name) => require(path.join(process.env.TDGRAM_OUT, name + '.cjs'));
const L = load('Layout');
const { Nav } = load('Nav');
const D = load('ListDiff');
const T = load('Tags');
const A = load('AlbumLayout');

// ---- Layout ----

test('split view: Pura X Max inner screen splits, cover screen does not', () => {
  assert.equal(L.isSplit(830, 587, 'auto'), true);   // unfolded, landscape
  assert.equal(L.isSplit(587, 830, 'auto'), false);  // unfolded, held upright
  assert.equal(L.isSplit(395, 577, 'auto'), false);  // cover screen
  assert.equal(L.isSplit(900, 1200, 'auto'), true);  // large tablet upright
});

test('split view: the setting overrides the rule, but never below a usable width', () => {
  assert.equal(L.isSplit(830, 587, 'off'), false);
  assert.equal(L.isSplit(650, 900, 'on'), true);
  assert.equal(L.isSplit(395, 577, 'on'), false);
});

test('list width: default, saved and clamped', () => {
  assert.equal(L.listWidth(830, 0), 315);
  assert.equal(L.listWidth(830, 360), 360);
  assert.equal(L.listWidth(830, 100), L.LIST_MIN);
  // Both panes stay usable however far the divider was dragged.
  const w = L.listWidth(830, 800);
  assert.ok(w <= 830 - L.DETAIL_MIN && w <= 830 * 0.6 + 1, `got ${w}`);
  assert.ok(L.listWidth(630, 600) >= L.LIST_MIN);
});

test('divider snaps to the crease only when close to it', () => {
  // Vertical crease in the middle of an 830vp window.
  assert.equal(L.snapListWidth(830, 405, 407, 16), 415);
  assert.equal(L.snapListWidth(830, 430, 407, 16), 415);
  assert.equal(L.snapListWidth(830, 350, 407, 16), 350);
  assert.equal(L.snapListWidth(830, 405, 0, 0), 405);
});

test('pane sizes stay within bounds on narrow and wide panes', () => {
  assert.equal(L.bubbleMaxWidth(395), 324);
  assert.equal(L.bubbleMaxWidth(1200), 560);
  assert.equal(L.mediaWidth(395), 253);
  assert.equal(L.mediaWidth(300), 200);
  assert.equal(L.mediaWidth(900), 340);
  assert.equal(L.columnsFor(395, 44, 6, 14), 8);
  assert.equal(L.columnsFor(515, 44, 6, 14), 11);
  assert.equal(L.columnsFor(200, 44, 6, 14), 6);
  assert.equal(L.panelHeight(560), 235);
  assert.equal(L.panelHeight(300), 150);
});

// ---- Nav ----

test('nav: choosing a chat from the list replaces the stack', () => {
  const nav = new Nav();
  let changes = 0;
  nav.onChange = () => { changes++; };
  nav.openRootChat(1);
  nav.push('profile').userId = 7;
  nav.commit();
  assert.deepEqual(nav.stack.map((r) => r.kind), ['chat', 'profile']);
  nav.openRootChat(2);
  assert.deepEqual(nav.stack.map((r) => r.chatId), [2]);
  assert.equal(nav.rootChatId(), 2);
  assert.equal(changes, 3);
  nav.openRootChat(2); // already open: nothing happens
  assert.equal(changes, 3);
});

test('nav: reopening the same chat at a message recreates the route', () => {
  const nav = new Nav();
  nav.openRootChat(1);
  const first = nav.top().id;
  nav.openRootChat(1, 555);
  assert.notEqual(nav.top().id, first);
  assert.equal(nav.top().messageId, 555);
});

test('nav: "send message" from a profile returns to the chat it came from', () => {
  const nav = new Nav();
  nav.openRootChat(1);
  const chatRoute = nav.top().id;
  nav.push('profile');
  nav.commit();
  nav.openChat(1);
  assert.equal(nav.stack.length, 1);
  assert.equal(nav.top().id, chatRoute); // the same view, state intact
  nav.openChat(9);                        // another chat stacks on top
  assert.deepEqual(nav.stack.map((r) => r.chatId), [1, 9]);
  nav.openChat(9);                        // already on top
  assert.equal(nav.stack.length, 2);
});

test('nav: back asks the top route first, then pops, then reports empty', () => {
  const nav = new Nav();
  nav.openRootChat(1);
  let panelOpen = true;
  nav.top().controller.back = () => {
    if (panelOpen) {
      panelOpen = false;
      return true;
    }
    return false;
  };
  assert.equal(nav.back(), true);
  assert.equal(nav.stack.length, 1); // the route closed its panel
  assert.equal(nav.back(), true);
  assert.equal(nav.stack.length, 0);
  assert.equal(nav.back(), false);   // nothing open: the host leaves the app
});

test('nav: a picker is replaced by the chat it leads to', () => {
  const nav = new Nav();
  nav.openRoot('contacts');
  nav.commit();
  nav.replaceWithChat(5);
  assert.deepEqual(nav.stack.map((r) => `${r.kind}:${r.chatId}`), ['chat:5']);
});

// ---- ListDiff ----

function apply(oldIds, ops) {
  const list = oldIds.slice();
  const marks = [];
  for (const op of ops) {
    if (op.type === D.OP_ADD) {
      list.splice(op.index, 0, null);
    } else if (op.type === D.OP_DELETE) {
      list.splice(op.index, 1);
    } else {
      marks.push(op.index);
    }
  }
  return { length: list.length, added: list.map((v, i) => (v === null ? i : -1)).filter((i) => i >= 0), changed: marks };
}

const keys = (ids, changed = []) => ids.map((id) => (changed.includes(id) ? `${id}*` : `${id}`));

test('diff: prepending older messages is reported as additions at the top', () => {
  const ops = D.diffLists([10, 11, 12], keys([10, 11, 12]), [7, 8, 9, 10, 11, 12], keys([7, 8, 9, 10, 11, 12]));
  assert.deepEqual(ops.map((o) => [o.type, o.index]), [[D.OP_ADD, 0], [D.OP_ADD, 1], [D.OP_ADD, 2]]);
});

test('diff: append, delete and change in one step reproduce the new list', () => {
  const oldIds = [1, 2, 3, 4, 5];
  const newIds = [0, 1, 3, 5, 6];
  const ops = D.diffLists(oldIds, keys(oldIds), newIds, keys(newIds, [3]));
  const r = apply(oldIds, ops);
  assert.equal(r.length, newIds.length);
  assert.deepEqual(r.added, [0, 4]);
  assert.deepEqual(r.changed, [2]);
});

test('diff: unchanged lists produce nothing; reordering asks for a reload', () => {
  assert.deepEqual(D.diffLists([1, 2], keys([1, 2]), [1, 2], keys([1, 2])), []);
  assert.equal(D.diffLists([1, 2, 3], keys([1, 2, 3]), [2, 1, 3], keys([2, 1, 3])), null);
  assert.deepEqual(D.diffLists([], [], [], []), []);
});

test('diff: random edits always reproduce the new list', () => {
  let seed = 42;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  for (let round = 0; round < 300; round++) {
    const oldIds = [];
    for (let id = 1; id <= 30; id++) {
      if (rnd(3) > 0) {
        oldIds.push(id);
      }
    }
    const newIds = [];
    for (let id = 1; id <= 30; id++) {
      if (rnd(3) > 0) {
        newIds.push(id);
      }
    }
    const changed = newIds.filter(() => rnd(4) === 0);
    const ops = D.diffLists(oldIds, keys(oldIds), newIds, keys(newIds, changed));
    assert.notEqual(ops, null);
    const r = apply(oldIds, ops);
    assert.equal(r.length, newIds.length);
    const expectAdded = newIds.map((id, i) => (oldIds.includes(id) ? -1 : i)).filter((i) => i >= 0);
    assert.deepEqual(r.added, expectAdded);
    const expectChanged = newIds.map((id, i) => (oldIds.includes(id) && changed.includes(id) ? i : -1)).filter((i) => i >= 0);
    assert.deepEqual(r.changed, expectChanged);
  }
});

// ---- Tags ----

test('tags: normalizing', () => {
  assert.equal(T.normalizeTag('#news'), '#news');
  assert.equal(T.normalizeTag('  #新闻 '), '#新闻');
  assert.equal(T.normalizeTag('news'), '#news');
  assert.equal(T.normalizeTag('$TON'), '$TON');
  assert.equal(T.normalizeTag('#'), '');
  assert.equal(T.normalizeTag('#a b'), '');
});

test('tags: snippet keeps the tag visible in long messages', () => {
  assert.equal(T.snippetAround('short #tag text', '#tag', 40), 'short #tag text');
  const long = 'x'.repeat(200) + ' #release notes ' + 'y'.repeat(200);
  const s = T.snippetAround(long, '#release', 60);
  assert.ok(s.includes('#release'), s);
  assert.ok(s.length <= 60, `length ${s.length}`);
  assert.ok(s.startsWith('…') && s.endsWith('…'));
  const head = T.snippetAround('#first ' + 'z'.repeat(300), '#first', 30);
  assert.ok(head.startsWith('#first') && head.endsWith('…') && head.length <= 30);
  assert.equal(T.snippetAround('line one\n\nline   two', '', 40), 'line one line two');
});

// ---- AlbumLayout ----

test('album layout: cells tile the box without overlap for 2 to 10 items', () => {
  for (let n = 2; n <= 10; n++) {
    for (const ratios of [Array(n).fill(1), Array(n).fill(1.6), Array(n).fill(0.6),
      Array.from({ length: n }, (_, i) => (i % 2 ? 0.7 : 1.8))]) {
      for (const maxW of [200, 273, 360]) {
        const box = A.albumLayout(ratios, maxW, 340);
        assert.equal(box.cells.length, n);
        assert.ok(box.width <= maxW + 0.01 && box.height <= 340 + 0.01, `box ${box.width}x${box.height}`);
        let area = 0;
        for (const c of box.cells) {
          assert.ok(c.w > 20 && c.h > 20, `cell too small: ${c.w}x${c.h} (n=${n})`);
          assert.ok(c.x >= -0.01 && c.y >= -0.01 && c.x + c.w <= box.width + 0.01 && c.y + c.h <= box.height + 0.01);
          area += c.w * c.h;
        }
        assert.ok(area <= box.width * box.height + 1, 'cells overlap');
      }
    }
  }
});

test('nav: opening a message of the chat underneath pops and jumps there', () => {
  const nav = new Nav();
  nav.openRootChat(1);
  let jumped = 0;
  nav.top().controller.jumpTo = (id) => { jumped = id; };
  nav.push('profile');
  nav.commit();
  nav.openChat(1, 777);
  assert.equal(nav.stack.length, 1);
  assert.equal(jumped, 777);
  nav.openChat(2, 5); // a message of another chat opens that chat on top
  assert.deepEqual(nav.stack.map((r) => `${r.chatId}:${r.messageId}`), ['1:0', '2:5']);
});

test('nav: replacing a picker with the chat underneath does not duplicate it', () => {
  const nav = new Nav();
  let changes = 0;
  nav.openRootChat(3);
  nav.push('forward');
  nav.commit();
  nav.onChange = () => { changes++; };
  nav.replaceWithChat(3);
  assert.deepEqual(nav.stack.map((r) => r.kind), ['chat']);
  assert.equal(changes, 1);
});

test('nav: a comment thread is its own route, distinct from its chat', () => {
  const nav = new Nav();
  nav.openRootChat(1);
  nav.openThread(50, 9000, '评论');   // comments live in discussion group 50
  assert.deepEqual(nav.stack.map((r) => `${r.chatId}/${r.threadId}`), ['1/0', '50/9000']);
  nav.openChat(50);                   // opening the group itself stacks; the thread is not "that chat"
  assert.equal(nav.stack.length, 3);
  assert.equal(nav.top().threadId, 0);
  assert.equal(nav.rootChatId(), 1);
  nav.pop();
  nav.pop();
  assert.equal(nav.top().chatId, 1);
});
