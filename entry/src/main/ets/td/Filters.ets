import { fileIo as fs } from '@kit.CoreFileKit';
import { connection, http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AI_BATCH, compilePattern, FilterContent, hasText, haystack, jevRequest, jevResult, JevResult, Pattern, patternHits, PRESETS,
  signature
} from '../common/Filter';
import { snippetAround } from '../common/Tags';
import { ChatItem, InlineButton, MsgItem } from './Models';
import { TdObject } from './TdClient';

export type FilterMode = 'collapse' | 'hide';
// Why a message is filtered: '' (it is not), same content as a blocked
// message, a keyword rule, or the AI classifier.
export type FilterReason = '' | 'same' | 'rule' | 'ai';

export const DEFAULT_AI_URL = 'https://jevmodel.org/v1/systemone';
export const DEFAULT_AI_MODEL = 'jev-latest';

// A blocked message: every message with the same fingerprint is filtered.
export class FilterEntry {
  sig: string = '';
  sample: string = '';    // what was blocked, for the list in the settings
  chatId: number = 0;     // 0: in every chat
  chatTitle: string = '';
  date: number = 0;
}

export class FilterConfig {
  enabled: boolean = true;
  mode: FilterMode = 'collapse'; // one line in place of the messages, or nothing at all
  presets: boolean = false;      // built-in rules for posts labelled as advertising
  entries: FilterEntry[] = [];
  rules: string[] = [];          // keywords or /regex/
  allowed: string[] = [];        // fingerprints marked "not an advertisement"
  aiEnabled: boolean = false;
  aiUrl: string = DEFAULT_AI_URL;
  aiKey: string = '';
  aiModel: string = DEFAULT_AI_MODEL;
  aiThreshold: number = 0.8;
  aiChannels: boolean = false;   // judge every channel, not only the chosen chats
  aiChats: number[] = [];

  static from(s: FilterConfig): FilterConfig {
    const d = new FilterConfig();
    d.enabled = s.enabled ?? d.enabled;
    d.mode = s.mode === 'hide' ? 'hide' : 'collapse';
    d.presets = s.presets ?? d.presets;
    d.entries = (s.entries ?? []).map((e: FilterEntry) => {
      const n = new FilterEntry();
      n.sig = e.sig ?? '';
      n.sample = e.sample ?? '';
      n.chatId = e.chatId ?? 0;
      n.chatTitle = e.chatTitle ?? '';
      n.date = e.date ?? 0;
      return n;
    }).filter((e: FilterEntry) => e.sig !== '');
    d.rules = (s.rules ?? []).filter((r: string) => typeof r === 'string' && r.trim() !== '');
    d.allowed = (s.allowed ?? []).slice();
    d.aiEnabled = s.aiEnabled ?? d.aiEnabled;
    d.aiUrl = s.aiUrl ?? d.aiUrl;
    d.aiKey = s.aiKey ?? d.aiKey;
    d.aiModel = s.aiModel ?? d.aiModel;
    d.aiThreshold = typeof s.aiThreshold === 'number' ? s.aiThreshold : d.aiThreshold;
    d.aiChannels = s.aiChannels ?? d.aiChannels;
    d.aiChats = (s.aiChats ?? []).slice();
    return d;
  }
}

// What a message is judged by.
export function contentOf(m: MsgItem): FilterContent {
  const c = new FilterContent();
  c.text = m.kind === 'poll' ? m.pollQuestion : m.text;
  const urls: string[] = [];
  m.buttons.forEach((row: InlineButton[]) => row.forEach((b: InlineButton) => {
    c.buttons.push(b.text);
    if (b.url) {
      urls.push(b.url);
    }
  }));
  for (const e of m.entities) {
    const t = e['type'] as TdObject | undefined;
    if (t && t['@type'] === 'textEntityTypeTextUrl') {
      urls.push(t['url'] as string);
    }
  }
  c.urls = urls.filter((u: string, i: number) => urls.indexOf(u) === i);
  c.fileUid = m.fileUid;
  return c;
}

