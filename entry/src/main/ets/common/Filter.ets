// Message filter logic: content fingerprints, keyword rules and the request
// and response of the AI classifier. No UI imports: unit-tested by
// tools/test.mjs.

// What a message is judged by.
export class FilterContent {
  text: string = '';
  buttons: string[] = []; // inline button labels
  urls: string[] = [];    // button and link preview addresses
  fileUid: string = '';   // unique id of the attached file
}

function keep(c: number): boolean {
  if (c < 0x80) {
    return (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A);
  }
  if (c < 0x3040) {
    // Latin, Greek, Cyrillic, Hebrew, Arabic and the scripts up to U+1FFF.
    return (c >= 0xC0 && c <= 0x24F && c !== 0xD7 && c !== 0xF7) || (c >= 0x370 && c <= 0x52F) ||
      (c >= 0x590 && c <= 0x6FF) || (c >= 0x900 && c <= 0x1FFF);
  }
  // Kana, CJK ideographs, Hangul.
  return c <= 0x30FA || (c >= 0x3400 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF);
}

// Letters and digits only, lower case: the same advertisement keeps its
// fingerprint when spacing, punctuation or emoji differ.
export function normalizeText(raw: string): string {
  const s = raw.normalize('NFKC').toLowerCase();
  let out = '';
  for (let i = 0; i < s.length; i++) {
    if (keep(s.charCodeAt(i))) {
      out += s.charAt(i);
    }
  }
  return out;
}

// Two independent 32-bit hashes plus the length.
function hash(s: string): string {
  let a = 0x811c9dc5;
  let b = 5381;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    a = Math.imul(a ^ c, 0x01000193);
    b = (Math.imul(b, 33) + c) | 0;
  }
  return `${s.length.toString(36)}.${(a >>> 0).toString(36)}.${(b >>> 0).toString(36)}`;
}

const MIN_TEXT = 6;

// Fingerprint of a message: 't:' from its text, 'b:' from a short text plus
// its buttons, 'f:' from its file; '' when there is nothing to recognise it by.
export function signature(c: FilterContent): string {
  const t = normalizeText(c.text);
  if (t.length >= MIN_TEXT) {
    return 't:' + hash(t);
  }
  const b = normalizeText(c.buttons.join(' ')) + c.urls.join(' ').toLowerCase();
  if (t.length + b.length >= MIN_TEXT) {
    return 'b:' + hash(t + '|' + b);
  }
  return c.fileUid ? 'f:' + c.fileUid : '';
}

// Only messages with real text are worth asking the classifier about.
export function hasText(sig: string): boolean {
  return sig.startsWith('t:');
}

// Everything a keyword rule searches in, lower case.
export function haystack(c: FilterContent): string {
  return [c.text].concat(c.buttons).concat(c.urls).join('\n').toLowerCase();
}

// A keyword rule: plain text (found anywhere, ignoring case) or /regex/flags.
export class Pattern {
  re: RegExp | null = null;
  needle: string = '';
  valid: boolean = true;
}

export function compilePattern(value: string): Pattern {
  const p = new Pattern();
  const v = value.trim();
  const end = v.startsWith('/') ? v.lastIndexOf('/') : -1;
  if (end > 0) {
    const flags = v.substring(end + 1).split('').filter((f: string) => 'msu'.includes(f)).join('');
    try {
      p.re = new RegExp(v.substring(1, end), flags + 'i');
    } catch (e) {
      p.valid = false;
    }
    if (end === 1) {
      p.valid = false;
    }
  } else {
    p.needle = v.toLowerCase();
    p.valid = p.needle.length > 0;
  }
  return p;
}

export function patternHits(p: Pattern, hay: string): boolean {
  if (!p.valid) {
    return false;
  }
  return p.re ? p.re.test(hay) : hay.includes(p.needle);
}

// Built-in rules: posts that label themselves as advertising.
export const PRESETS: string[] = [
  '/#(ad|ads|advert|advertisement|sponsored|promo|广告|推广|赞助|恰饭|商务合作)(?![a-z0-9_])/',
  '/(^|\\n)\\s*(广告|推广|赞助|ad|sponsored)\\s*[:：|｜]/'
];

// ---- AI classifier (Jev "SystemOne" request format) ----

export const AI_BATCH = 8;       // questions one request may carry
const AI_TEXT_MAX = 1200;        // characters of a message sent for judging

function adQuestion(name: string): string {
  return `Is message ${name} an advertisement, sponsored post or promotion (of a product, service, channel, ` +
    'group, bot, giveaway, gambling, crypto, VPN or similar) rather than regular content of the chat?';
}

// Body of one request: up to AI_BATCH messages as the state (m1, m2, ...)
// and one yes/no question about each. Sharing a request costs about a third
// of asking one by one. Long posts are cut: the start is enough to judge.
export function jevRequest(model: string, items: FilterContent[]): string {
  const state: Record<string, Object> = {};
  const questions: Record<string, Object> = {};
  items.slice(0, AI_BATCH).forEach((c: FilterContent, i: number) => {
    const name = `m${i + 1}`;
    const one: Record<string, Object> = {
      'message': c.text.length > AI_TEXT_MAX ? c.text.substring(0, AI_TEXT_MAX) + '…' : c.text
    };
    if (c.buttons.length > 0) {
      one['buttons'] = c.buttons.slice(0, 8);
    }
    if (c.urls.length > 0) {
      one['links'] = c.urls.slice(0, 8);
    }
    state[name] = one;
    const question: Record<string, Object> = { 'type': 'noul', 'instructions': adQuestion(name) };
    questions[name] = question;
  });
  const body: Record<string, Object> = { 'model': model || 'jev-latest', 'state': state, 'questions': questions };
  return JSON.stringify(body);
}

export class JevResult {
  ok: boolean = false;
  p: number[] = [];       // per message: probability that it is an advertisement, -1 when not answered
  error: string = '';
  retry: boolean = false; // worth asking again later (rate limit, server or network trouble)
  fatal: boolean = false; // nothing will work until the settings change (key, credits, address)
}

// Reads the response to a request about `count` messages; `status` 0 stands
// for a request that never got one.
export function jevResult(status: number, body: string, count: number): JevResult {
  const r = new JevResult();
  let o: Record<string, Object> | null = null;
  try {
    o = JSON.parse(body) as Record<string, Object> | null;
  } catch (e) {
    o = null;
  }
  const isObject = o !== null && typeof o === 'object';
  const answers = isObject ? o!['answers'] as Record<string, Object> | undefined : undefined;
  if (status === 200 && answers && typeof answers === 'object') {
    for (let i = 0; i < count; i++) {
      const a = answers[`m${i + 1}`] as Record<string, Object> | undefined;
      const p = a && typeof a === 'object' ? a['noul'] as number | undefined : undefined;
      const valid = typeof p === 'number' && p >= 0 && p <= 1;
      r.p.push(valid ? p as number : -1);
      r.ok = r.ok || valid;
    }
    if (r.ok) {
      return r;
    }
  }
  if (status === 200) {
    r.error = '接口返回的内容无法识别';
    r.fatal = true;
    return r;
  }
  const err = isObject ? o!['error'] as Record<string, Object> | undefined : undefined;
  const message = err && typeof err === 'object' ? err['message'] as string | undefined : undefined;
  if (status === 0) {
    r.error = `无法连接接口${body ? '：' + body : ''}`;
    r.retry = true;
    return r;
  }
  r.error = message ? `${message}（${status}）` : `接口返回 ${status}`;
  r.retry = status === 429 || status >= 500;
  r.fatal = status === 401 || status === 402 || status === 403 || status === 404;
  return r;
}
