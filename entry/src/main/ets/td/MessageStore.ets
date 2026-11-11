import { AccountCore } from './Core';
import { o, TdObject } from './TdClient';
import { MsgItem, ReactionItem } from './Models';
import { fillContent, fillInteraction, fillMessage, NameOf } from './Parse';
import { hilog } from '@kit.PerformanceAnalysisKit';

const PAGE = 40;
// TDLib often answers the first request with only the messages it has in
// memory (sometimes a single one); keep asking until a screen can be filled.
const MIN_FILL = 20;

export interface SendOptions {
  replyTo: number;
  silent: boolean;
}

export type StoreEvent = 'messages' | 'pinned';

// How a chat view wants its history positioned when it opens.
export class OpenOptions {
  messageId: number = 0;  // open around this message
  lastReadId: number = 0; // last incoming message already read
  unread: number = 0;     // unread count; with lastReadId, opens at the first unread message
  secret: boolean = false;
}

export class SearchPage {
  items: MsgItem[] = [];
  next: string = ''; // cursor of the following page, '' at the end
  total: number = 0;
}

// Messages of one opened chat (or forum topic) plus every message-level
// action. Each chat view owns its own store, so several chats can be open at
// once (split view, a chat opened from another chat's profile). A store that
// was only bind()-ed serves sends and searches without loading history.
export class MessageStore {
  private core: AccountCore;
  private nameOf: NameOf;
  chatId: number = 0;
  topicId: number = 0; // forum topic being viewed, 0 for the whole chat
  messages: MsgItem[] = []; // ascending by id
  olderDone: boolean = false;
  // False after jumping to an old message: newer pages must be loaded.
  atLatest: boolean = true;
  pinned: MsgItem | null = null;
  // First message after the read position when the chat was opened; the
  // view draws the "unread messages" divider above it. 0 when none.
  firstUnreadId: number = 0;
  onChange: (e: StoreEvent) => void = (): void => {};
  private loading: boolean = false;
  private opened: boolean = false;
  private gen: number = 0; // bumped whenever the window is replaced
  private secret: boolean = false;
  private pendingEvents: Set<StoreEvent> = new Set();
  private timer: number = -1;

  constructor(core: AccountCore, nameOf: NameOf) {
    this.core = core;
    this.nameOf = nameOf;
  }