export function reasonText(r: string): string {
  return r === 'same' ? '相同内容' : (r === 'rule' ? '关键词规则' : (r === 'ai' ? 'AI 判定为广告' : ''));
}

class Job {
  sig: string = '';
  content: FilterContent = new FilterContent();
}

class SavedVerdicts {
  s: string[] = [];
  p: number[] = [];
}

type FilterListener = () => void;

const PARALLEL = 3;
const QUEUE_MAX = 240;
const VERDICTS_MAX = 4000;
const ALLOWED_MAX = 500;
const WAIT_MS = 8000;     // how long a notification waits for the classifier

// Message filters of the app: blocked fingerprints, keyword rules and an
// optional AI classifier. One instance for all accounts.
export class Filters {
  private static instance: Filters | null = null;
  config: FilterConfig = new FilterConfig();
  // Bumped whenever a verdict may have changed; cached verdicts carry it.
  rev: number = 1;
  configRev: number = 1; // bumped only when the settings change
  aiError: string = '';
  aiLeft: string = '';   // tokens left on the key, as last reported by the service
  aiAsked: number = 0;   // messages judged since the app started
  // The proxy requests go through, when the app has an HTTP proxy enabled.
  httpProxy: () => connection.HttpProxy | null = (): connection.HttpProxy | null => null;
  private dir: string = '';
  private listeners: FilterListener[] = [];
  private entryMap: Map<string, FilterEntry[]> = new Map();
  private allowSet: Set<string> = new Set();
  private patterns: Pattern[] = [];
  private verdicts: Map<string, number> = new Map();
  private queue: Job[] = [];
  private queued: Set<string> = new Set();
  private failed: Set<string> = new Set(); // not asked again until the settings change
  private waiters: Map<string, Array<() => void>> = new Map();
  private running: number = 0;
  private flushTimer: number = -1;
  private pausedUntil: number = 0;
  private backoff: number = 0;
  private stopped: boolean = false; // the service refuses the settings; nothing is asked until they change
  private notifyTimer: number = -1;
  private saveTimer: number = -1;

  static get(): Filters {
    if (!Filters.instance) {
      Filters.instance = new Filters();
    }
    return Filters.instance;
  }

  // `dir`: the app's files directory. Files rather than preferences, whose
  // values are limited in length.
  init(dir: string): void {
    this.dir = dir;
    try {
      const saved = this.read('filters.json');
      if (saved) {
        this.config = FilterConfig.from(JSON.parse(saved) as FilterConfig);
      }
    } catch (e) {
      this.config = new FilterConfig();
    }
    try {
      const v = this.read('filter-verdicts.json');
      if (v) {
        const sv = JSON.parse(v) as SavedVerdicts;
        sv.s.forEach((sig: string, i: number) => this.verdicts.set(sig, sv.p[i]));
      }
    } catch (e) {
      this.verdicts.clear();
    }
    this.index();
  }

  private read(name: string): string {
    const path = `${this.dir}/${name}`;
    return fs.accessSync(path) ? fs.readTextSync(path) : '';
  }

  // Written to a temporary file first, so a crash never leaves half a file.
  private write(name: string, text: string): void {
    if (!this.dir) {
      return;
    }
    try {
      const tmp = `${this.dir}/${name}.tmp`;
      const f = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
      fs.renameSync(tmp, `${this.dir}/${name}`);
    } catch (e) {
      // Kept in memory; the next change tries again.
    }
  }

  on(l: FilterListener): void {
    this.listeners.push(l);
  }

  off(l: FilterListener): void {
    this.listeners = this.listeners.filter((x: FilterListener) => x !== l);
  }

  private index(): void {
    this.entryMap.clear();
    for (const e of this.config.entries) {
      const list = this.entryMap.get(e.sig);
      if (list) {
        list.push(e);
      } else {
        this.entryMap.set(e.sig, [e]);
      }
    }
    this.allowSet = new Set(this.config.allowed);
    const rules = this.config.presets ? PRESETS.concat(this.config.rules) : this.config.rules;
    this.patterns = rules.map((r: string) => compilePattern(r)).filter((p: Pattern) => p.valid);
  }

