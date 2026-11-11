import { AccountCore } from './Core';
import { o, TdObject } from './TdClient';
import { MsgItem, ReactionItem } from './Models';
import { fillContent, fillInteraction, fillMessage, NameOf } from './Parse';
import { hilog } from '@kit.PerformanceAnalysisKit';

const PAGE = 40;

export interface SendOptions {
  replyTo: number;
  silent: boolean;
}

// Messages of the open chat, plus every message-level action.
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
  readReceipts: boolean = true;
  private loading: boolean = false;

  constructor(core: AccountCore, nameOf: NameOf) {
    this.core = core;
    this.nameOf = nameOf;
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

  private session: number = 0;

  // Returns a session token for close(). In split view the next chat can
  // open before the previous view is torn down; a stale close is ignored.
  open(chatId: number, topicId: number = 0): number {
    this.closeChat();
    this.session++;
    this.chatId = chatId;
    this.topicId = topicId;
    this.messages = [];
    this.olderDone = false;
    this.atLatest = true;
    this.pinned = null;
    this.core.td.send(o({ '@type': 'openChat', 'chat_id': chatId })).catch(() => {});
    this.loadOlder();
    this.refreshPinned();
    return this.session;
  }

  close(session: number): void {
    if (session === this.session) {
      this.closeChat();
    }
  }

  private closeChat(): void {
    if (this.chatId) {
      this.core.td.send(o({ '@type': 'closeChat', 'chat_id': this.chatId })).catch(() => {});
    }
    this.chatId = 0;
    this.topicId = 0;
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
    const chatId = this.chatId;
    const topicId = this.topicId;
    const req = topicId ?
      o({ '@type': 'getForumTopicHistory', 'chat_id': chatId, 'forum_topic_id': topicId, 'from_message_id': from,
        'offset': offset, 'limit': limit }) :
      o({ '@type': 'getChatHistory', 'chat_id': chatId, 'from_message_id': from,
        'offset': offset, 'limit': limit, 'only_local': false });
    return this.core.td.send(req).then((res: TdObject) =>
      chatId === this.chatId && topicId === this.topicId ? ((res['messages'] as TdObject[]) ?? []) : []);
  }

  // TDLib may return short pages while it fetches from the server, so only an
  // empty page ends the history.
  loadOlder(): void {
    if (this.loading || this.olderDone || !this.chatId) {
      return;
    }
    this.loading = true;
    const from = this.messages.length > 0 ? this.messages[0].id : 0;
    this.history(from, 0, PAGE).then((list: TdObject[]) => {
      if (list.length === 0 || (list.length === 1 && (list[0]['id'] as number) === from)) {
        this.olderDone = true;
      }
      this.merge(list);
      this.markRead();
      this.core.emit('messages');
    }).catch(() => {}).finally(() => {
      this.loading = false;
    });
  }

  loadNewer(): void {
    if (this.loading || this.atLatest || this.messages.length === 0) {
      return;
    }
    this.loading = true;
    const last = this.messages[this.messages.length - 1].id;
    this.history(last, -PAGE + 1, PAGE).then((list: TdObject[]) => {
      const before = this.messages.length;
      this.merge(list);
      if (this.messages.length === before) {
        this.atLatest = true;
      }
      this.markRead();
      this.core.emit('messages');
    }).catch(() => {}).finally(() => {
      this.loading = false;
    });
  }

  // Replaces the window with messages around `id`. Resolves when loaded.
  jumpTo(id: number): Promise<boolean> {
    if (this.find(id)) {
      return Promise.resolve(true);
    }
    return this.history(id, -PAGE / 2, PAGE).then((list: TdObject[]) => {
      if (list.length === 0) {
        return false;
      }
      this.messages = [];
      this.merge(list);
      this.atLatest = false;
      this.olderDone = false;
      this.core.emit('messages');
      return this.find(id) !== undefined;
    });
  }

  jumpToLatest(): void {
    if (this.atLatest) {
      return;
    }
    this.messages = [];
    this.atLatest = true;
    this.olderDone = false;
    this.loadOlder();
  }

  markRead(): void {
    if (!this.readReceipts || !this.chatId || this.messages.length === 0 || !this.atLatest) {
      return;
    }
    this.core.td.send(o({
      '@type': 'viewMessages', 'chat_id': this.chatId,
      'message_ids': [this.messages[this.messages.length - 1].id],
      'source': o({ '@type': this.topicId ? 'messageSourceForumTopicHistory' : 'messageSourceChatHistory' }),
      'force_read': true
    })).catch(() => {});
  }

  refreshPinned(): void {
    const chatId = this.chatId;
    this.core.td.send(o({ '@type': 'getChatPinnedMessage', 'chat_id': chatId })).then((raw: TdObject) => {
      if (chatId === this.chatId) {
        this.pinned = this.parse(raw);
        this.core.emit('pinned');
      }
    }).catch(() => {
      if (chatId === this.chatId) {
        this.pinned = null;
        this.core.emit('pinned');
      }
    });
  }

  fetch(chatId: number, id: number): Promise<MsgItem> {
    return this.core.td.send(o({ '@type': 'getMessage', 'chat_id': chatId, 'message_id': id }))
      .then((raw: TdObject) => this.parse(raw));
  }
  // ---- Sending ----

  private send(content: TdObject, opts: SendOptions): Promise<TdObject> {
    const req: TdObject = {
      '@type': 'sendMessage', 'chat_id': this.chatId, 'input_message_content': content,
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

  sendPhoto(path: string, caption: string, opts: SendOptions, spoiler: boolean, selfDestruct: number): Promise<TdObject> {
    const content: TdObject = {
      '@type': 'inputMessagePhoto',
      'photo': o({ '@type': 'inputPhoto', 'photo': this.local(path), 'added_sticker_file_ids': [], 'width': 0, 'height': 0 }),
      'caption': this.plain(caption), 'has_spoiler': spoiler
    };
    if (selfDestruct) {
      content['self_destruct_type'] = o({ '@type': 'messageSelfDestructTypeTimer', 'self_destruct_time': selfDestruct });
    }
    return this.send(content, opts);
  }

  sendVideo(path: string, caption: string, opts: SendOptions, w: number, h: number, duration: number,
    spoiler: boolean): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessageVideo',
      'video': o({ '@type': 'inputVideo', 'video': this.local(path), 'added_sticker_file_ids': [],
        'duration': Math.round(duration), 'width': w, 'height': h, 'supports_streaming': true }),
      'caption': this.plain(caption), 'has_spoiler': spoiler
    }), opts);
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
      'location': o({ '@type': 'location', 'latitude': lat, 'longitude': lon, 'horizontal_accuracy': 0 }),
      'live_period': 0, 'heading': 0, 'proximity_alert_radius': 0
    }), opts);
  }

  sendPoll(question: string, options: string[], anonymous: boolean, multiple: boolean, opts: SendOptions): Promise<TdObject> {
    return this.send(o({
      '@type': 'inputMessagePoll',
      'question': this.plain(question),
      'options': options.map((t: string) => o({ '@type': 'inputPollOption', 'text': this.plain(t) })),
      'is_anonymous': anonymous, 'allows_multiple_answers': multiple,
      'type': o({ '@type': 'pollTypeRegular' }), 'open_period': 0, 'close_date': 0, 'is_closed': false
    }), opts);
  }

  sendDice(emoji: string, opts: SendOptions): Promise<TdObject> {
    return this.send(o({ '@type': 'inputMessageDice', 'emoji': emoji, 'clear_draft': false }), opts);
  }

  setDraft(chatId: number, text: string, replyTo: number): void {
    const req: TdObject = { '@type': 'setChatDraftMessage', 'chat_id': chatId };
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
  opened(m: MsgItem): void {
    this.core.td.send(o({ '@type': 'openMessageContent', 'chat_id': m.chatId, 'message_id': m.id })).catch(() => {});
  }

  callback(m: MsgItem, data: string): Promise<TdObject> {
    return this.core.td.send(o({
      '@type': 'getCallbackQueryAnswer', 'chat_id': m.chatId, 'message_id': m.id,
      'payload': o({ '@type': 'callbackQueryPayloadData', 'data': data })
    }));
  }

  search(query: string, filter: string, from: number): Promise<MsgItem[]> {
    const req: TdObject = {
      '@type': 'searchChatMessages', 'chat_id': this.chatId, 'query': query,
      'from_message_id': from, 'offset': 0, 'limit': 50, 'filter': o({ '@type': filter })
    };
    const topic = this.topic();
    if (topic) {
      req['topic_id'] = topic;
    }
    return this.core.td.send(req).then((r: TdObject) => ((r['messages'] as TdObject[]) ?? []).map((raw: TdObject) => this.parse(raw)));
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
      this.markRead();
    } else {
      return; // a newer page will include it
    }
    this.messages = this.messages.slice().sort((a: MsgItem, b: MsgItem) => a.id - b.id);
    this.core.emit('messages');
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
      this.core.emit('messages');
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
        this.core.emit('messages');
        break;
      }
      default:
        break;
    }
  }
}