  // Updates arrive in bursts; the view hears about each kind once per frame.
  private notify(e: StoreEvent): void {
    this.pendingEvents.add(e);
    if (this.timer >= 0) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      const events = Array.from(this.pendingEvents);
      this.pendingEvents.clear();
      for (const ev of events) {
        this.onChange(ev);
      }
    }, 16);
  }

  // One malformed message must not blank the whole page, so parse errors
  // become an "unsupported" bubble instead of rejecting the history.
  private parse(raw: TdObject): MsgItem {
    const item = new MsgItem();
    try {
      return fillMessage(item, raw, this.nameOf);
    } catch (e) {
      hilog.warn(0x0000, 'tdgram', 'parse message failed: %{public}s', String(e));
      item.id = (raw['id'] as number) ?? 0;
      item.chatId = (raw['chat_id'] as number) ?? 0;
      item.date = (raw['date'] as number) ?? 0;
      item.kind = 'unsupported';
      item.text = '无法显示的消息，请在官方客户端查看';
      item.version++;
      return item;
    }
  }

  private refill(m: MsgItem, raw: TdObject): MsgItem {
    try {
      return fillMessage(m, raw, this.nameOf);
    } catch (e) {
      return m;
    }
  }

  private topic(): TdObject | null {
    return this.topicId ? o({ '@type': 'messageTopicForum', 'forum_topic_id': this.topicId }) : null;
  }

  // Parses a message that is not part of the open chat (search results).
  fetchParsed(raw: TdObject): MsgItem {
    return this.parse(raw);
  }

  // Targets a chat for sends and searches without opening it.
  bind(chatId: number, topicId: number = 0, secret: boolean = false): MessageStore {
    this.chatId = chatId;
    this.topicId = topicId;
    this.secret = secret;
    return this;
  }

  // Called by Account.openSession. TDLib counts openChat/closeChat per chat,
  // so two views of the same chat are fine.
  start(opt: OpenOptions): void {
    this.opened = true;
    this.secret = opt.secret;
    this.core.td.send(o({ '@type': 'openChat', 'chat_id': this.chatId })).catch(() => {});
    this.refreshPinned();
    if (opt.messageId) {
      this.loadAround(opt.messageId, 0);
    } else if (opt.unread > 0 && opt.lastReadId > 0) {
      this.loadAround(opt.lastReadId, opt.lastReadId);
    } else {
      this.loadOlder();
    }
  }

  stop(): void {
    if (this.opened) {
      this.opened = false;
      this.core.td.send(o({ '@type': 'closeChat', 'chat_id': this.chatId })).catch(() => {});
    }
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.onChange = (): void => {};
    this.messages = [];
  }

  find(id: number): MsgItem | undefined {
    return this.messages.find((m: MsgItem) => m.id === id);
  }

  private merge(list: TdObject[]): void {
    const byId = new Map<number, MsgItem>();
    for (const m of this.messages) {
      byId.set(m.id, m);
    }
    for (const raw of list) {
      const id = raw['id'] as number;
      const existing = byId.get(id);
      byId.set(id, existing ? this.refill(existing, raw) : this.parse(raw));
    }
    this.messages = Array.from(byId.values()).sort((a: MsgItem, b: MsgItem) => a.id - b.id);
  }

  private history(from: number, offset: number, limit: number): Promise<TdObject[]> {
    const req = this.topicId ?
      o({ '@type': 'getForumTopicHistory', 'chat_id': this.chatId, 'forum_topic_id': this.topicId,
        'from_message_id': from, 'offset': offset, 'limit': limit }) :
      o({ '@type': 'getChatHistory', 'chat_id': this.chatId, 'from_message_id': from,
        'offset': offset, 'limit': limit, 'only_local': false });
    return this.core.td.send(req).then((res: TdObject) =>
      this.opened ? ((res['messages'] as TdObject[]) ?? []).filter((m: TdObject) => m !== null) : []);
  }

  // TDLib may return short pages while it fetches from the server, so only an
  // empty page ends the history.
  loadOlder(): void {
    if (this.loading || this.olderDone || !this.opened) {
      return;
    }
    this.loading = true;
    let more = false;
    const gen = this.gen;
    const from = this.messages.length > 0 ? this.messages[0].id : 0;
    this.history(from, 0, PAGE).then((list: TdObject[]) => {
      if (gen !== this.gen) {
        return;
      }
      if (list.length === 0 || (list.length === 1 && (list[0]['id'] as number) === from)) {
        this.olderDone = true;
      }
      this.merge(list);
      this.notify('messages');
      more = true;
    }).catch(() => {
      // Still announce, so the view can leave its loading state.
      this.notify('messages');
    }).finally(() => {
      if (gen === this.gen) {
        this.loading = false;
        if (more) {
          this.fill();
        }
      }
    });
  }

  loadNewer(): void {
    if (this.loading || this.atLatest || this.messages.length === 0 || !this.opened) {
      return;
    }
    this.loading = true;
    const gen = this.gen;
    const last = this.messages[this.messages.length - 1].id;
    this.history(last, -PAGE + 1, PAGE).then((list: TdObject[]) => {
      if (gen !== this.gen) {
        return;
      }
      const before = this.messages.length;
      this.merge(list);
      if (this.messages.length === before) {
        this.atLatest = true;
      }
      this.notify('messages');
    }).catch(() => {}).finally(() => {
      if (gen === this.gen) {
        this.loading = false;
        this.fill();
      }
    });
  }

  private fill(): void {
    if (this.messages.length < MIN_FILL && !this.olderDone) {
      this.loadOlder();
    }
  }

  // Replaces the window with the messages around `id`. `readUpTo` > 0 marks
  // the read position: the first later incoming message becomes firstUnreadId.
  private loadAround(id: number, readUpTo: number): Promise<boolean> {
    const gen = ++this.gen;
    this.loading = true;
    return this.history(id, -PAGE / 2, PAGE).then((list: TdObject[]) => {
      if (gen !== this.gen) {
        return false;
      }
      this.loading = false;
      if (list.length === 0) {
        if (readUpTo) {
          this.loadOlder();
        }
        return false;
      }
      this.messages = [];
      this.merge(list);
      this.olderDone = false;
      // Whether this window reaches the newest message is settled by the
      // loadNewer() below: it finds nothing newer when it does.
      this.atLatest = false;
      if (readUpTo) {
        const first = this.messages.find((m: MsgItem) => m.id > readUpTo && !m.outgoing);
        this.firstUnreadId = first ? first.id : 0;
      }
      this.notify('messages');
      // A short window may not fill the screen, so no scroll would ask for
      // the next page; fetch it once now. It also settles atLatest.
      this.loadNewer();
      return this.find(id) !== undefined;
    }).catch(() => {
      if (gen === this.gen) {
        this.loading = false;
      }
      return false;
    });
  }

  // Re-announces the list, e.g. after the chat's read position moved.
  touch(): void {
    this.notify('messages');
  }

  jumpTo(id: number): Promise<boolean> {
    if (this.find(id)) {
      return Promise.resolve(true);
    }
    return this.loadAround(id, 0);
  }

  jumpToLatest(): void {
    if (this.atLatest) {
      return;
    }
    this.gen++;
    this.messages = [];
    this.atLatest = true;
    this.olderDone = false;
    this.loading = false;
    this.loadOlder();
  }

  // Tells TDLib which messages are on screen; it advances the read position
  // to the newest of them and counts channel views.
  view(ids: number[]): void {
    if (!this.core.readReceipts || !this.opened || ids.length === 0) {
      return;
    }
    this.core.td.send(o({
      '@type': 'viewMessages', 'chat_id': this.chatId, 'message_ids': ids,
      'source': o({ '@type': this.topicId ? 'messageSourceForumTopicHistory' : 'messageSourceChatHistory' }),
      'force_read': false
    })).catch(() => {});
  }

  refreshPinned(): void {
    this.core.td.send(o({ '@type': 'getChatPinnedMessage', 'chat_id': this.chatId })).then((raw: TdObject) => {
      this.pinned = this.parse(raw);
      this.notify('pinned');
    }).catch(() => {
      this.pinned = null;
      this.notify('pinned');
    });
  }

  fetch(chatId: number, id: number): Promise<MsgItem> {
    return this.core.td.send(o({ '@type': 'getMessage', 'chat_id': chatId, 'message_id': id }))
      .then((raw: TdObject) => this.parse(raw));
  }

  // ---- Sending ----

  private request(type: string, opts: SendOptions): TdObject {
    const req: TdObject = {
      '@type': type, 'chat_id': this.chatId,
      'options': o({ '@type': 'messageSendOptions', 'disable_notification': opts.silent })
    };
    const topic = this.topic();
    if (topic) {
      req['topic_id'] = topic;
    }
    if (opts.replyTo) {
      req['reply_to'] = o({ '@type': 'inputMessageReplyToMessage', 'message_id': opts.replyTo });
    }
    if (!this.atLatest) {
      this.jumpToLatest();
    }
    return req;
  }

  private send(content: TdObject, opts: SendOptions): Promise<TdObject> {
    const req = this.request('sendMessage', opts);
    req['input_message_content'] = content;
    return this.core.td.send(req);
  }

  // Photos and videos sent together arrive as one album (2 to 10 items).
  sendAlbum(contents: TdObject[], opts: SendOptions): Promise<TdObject> {
    if (contents.length === 1) {
      return this.send(contents[0], opts);
    }
    const req = this.request('sendMessageAlbum', opts);
    req['input_message_contents'] = contents;
    return this.core.td.send(req);
  }

  // Text is parsed as Markdown (**bold**, __italic__, `code`, [link](url)...).
  formatted(text: string): Promise<TdObject> {
    return this.core.td.send(o({
      '@type': 'parseTextEntities', 'text': text, 'parse_mode': o({ '@type': 'textParseModeMarkdown', 'version': 2 })
    })).catch(() => o({ '@type': 'formattedText', 'text': text, 'entities': [] }));
  }

  private plain(text: string): TdObject {
    return o({ '@type': 'formattedText', 'text': text, 'entities': [] });
  }

  sendText(text: string, opts: SendOptions, markdown: boolean): Promise<TdObject> {
    const p = markdown ? this.formatted(text) : Promise.resolve(this.plain(text));
    return p.then((f: TdObject) => this.send(o({ '@type': 'inputMessageText', 'text': f, 'clear_draft': true }), opts));
  }

  private local(path: string): TdObject {
    return o({ '@type': 'inputFileLocal', 'path': path });
  }

  photoContent(path: string, caption: string, spoiler: boolean, selfDestruct: number): TdObject {
    const content: TdObject = {
      '@type': 'inputMessagePhoto',
      'photo': o({ '@type': 'inputPhoto', 'photo': this.local(path), 'added_sticker_file_ids': [], 'width': 0, 'height': 0 }),
      'caption': this.plain(caption), 'has_spoiler': spoiler
    };
    if (selfDestruct) {
      content['self_destruct_type'] = o({ '@type': 'messageSelfDestructTypeTimer', 'self_destruct_time': selfDestruct });
    }
    return content;
  }

  videoContent(path: string, caption: string, w: number, h: number, duration: number): TdObject {
    return o({
      '@type': 'inputMessageVideo',
      'video': o({ '@type': 'inputVideo', 'video': this.local(path), 'added_sticker_file_ids': [],
        'duration': Math.round(duration), 'width': w, 'height': h, 'supports_streaming': true }),
      'caption': this.plain(caption), 'has_spoiler': false
    });
  }

  sendPhoto(path: string, caption: string, opts: SendOptions, spoiler: boolean, selfDestruct: number): Promise<TdObject> {
    return this.send(this.photoContent(path, caption, spoiler, selfDestruct), opts);
  }

  sendDocument(path: string, caption: string, opts: SendOptions): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessageDocument',
      'document': o({ '@type': 'inputDocument', 'document': this.local(path) }),
      'caption': this.plain(caption)
    }), opts);
  }

  sendVoice(path: string, duration: number, waveform: string, opts: SendOptions): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessageVoiceNote',
      'voice_note': o({ '@type': 'inputVoiceNote', 'voice_note': this.local(path),
        'duration': Math.max(1, Math.round(duration)), 'waveform': waveform }),
      'caption': this.plain('')
    }), opts);
  }

  sendSticker(fileId: number, opts: SendOptions): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessageSticker',
      'sticker': o({ '@type': 'inputSticker', 'sticker': o({ '@type': 'inputFileId', 'id': fileId }), 'width': 0, 'height': 0 }),
      'emoji': ''
    }), opts);
  }

  sendAnimation(fileId: number, opts: SendOptions): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessageAnimation',
      'animation': o({ '@type': 'inputAnimation', 'animation': o({ '@type': 'inputFileId', 'id': fileId }),
        'added_sticker_file_ids': [], 'duration': 0, 'width': 0, 'height': 0 }),
      'caption': this.plain('')
    }), opts);
  }

  sendLocation(lat: number, lon: number, opts: SendOptions): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessageLocation',
      'location': o({ '@type': 'location', 'latitude': lat, 'longitude': lon, 'horizontal_accuracy': 0 })
    }), opts);
  }

  sendPoll(question: string, options: string[], anonymous: boolean, multiple: boolean, opts: SendOptions): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessagePoll',
      'question': this.plain(question),
      'options': options.map((t: string) => o({ '@type': 'inputPollOption', 'text': this.plain(t) })),
      'is_anonymous': anonymous, 'allows_multiple_answers': multiple,
      'type': o({ '@type': 'inputPollTypeRegular', 'allow_adding_options': false }),
      'open_period': 0, 'close_date': 0, 'is_closed': false
    }), opts);
  }

  sendDice(emoji: string, opts: SendOptions): Promise<TdObject> {
    return this.send(o({ '@type': 'inputMessageDice', 'emoji': emoji, 'clear_draft': false }), opts);
  }

  setDraft(text: string, replyTo: number): void {
    const req: TdObject = { '@type': 'setChatDraftMessage', 'chat_id': this.chatId };
    const topic = this.topic();
    if (topic) {
      req['topic_id'] = topic;
    }
    if (text) {
      const draft: TdObject = {
        '@type': 'draftMessage', 'date': 0,
        'content': o({ '@type': 'draftMessageContentText', 'text': this.plain(text) })
      };
      if (replyTo) {
        draft['reply_to'] = o({ '@type': 'inputMessageReplyToMessage', 'message_id': replyTo });
      }
      req['draft_message'] = draft;
    }
    this.core.td.send(req).catch(() => {});
  }

  sendTyping(action: string): void {
    if (this.chatId) {
      const req: TdObject = { '@type': 'sendChatAction', 'chat_id': this.chatId, 'action': o({ '@type': action }) };
      const topic = this.topic();
      if (topic) {
        req['topic_id'] = topic;
      }
      this.core.td.send(req).catch(() => {});
    }
  }

  // ---- Message actions ----

  editText(m: MsgItem, text: string, markdown: boolean): Promise<TdObject> {
    const p = markdown ? this.formatted(text) : Promise.resolve(this.plain(text));
    return p.then((f: TdObject) => {
      if (m.kind === 'text') {
        return this.core.td.send(o({
          '@type': 'editMessageText', 'chat_id': m.chatId, 'message_id': m.id,
          'input_message_content': o({ '@type': 'inputMessageText', 'text': f, 'clear_draft': false })
        }));
      }
      return this.core.td.send(o({
        '@type': 'editMessageCaption', 'chat_id': m.chatId, 'message_id': m.id, 'caption': f
      }));
    });
  }

  remove(chatId: number, ids: number[], revoke: boolean): Promise<TdObject> {
    return this.core.td.send(o({ '@type': 'deleteMessages', 'chat_id': chatId, 'message_ids': ids, 'revoke': revoke }));
  }

  forward(toChatId: number, fromChatId: number, ids: number[], asCopy: boolean): Promise<TdObject> {
    return this.core.td.send(o({
      '@type': 'forwardMessages', 'chat_id': toChatId, 'from_chat_id': fromChatId, 'message_ids': ids,
      'options': o({ '@type': 'messageSendOptions' }), 'send_copy': asCopy, 'remove_caption': false
    }));
  }

  pin(m: MsgItem, pin: boolean): Promise<TdObject> {
    const req: TdObject = pin ?
      o({ '@type': 'pinChatMessage', 'chat_id': m.chatId, 'message_id': m.id, 'disable_notification': true,
        'only_for_self': false }) :
      o({ '@type': 'unpinChatMessage', 'chat_id': m.chatId, 'message_id': m.id });
    return this.core.td.send(req).then((r: TdObject) => {
      this.refreshPinned();
      return r;
    });
  }

  properties(m: MsgItem): Promise<TdObject> {
    return this.core.td.send(o({ '@type': 'getMessageProperties', 'chat_id': m.chatId, 'message_id': m.id }));
  }

  link(m: MsgItem): Promise<string> {
    return this.core.td.send(o({
      '@type': 'getMessageLink', 'chat_id': m.chatId, 'message_id': m.id, 'media_timestamp': 0,
      'for_album': false, 'in_message_thread': false
    })).then((r: TdObject) => r['link'] as string);
  }

  react(m: MsgItem, emoji: string): Promise<TdObject> {
    const mine = m.reactions.find((r: ReactionItem) => r.emoji === emoji && r.chosen);
    const type = o({ '@type': 'reactionTypeEmoji', 'emoji': emoji });
    return this.core.td.send(mine ?
      o({ '@type': 'removeMessageReaction', 'chat_id': m.chatId, 'message_id': m.id, 'reaction_type': type }) :
      o({ '@type': 'addMessageReaction', 'chat_id': m.chatId, 'message_id': m.id, 'reaction_type': type,
        'is_big': false, 'update_recent_reactions': true }));
  }

  availableReactions(m: MsgItem): Promise<string[]> {
    return this.core.td.send(o({ '@type': 'getMessageAvailableReactions', 'chat_id': m.chatId, 'message_id': m.id,
      'row_size': 8 })).then((r: TdObject) => {
      const out: string[] = [];
      const lists = [r['top_reactions'], r['recent_reactions'], r['popular_reactions']] as TdObject[][];
      for (const list of lists) {
        for (const a of list ?? []) {
          const t = a['type'] as TdObject;
          if (t['@type'] === 'reactionTypeEmoji' && !out.includes(t['emoji'] as string)) {
            out.push(t['emoji'] as string);
          }
        }
      }
      return out;
    });
  }

  vote(m: MsgItem, optionIds: number[]): Promise<TdObject> {
    return this.core.td.send(o({ '@type': 'setPollAnswer', 'chat_id': m.chatId, 'message_id': m.id,
      'option_ids': optionIds }));
  }

  recognizeSpeech(m: MsgItem): Promise<TdObject> {
    return this.core.td.send(o({ '@type': 'recognizeSpeech', 'chat_id': m.chatId, 'message_id': m.id }));
  }

  translate(m: MsgItem, lang: string): Promise<string> {
    return this.core.td.send(o({ '@type': 'translateMessageText', 'chat_id': m.chatId, 'message_id': m.id,
      'to_language_code': lang })).then((r: TdObject) => r['text'] as string);
  }

  // Marks self-destructing or listened-to content as opened (starts timers).
  markOpened(m: MsgItem): void {
    this.core.td.send(o({ '@type': 'openMessageContent', 'chat_id': m.chatId, 'message_id': m.id })).catch(() => {});
  }

  callback(m: MsgItem, data: string): Promise<TdObject> {
    return this.core.td.send(o({
      '@type': 'getCallbackQueryAnswer', 'chat_id': m.chatId, 'message_id': m.id,
      'payload': o({ '@type': 'callbackQueryPayloadData', 'data': data })
    }));
  }

  // Newest first. `filter` is a searchMessagesFilter* type name; `cursor` is
  // '' for the first page, then the previous page's `next`.
  search(query: string, filter: string, cursor: string): Promise<SearchPage> {
    // Secret chats are searched on the device by a separate request.
    if (this.secret && query) {
      return this.core.td.send(o({
        '@type': 'searchSecretMessages', 'chat_id': this.chatId, 'query': query, 'offset': cursor, 'limit': 50,
        'filter': o({ '@type': filter })
      })).then((r: TdObject) => this.page(r, (r['next_offset'] as string) ?? ''));
    }
    const req: TdObject = {
      '@type': 'searchChatMessages', 'chat_id': this.chatId, 'query': query,
      'from_message_id': cursor ? Number(cursor) : 0, 'offset': 0, 'limit': 50, 'filter': o({ '@type': filter })
    };
    const topic = this.topic();
    if (topic) {
      req['topic_id'] = topic;
    }
    return this.core.td.send(req).then((r: TdObject) => {
      const next = (r['next_from_message_id'] as number) ?? 0;
      return this.page(r, next ? String(next) : '');
    });
  }

  private page(r: TdObject, next: string): SearchPage {
    const p = new SearchPage();
    p.items = ((r['messages'] as TdObject[]) ?? []).filter((raw: TdObject) => raw !== null)
      .map((raw: TdObject) => this.parse(raw));
    p.total = (r['total_count'] as number) ?? p.items.length;
    p.next = p.items.length > 0 ? next : '';
    return p;
  }

  // ---- Updates for the open chat ----

  private upsert(raw: TdObject, replaceId: number = 0): void {
    if ((raw['chat_id'] as number) !== this.chatId) {
      return;
    }
    if (this.topicId) {
      const t = raw['topic_id'] as TdObject | undefined;
      if (!t || t['@type'] !== 'messageTopicForum' || (t['forum_topic_id'] as number) !== this.topicId) {
        return;
      }
    }
    const id = replaceId || (raw['id'] as number);
    const existing = this.find(id);
    if (existing) {
      this.refill(existing, raw);
    } else if (this.atLatest) {
      this.messages.push(this.parse(raw));
    } else {
      return; // a newer page will include it
    }
    this.messages = this.messages.slice().sort((a: MsgItem, b: MsgItem) => a.id - b.id);
    this.notify('messages');
  }

  private patch(u: TdObject, fn: (m: MsgItem) => void): void {
    if ((u['chat_id'] as number) !== this.chatId) {
      return;
    }
    const m = this.find(u['message_id'] as number);
    if (m) {
      fn(m);
      m.version++;
      this.messages = this.messages.slice();
      this.notify('messages');
    }
  }

  onUpdate(u: TdObject): void {
    switch (u['@type'] as string) {
      case 'updateNewMessage':
        this.upsert(u['message'] as TdObject);
        break;
      case 'updateMessageSendSucceeded':
      case 'updateMessageSendFailed':
        this.upsert(u['message'] as TdObject, u['old_message_id'] as number);
        break;
      case 'updateMessageContent':
        this.patch(u, (m: MsgItem) => {
          try {
            fillContent(m, u['new_content'] as TdObject, this.nameOf);
          } catch (e) {
            m.kind = 'unsupported';
          }
        });
        break;
      case 'updateMessageEdited':
        this.patch(u, (m: MsgItem) => { m.editDate = u['edit_date'] as number; });
        break;
      case 'updateMessageInteractionInfo':
        this.patch(u, (m: MsgItem) => fillInteraction(m, u['interaction_info'] as TdObject | undefined));
        break;
      case 'updateMessageContentOpened':
        this.patch(u, (m: MsgItem) => { m.listened = true; });
        break;
      case 'updateMessageIsPinned':
        if ((u['chat_id'] as number) === this.chatId) {
          this.refreshPinned();
        }
        break;
      case 'updateDeleteMessages': {
        if ((u['chat_id'] as number) !== this.chatId || u['from_cache']) {
          break;
        }
        const ids = new Set<number>((u['message_ids'] as number[]) ?? []);
        this.messages = this.messages.filter((m: MsgItem) => !ids.has(m.id));
        if (this.pinned && ids.has(this.pinned.id)) {
          this.refreshPinned();
        }
        this.notify('messages');
        break;
      }
      default:
        break;
    }
  }
}
