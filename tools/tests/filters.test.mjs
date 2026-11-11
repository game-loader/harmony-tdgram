// The message filter manager, with the system kits replaced by stubs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const load = (name) => require(path.join(process.env.TDGRAM_OUT, name + '.js'));
const { Filters, FilterConfig } = load('td/Filters');
const { MsgItem, ChatItem, InlineButton } = load('td/Models');

let nextId = 1;
const msg = (text, chatId = 100, extra = {}) =>
  Object.assign(new MsgItem(), { id: nextId++, chatId, kind: 'text', text, version: 1 }, extra);
const chat = (id, type = 'channel') => Object.assign(new ChatItem(), { id, type, title: `chat ${id}` });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A fresh manager on its own directory; `answer` plays the classifier. The
// handler is global, so a test uses the manager it set up last.
function setup(answer) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tdgram-filters-'));
  const f = new Filters();
  f.init(dir);
  const calls = [];
  globalThis.httpHandler = (url, options) => {
    const body = JSON.parse(options.extraData);
    calls.push({ url, body, auth: options.header.Authorization });
    return answer ? answer(body) : { responseCode: 500, result: '{}', header: {} };
  };
  return { f, dir, calls };
}

// Answers "advertisement" for every message containing the word "buy".
const byWord = (body) => {
  const answers = {};
  for (const [name, s] of Object.entries(body.state)) {
    answers[name] = { type: 'noul', noul: /buy/.test(s.message) ? 0.97 : 0.03 };
  }
  return { responseCode: 200, result: JSON.stringify({ answers }), header: { 'x-tokens-remaining': '4242' } };
};

test('filters: a blocked message hides every copy, in its chat or everywhere', () => {
  const { f } = setup();
  const c = chat(100);
  const ad = msg('🔥 Join our VIP group now!!');
  assert.equal(f.check(ad, c), '');
  assert.equal(f.block([ad], c, false), 1);
  assert.equal(f.check(ad, c), 'same');
  assert.equal(f.check(msg('join our vip group NOW'), c), 'same');
  assert.equal(f.check(msg('Join our VIP group now', 200), chat(200)), '');
  assert.equal(f.check(msg('Join our VIP group later'), c), '');
  assert.equal(f.check(msg('Join our VIP group now', 100, { outgoing: true }), c), '');
  // Widening the entry replaces it.
  f.block([ad], c, true);
  assert.equal(f.config.entries.length, 1);
  assert.equal(f.config.entries[0].chatId, 0);
  assert.equal(f.check(msg('Join our VIP group now', 200), chat(200)), 'same');
  assert.equal(f.block([msg('ok')], c, false), 0);
});

test('filters: an edited message is judged again', () => {
  const { f } = setup();
  const c = chat(100);
  const m = msg('Join our VIP group now');
  f.block([m], c, false);
  assert.equal(f.check(m, c), 'same');
  m.text = 'Server maintenance tomorrow';
  m.version++;
  assert.equal(f.check(m, c), '');
});

test('filters: keyword rules, the allow list and the main switch', () => {
  const { f } = setup();
  const c = chat(100);
  f.update((cfg) => { cfg.rules = ['t.me/spam', '/free\\s+vpn/']; });
  const byButton = msg('look', 100, { buttons: [[Object.assign(new InlineButton(), { text: 'Open', url: 'https://T.me/Spam' })]] });
  assert.equal(f.check(byButton, c), 'rule');
  const byRegex = msg('Get a FREE   VPN today');
  assert.equal(f.check(byRegex, c), 'rule');
  assert.equal(f.check(msg('nothing special here'), c), '');
  f.unblock(byRegex);
  assert.equal(f.check(byRegex, c), '');
  assert.equal(f.check(msg('get a free vpn TODAY'), c), '');
  assert.equal(f.check(byButton, c), 'rule');
  f.update((cfg) => { cfg.enabled = false; });
  assert.equal(f.check(byButton, c), '');
});