  // Verdicts changed: listeners redraw, at most once per burst.
  private changed(): void {
    this.rev++;
    if (this.notifyTimer >= 0) {
      return;
    }
    this.notifyTimer = setTimeout(() => {
      this.notifyTimer = -1;
      for (const l of this.listeners.slice()) {
        l();
      }
    }, 40);
  }

  // Changes the settings, saves them and re-evaluates everything.
  update(fn: (c: FilterConfig) => void): void {
    fn(this.config);
    this.index();
    this.write('filters.json', JSON.stringify(this.config));
    this.configRev++;
    // New settings get a fresh start with the classifier.
    this.stopped = false;
    this.pausedUntil = 0;
    this.backoff = 0;
    this.aiError = '';
    this.failed.clear();
    if (!this.aiReady()) {
      this.dropQueue();
    }
    this.changed();
  }

  // ---- Verdicts ----

  sigOf(m: MsgItem): string {
    if (m.filterSigVersion !== m.version) {
      m.filterSig = m.kind === 'service' || m.kind === 'unsupported' ? '' : signature(contentOf(m));
      m.filterSigVersion = m.version;
    }
    return m.filterSig;
  }

  // Why `m` is filtered, '' when it is shown. Cheap to call repeatedly.
  // With `ask`, a message the classifier has not seen yet is sent to it, and
  // listeners are told when the answer changes the verdict.
  check(m: MsgItem, chat: ChatItem | undefined, ask: boolean = true): string {
    if (!this.config.enabled || m.outgoing || m.pending || m.kind === 'service') {
      return '';
    }
    if (m.filterRev !== this.rev || m.filterVersion !== m.version) {
      m.filterReason = this.judge(m, chat);
      m.filterRev = this.rev;
      m.filterVersion = m.version;
    }
    if (ask && !m.filterReason && this.aiFor(chat)) {
      const sig = this.sigOf(m);
      if (hasText(sig) && !this.allowSet.has(sig) && !this.verdicts.has(sig)) {
        this.ask(sig, m);
      }
    }
    return m.filterReason;
  }

  private judge(m: MsgItem, chat: ChatItem | undefined): FilterReason {
    const sig = this.sigOf(m);
    if (sig) {
      if (this.allowSet.has(sig)) {
        return '';
      }
      const list = this.entryMap.get(sig);
      if (list && list.some((e: FilterEntry) => e.chatId === 0 || e.chatId === m.chatId)) {
        return 'same';
      }
    }
    if (this.patterns.length > 0) {
      const hay = haystack(contentOf(m));
      if (this.patterns.some((p: Pattern) => patternHits(p, hay))) {
        return 'rule';
      }
    }
    if (sig && hasText(sig) && this.aiFor(chat)) {
      const p = this.verdicts.get(sig);
      if (p !== undefined && p >= this.config.aiThreshold) {
        return 'ai';
      }
    }
    return '';
  }

  // Like check(), but waits a little for a classifier answer that is on its way.
  settle(m: MsgItem, chat: ChatItem | undefined): Promise<string> {
    const now = this.check(m, chat);
    const sig = this.sigOf(m);
    if (now || !sig || !this.queued.has(sig)) {
      return Promise.resolve(now);
    }
    return new Promise<string>((resolve: (r: string) => void) => {
      let done = false;
      const finish = (): void => {
        if (!done) {
          done = true;
          resolve(this.check(m, chat));
        }
      };
      const list = this.waiters.get(sig);
      if (list) {
        list.push(finish);
      } else {
        this.waiters.set(sig, [finish]);
      }
      setTimeout(finish, WAIT_MS);
    });
  }

  // ---- Blocked messages ----