test('filters: settings and blocked messages survive a restart', () => {
  const { f, dir } = setup();
  const c = chat(100);
  f.block([msg('Join our VIP group now')], c, false);
  f.update((cfg) => { cfg.rules = ['casino']; cfg.mode = 'hide'; cfg.aiKey = 'sk-test'; });
  const again = new Filters();
  again.init(dir);
  assert.equal(again.config.mode, 'hide');
  assert.equal(again.config.aiKey, 'sk-test');
  assert.equal(again.check(msg('JOIN our vip group now'), c), 'same');
  assert.equal(again.check(msg('best casino in town'), c), 'rule');
  fs.writeFileSync(path.join(dir, 'filters.json'), '{broken');
  const broken = new Filters();
  broken.init(dir);
  assert.deepEqual(broken.config, new FilterConfig());
});

test('filters: the classifier is asked once per content, in batches, only for chosen chats', async () => {
  const { f, calls } = setup(byWord);
  f.update((cfg) => { cfg.aiEnabled = true; cfg.aiKey = ' sk-test '; cfg.aiChats = [100]; });
  const c = chat(100);
  let notified = 0;
  f.on(() => { notified++; });
  const ad = msg('buy cheap watches today');
  const plain = msg('the build is green again');
  assert.equal(f.check(ad, c), '');
  assert.equal(f.check(plain, c), '');
  assert.equal(f.check(msg('BUY cheap watches, today!'), c), '');
  // Not asked: another chat, a secret chat, a message without text.
  f.check(msg('buy something else entirely', 200), chat(200));
  f.check(msg('buy this in a secret chat', 100), chat(100, 'secret'));
  f.check(msg('ok'), c);
  await sleep(450);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].auth, 'Bearer sk-test');
  assert.equal(Object.keys(calls[0].body.state).length, 2);
  assert.equal(f.check(ad, c), 'ai');
  assert.equal(f.check(plain, c), '');
  assert.equal(f.probability(ad), 0.97);
  assert.equal(f.aiLeft, '4242');
  assert.ok(notified >= 1);
  // Remembered: the same content is not sent again, also after a restart.
  assert.equal(f.check(msg('Buy cheap watches today'), c), 'ai');
  await sleep(2300);
  assert.equal(calls.length, 1);
  // The threshold decides; "not an advertisement" overrules.
  f.update((cfg) => { cfg.aiThreshold = 0.99; });
  assert.equal(f.check(ad, c), '');
  f.update((cfg) => { cfg.aiThreshold = 0.8; });
  assert.equal(f.check(ad, c), 'ai');
  f.unblock(ad);
  assert.equal(f.check(ad, c), '');
  assert.equal(calls.length, 1);
});

test('filters: all channels can be judged, other chat types only when chosen', async () => {
  const { f, calls } = setup(byWord);
  f.update((cfg) => { cfg.aiEnabled = true; cfg.aiKey = 'k'; cfg.aiChannels = true; });
  f.check(msg('buy one get one free', 300), chat(300, 'channel'));
  f.check(msg('buy me a coffee sometime', 301), chat(301, 'supergroup'));
  await sleep(450);
  assert.equal(calls.length, 1);
  assert.deepEqual(Object.values(calls[0].body.state).map((s) => s.message), ['buy one get one free']);
});

test('filters: a notification waits for the answer; a refused key stops the asking', async () => {
  const ok = setup(byWord);
  ok.f.update((cfg) => { cfg.aiEnabled = true; cfg.aiKey = 'k'; cfg.aiChats = [100]; });
  assert.equal(await ok.f.settle(msg('buy followers cheap'), chat(100)), 'ai');
  assert.equal(await ok.f.settle(msg('lunch at noon as usual'), chat(100)), '');
  assert.match(await ok.f.test(), /^可用/);

  const bad = setup(() => ({ responseCode: 401, result: '{"error":{"message":"Missing or invalid API key."}}', header: {} }));
  bad.f.update((cfg) => { cfg.aiEnabled = true; cfg.aiKey = 'wrong'; cfg.aiChats = [100]; });
  assert.equal(await bad.f.settle(msg('buy followers cheap'), chat(100)), '');
  assert.match(bad.f.aiError, /invalid API key/);
  bad.f.check(msg('buy another thing now'), chat(100));
  await sleep(450);
  assert.equal(bad.calls.length, 1);
  // New settings give it another try.
  bad.f.update((cfg) => { cfg.aiKey = 'better'; });
  bad.f.check(msg('buy a third thing now'), chat(100));
  await sleep(450);
  assert.equal(bad.calls.length, 2);
  assert.match(await bad.f.test(), /^失败/);
});