  // Blocks everything with the same content as each of `list`, in this chat
  // or everywhere. Returns how many had something to recognise them by.
  block(list: MsgItem[], chat: ChatItem | undefined, everywhere: boolean): number {
    const usable = list.filter((m: MsgItem) => this.sigOf(m) !== '');
    if (usable.length === 0) {
      return 0;
    }
    this.update((c: FilterConfig) => {
      for (const m of usable) {
        const sig = this.sigOf(m);
        const chatId = everywhere ? 0 : m.chatId;
        c.allowed = c.allowed.filter((s: string) => s !== sig);
        // A wider entry replaces the narrower ones.
        c.entries = c.entries.filter((e: FilterEntry) => !(e.sig === sig && (chatId === 0 || e.chatId === chatId)));
        if (c.entries.some((e: FilterEntry) => e.sig === sig && e.chatId === 0)) {
          continue;
        }
        const e = new FilterEntry();
        const content = contentOf(m);
        e.sig = sig;
        e.sample = snippetAround(content.text || content.buttons.join(' ') || `（${m.kind}）`, '', 80);
        e.chatId = chatId;
        e.chatTitle = chatId && chat ? chat.title : '';
        e.date = Math.floor(Date.now() / 1000);
        c.entries.unshift(e);
      }
    });
    return usable.length;
  }

  // Shows the messages like `m` again: its entry is removed, and a keyword
  // or AI verdict is overruled.
  unblock(m: MsgItem): void {
    const sig = this.sigOf(m);
    if (!sig) {
      return;
    }
    const reason = m.filterReason;
    this.update((c: FilterConfig) => {
      c.entries = c.entries.filter((e: FilterEntry) => !(e.sig === sig && (e.chatId === 0 || e.chatId === m.chatId)));
      if (reason !== 'same' && !c.allowed.includes(sig)) {
        c.allowed.push(sig);
        if (c.allowed.length > ALLOWED_MAX) {
          c.allowed.splice(0, c.allowed.length - ALLOWED_MAX);
        }
      }
    });
  }

  // ---- AI classifier ----

  aiReady(): boolean {
    const c = this.config;
    return c.enabled && c.aiEnabled && c.aiKey.trim() !== '' && c.aiUrl.trim().startsWith('http');
  }

  // Whether messages of `chat` are sent to the classifier. Never secret chats.
  aiFor(chat: ChatItem | undefined): boolean {
    if (!chat || chat.type === 'secret' || !this.aiReady()) {
      return false;
    }
    return this.config.aiChats.includes(chat.id) || (this.config.aiChannels && chat.type === 'channel');
  }

  // The classifier's answer for `m`: 0..1, or -1 when it was not asked.
  probability(m: MsgItem): number {
    const p = this.verdicts.get(this.sigOf(m));
    return p === undefined ? -1 : p;
  }

  verdictCount(): number {
    return this.verdicts.size;
  }

  clearVerdicts(): void {
    this.verdicts.clear();
    this.saveVerdicts();
    this.changed();
  }

  private ask(sig: string, m: MsgItem): void {
    if (this.stopped || this.queued.has(sig) || this.failed.has(sig)) {
      return;
    }
    const job = new Job();
    job.sig = sig;
    job.content = contentOf(m);
    this.queued.add(sig);
    this.queue.push(job);
    while (this.queue.length > QUEUE_MAX) {
      const old = this.queue.shift();
      if (old) {
        this.release(old.sig);
      }
    }
    this.schedule(250);
  }

  private release(sig: string): void {
    this.queued.delete(sig);
    const list = this.waiters.get(sig);
    if (list) {
      this.waiters.delete(sig);
      list.forEach((fn: () => void) => fn());
    }
  }

  private dropQueue(): void {
    const jobs = this.queue;
    this.queue = [];
    jobs.forEach((j: Job) => this.release(j.sig));
  }

  private schedule(delay: number): void {
    if (this.flushTimer >= 0) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flush();
    }, delay);
  }

  private flush(): void {
    const wait = this.pausedUntil - Date.now();
    if (wait > 0) {
      this.schedule(wait);
      return;
    }
    while (this.running < PARALLEL && this.queue.length > 0) {
      // Newest first: those are the messages on screen.
      const batch = this.queue.splice(Math.max(0, this.queue.length - AI_BATCH), AI_BATCH);
      this.run(batch);
    }
  }

  private run(batch: Job[]): void {
    this.running++;
    this.post(jevRequest(this.config.aiModel.trim(), batch.map((j: Job) => j.content)), batch.length)
      .then((r: JevResult) => {
        this.running--;
        let done: Job[] = batch;
        if (r.ok) {
          this.backoff = 0;
          this.aiError = '';
          batch.forEach((j: Job, i: number) => {
            if (r.p[i] >= 0) {
              this.verdicts.set(j.sig, r.p[i]);
              this.aiAsked++;
            } else {
              this.failed.add(j.sig);
            }
          });
          this.trimVerdicts();
          this.saveVerdicts();
        } else if (r.retry) {
          // Rate limit or trouble on the way: the same messages go again later.
          this.aiError = r.error;
          this.backoff = Math.min(Math.max(this.backoff * 2, 30000), 600000);
          this.pausedUntil = Date.now() + this.backoff;
          this.queue = this.queue.concat(batch);
          done = [];
        } else {
          this.aiError = r.error;
          batch.forEach((j: Job) => this.failed.add(j.sig));
          if (r.fatal) {
            this.stopped = true;
            done = batch.concat(this.queue);
            this.queue = [];
          }
        }
        // Verdicts are refreshed before anyone waiting is told.
        this.changed();
        done.forEach((j: Job) => this.release(j.sig));
        this.flush();
      });
  }

  // One request; never rejects.
  private post(body: string, count: number): Promise<JevResult> {
    const req = http.createHttp();
    const header: Record<string, string> = {
      'Authorization': `Bearer ${this.config.aiKey.trim()}`,
      'Content-Type': 'application/json'
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: header,
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 40000
    };
    // The app's own HTTP proxy when there is one, else the system's.
    const proxy = this.httpProxy();
    options.usingProxy = proxy ? proxy : true;
    return req.request(this.config.aiUrl.trim(), options).then((resp: http.HttpResponse) => {
      req.destroy();
      const headers = resp.header as Record<string, string> | undefined;
      const left = headers ? (headers['x-tokens-remaining'] ?? headers['X-Tokens-Remaining']) : undefined;
      if (left !== undefined) {
        this.aiLeft = String(left);
      }
      const text = typeof resp.result === 'string' ? resp.result as string : JSON.stringify(resp.result);
      return jevResult(resp.responseCode, text, count);
    }).catch((e: BusinessError) => {
      req.destroy();
      return jevResult(0, e && e.message ? e.message : '', count);
    });
  }

  private trimVerdicts(): void {
    if (this.verdicts.size <= VERDICTS_MAX) {
      return;
    }
    const keys = Array.from(this.verdicts.keys());
    keys.slice(0, keys.length - VERDICTS_MAX).forEach((k: string) => this.verdicts.delete(k));
  }

  private saveVerdicts(): void {
    if (this.saveTimer >= 0) {
      return;
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      const sv = new SavedVerdicts();
      this.verdicts.forEach((p: number, sig: string) => {
        sv.s.push(sig);
        sv.p.push(p);
      });
      this.write('filter-verdicts.json', JSON.stringify(sv));
    }, 2000);
  }

  // Tries the settings with one obvious advertisement and one ordinary
  // message, and describes the outcome.
  test(): Promise<string> {
    if (!this.config.aiKey.trim() || !this.config.aiUrl.trim().startsWith('http')) {
      return Promise.resolve('请先填写接口地址和 API Key');
    }
    const ad = new FilterContent();
    ad.text = '🔥限时福利：全网最低价 VPN，注册即送 7 天试用，点击下方按钮立即领取';
    ad.buttons = ['立即领取'];
    const plain = new FilterContent();
    plain.text = '明天上午十点服务器维护，预计半小时，期间机器人无法使用。';
    const started = Date.now();
    return this.post(jevRequest(this.config.aiModel.trim(), [ad, plain]), 2).then((r: JevResult) => {
      if (!r.ok) {
        return `失败：${r.error}`;
      }
      const pct = (p: number): string => p < 0 ? '无结果' : `${Math.round(p * 100)}%`;
      return `可用（${Date.now() - started} ms）。示例广告 ${pct(r.p[0])}，普通消息 ${pct(r.p[1])}` +
        (this.aiLeft ? `，剩余额度 ${this.aiLeft} tokens` : '');
    });
  }
}
