import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { API_HASH, API_ID } from '../common/Config';
import { AccountCore, AccountEvent, AccountListener } from './Core';
import { ChatStore } from './ChatStore';
import { FileStore } from './FileStore';
import { MessageStore, OpenOptions } from './MessageStore';
import { o, TdClient, TdObject } from './TdClient';
import { BotCmd, ChatItem, MsgItem, UserItem } from './Models';
import { ProxyConfig } from './Proxy';

export type ConnectionState = 'waiting' | 'proxy' | 'connecting' | 'updating' | 'ready';
// Where a t.me / tg: link leads.
export class LinkTarget {
  chatId: number = 0;
  messageId: number = 0;
  invite: string = '';       // invite link that still has to be joined
  inviteTitle: string = '';
  proxy: ProxyConfig | null = null;
  botStart: boolean = false; // a bot to start with startParam
  startParam: string = '';
}

export type AuthStep = 'loading' | 'phone' | 'code' | 'password' | 'qr' | 'email' | 'ready' | 'closed';

// One logged-in (or logging-in) Telegram account with its own TDLib client
// and database directory `tdlib/<slot>`.
export class Account implements AccountCore {
  readonly slot: number;
  td: TdClient;
  context: common.UIAbilityContext;
  myUserId: number = 0;
  authStep: AuthStep = 'loading';
  authHint: string = '';
  qrLink: string = '';
  readReceipts: boolean = true;
  connection: ConnectionState = 'connecting';
  files: FileStore;
  chats: ChatStore;
  // Chat-independent message actions (forwarding, parsing search results).
  actions: MessageStore;
  // One store per chat view currently on screen.
  private sessions: MessageStore[] = [];
  private nameOf: (id: number, isChat: boolean) => string;
  private mapFiles: Map<string, number> = new Map(); // "lat,lon" -> map image file id
  private mapAsked: Set<string> = new Set();
  private listeners: AccountListener[] = [];
  private batchTimer: number = -1;
  private pendingEvents: Set<AccountEvent> = new Set();
  onAuthChanged: (account: Account) => void = () => {};

  constructor(slot: number, context: common.UIAbilityContext) {
    this.slot = slot;
    this.context = context;
    this.td = new TdClient();
    this.files = new FileStore(this);
    this.chats = new ChatStore(this);
    this.nameOf = (id: number, isChat: boolean): string => this.chats.nameOf(id, isChat);
    this.actions = new MessageStore(this, this.nameOf);
    this.td.addListener((u: TdObject) => this.onUpdate(u));
    this.td.start();
  }

  on(l: AccountListener): void {
    this.listeners.push(l);
  }

  off(l: AccountListener): void {
    this.listeners = this.listeners.filter((x: AccountListener) => x !== l);
  }

  // Startup delivers thousands of updates; listeners get at most one call per
  // event type per frame.
  emit(event: AccountEvent): void {
    this.pendingEvents.add(event);
    if (this.batchTimer >= 0) {
      return;
    }
    this.batchTimer = setTimeout(() => {
      this.batchTimer = -1;
      const events = Array.from(this.pendingEvents);
      this.pendingEvents.clear();
      for (const e of events) {
        for (const l of this.listeners) {
          l(e);
        }
      }
    }, 16);
  }

  // A store targeting a chat for sends and searches; no history is loaded.
  store(chatId: number, topicId: number = 0, threadId: number = 0): MessageStore {
    const c = this.chats.chats.get(chatId);
    return new MessageStore(this, this.nameOf).bind(chatId, topicId, c !== undefined && c.type === 'secret', threadId);
  }

  // File id of a map image for a location message, 0 until TDLib has made
  // one; 'files' is emitted when it becomes available.
  mapFile(lat: number, lon: number, chatId: number): number {
    const key = `${lat.toFixed(5)},${lon.toFixed(5)}`;
    const known = this.mapFiles.get(key);
    if (known !== undefined) {
      return known;
    }
    if (!this.mapAsked.has(key)) {
      this.mapAsked.add(key);
      this.td.send(o({ '@type': 'getMapThumbnailFile',
        'location': o({ '@type': 'location', 'latitude': lat, 'longitude': lon, 'horizontal_accuracy': 0 }),
        'zoom': 15, 'width': 480, 'height': 240, 'scale': 2, 'chat_id': chatId })).then((f: TdObject) => {
        this.mapFiles.set(key, f['id'] as number);
        this.emit('files');
      }).catch(() => {});
    }
    return 0;
  }

  // Commands of the bots in a chat, listed when the user types '/'.
  botCommands(c: ChatItem): Promise<BotCmd[]> {
    const make = (raw: TdObject, bot: string): BotCmd => {
      const cmd = new BotCmd();
      cmd.command = raw['command'] as string;
      cmd.description = (raw['description'] as string) ?? '';
      cmd.bot = bot;
      return cmd;
    };
    if (c.type === 'private') {
      const u = this.chats.users.get(c.userId);
      if (!u || !u.isBot) {
        return Promise.resolve([]);
      }
      return this.td.send(o({ '@type': 'getUserFullInfo', 'user_id': c.userId })).then((f: TdObject) => {
        const info = f['bot_info'] as TdObject | undefined;
        return info ? ((info['commands'] as TdObject[]) ?? []).map((raw: TdObject) => make(raw, '')) : [];
      });
    }
    if (c.type !== 'group' && c.type !== 'supergroup') {
      return Promise.resolve([]);
    }
    const req = c.type === 'group' ? o({ '@type': 'getBasicGroupFullInfo', 'basic_group_id': c.groupId }) :
      o({ '@type': 'getSupergroupFullInfo', 'supergroup_id': c.groupId });
    return this.td.send(req).then((f: TdObject) => {
      const out: BotCmd[] = [];
      for (const set of (f['bot_commands'] as TdObject[]) ?? []) {
        const bot = this.chats.users.get(set['bot_user_id'] as number);
        for (const raw of (set['commands'] as TdObject[]) ?? []) {
          out.push(make(raw, bot ? bot.username : ''));
        }
      }
      return out;
    });
  }

  // Opens a chat (or one forum topic) for a view. Pair with closeSession.
  openSession(chatId: number, topicId: number, opt: OpenOptions, threadId: number = 0): MessageStore {
    const c = this.chats.chats.get(chatId);
    opt.secret = c !== undefined && c.type === 'secret';
    const s = new MessageStore(this, this.nameOf).bind(chatId, topicId, opt.secret, threadId);
    this.sessions.push(s);
    s.start(opt);
    return s;
  }

  closeSession(s: MessageStore): void {
    this.sessions = this.sessions.filter((x: MessageStore) => x !== s);
    s.stop();
  }

  isViewing(chatId: number): boolean {
    return this.sessions.some((s: MessageStore) => s.chatId === chatId);
  }

  me(): UserItem | undefined {
    return this.chats.users.get(this.myUserId);
  }

  chat(id: number): ChatItem | undefined {
    return this.chats.chats.get(id);
  }

  user(id: number): UserItem | undefined {
    return this.chats.users.get(id);
  }

  private onUpdate(u: TdObject): void {
    const type = u['@type'] as string;
    if (type === 'updateAuthorizationState') {
      this.onAuthState(u['authorization_state'] as TdObject);
      return;
    }
    if (type === 'updateConnectionState') {
      this.connection = connectionOf((u['state'] as TdObject)['@type'] as string);
      this.emit('connection');
      return;
    }
    this.files.onUpdate(u);
    this.chats.onUpdate(u);
    for (const s of this.sessions) {
      s.onUpdate(u);
      // Read ticks of outgoing messages follow the chat's read position.
      if (type === 'updateChatReadOutbox' && s.chatId === (u['chat_id'] as number)) {
        s.touch();
      }
    }
    if (type === 'updateUser' && (((u['user'] as TdObject)['id'] as number) === this.myUserId)) {
      this.emit('me');
    }
  }
  // ---- Authorization ----

  private onAuthState(state: TdObject): void {
    this.authHint = '';
    switch (state['@type'] as string) {
      case 'authorizationStateWaitTdlibParameters':
        this.sendParameters();
        return;
      case 'authorizationStateWaitPhoneNumber':
        this.authStep = 'phone';
        break;
      case 'authorizationStateWaitEmailAddress':
      case 'authorizationStateWaitEmailCode':
        this.authStep = 'email';
        this.authHint = '此账号需要先在官方客户端完成邮箱验证';
        break;
      case 'authorizationStateWaitCode': {
        this.authStep = 'code';
        this.authHint = describeCodeType((state['code_info'] as TdObject)['type'] as TdObject);
        break;
      }
      case 'authorizationStateWaitPassword':
        this.authStep = 'password';
        this.authHint = state['password_hint'] as string;
        break;
      case 'authorizationStateWaitOtherDeviceConfirmation':
        this.authStep = 'qr';
        this.qrLink = state['link'] as string;
        break;
      case 'authorizationStateReady':
        this.authStep = 'ready';
        this.td.send(o({ '@type': 'getMe' })).then((me: TdObject) => {
          this.myUserId = me['id'] as number;
          this.emit('me');
        }).catch(() => {});
        this.chats.loadMore(0);
        break;
      case 'authorizationStateClosed':
        this.authStep = 'closed';
        break;
      default:
        this.authStep = 'loading';
    }
    this.emit('auth');
    this.onAuthChanged(this);
  }

  private sendParameters(): void {
    if (!API_ID || !API_HASH) {
      this.authStep = 'closed';
      this.authHint = '未配置 Telegram API 凭证：请在 entry/src/main/ets/common/Config.ets 填写 api_id 和 api_hash 后重新编译';
      this.emit('auth');
      return;
    }
    const dir = `${this.context.filesDir}/tdlib/${this.slot}`;
    this.td.send(o({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': dir,
      'files_directory': dir,
      'database_encryption_key': '',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': true,
      'api_id': API_ID,
      'api_hash': API_HASH,
      'system_language_code': 'zh',
      'device_model': deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS',
      'system_version': deviceInfo.displayVersion || 'HarmonyOS',
      'application_version': '0.4.0'
    })).catch((e: Error) => {
      this.authHint = `初始化失败：${e.message}`;
      this.emit('auth');
    });
  }

  submitPhone(phone: string): Promise<TdObject> {
    return this.td.send(o({ '@type': 'setAuthenticationPhoneNumber', 'phone_number': phone }));
  }

  submitCode(code: string): Promise<TdObject> {
    return this.td.send(o({ '@type': 'checkAuthenticationCode', 'code': code }));
  }

  submitPassword(password: string): Promise<TdObject> {
    return this.td.send(o({ '@type': 'checkAuthenticationPassword', 'password': password }));
  }

  requestQrLogin(): Promise<TdObject> {
    return this.td.send(o({ '@type': 'requestQrCodeAuthentication', 'other_user_ids': [] }));
  }

  logOut(): Promise<TdObject> {
    return this.td.send(o({ '@type': 'logOut' }));
  }

  // ---- Chat-level actions ----

  togglePin(chat: ChatItem, folderId: number, pinned: boolean): Promise<TdObject> {
    const list = folderId === 0 ? o({ '@type': 'chatListMain' }) :
      (folderId === -1 ? o({ '@type': 'chatListArchive' }) : o({ '@type': 'chatListFolder', 'chat_folder_id': folderId }));
    return this.td.send(o({ '@type': 'toggleChatIsPinned', 'chat_list': list, 'chat_id': chat.id, 'is_pinned': pinned }));
  }

  archive(chat: ChatItem, toArchive: boolean): Promise<TdObject> {
    return this.td.send(o({ '@type': 'addChatToList', 'chat_id': chat.id,
      'chat_list': o({ '@type': toArchive ? 'chatListArchive' : 'chatListMain' }) }));
  }

  // muteFor seconds; 0 unmutes.
  mute(chat: ChatItem, muteFor: number): Promise<TdObject> {
    return this.td.send(o({ '@type': 'setChatNotificationSettings', 'chat_id': chat.id,
      'notification_settings': o({ '@type': 'chatNotificationSettings', 'use_default_mute_for': false,
        'mute_for': muteFor, 'use_default_sound': true, 'use_default_show_preview': true,
        'use_default_disable_pinned_message_notifications': true,
        'use_default_disable_mention_notifications': true }) }));
  }

  markRead(chat: ChatItem, read: boolean): Promise<TdObject> {
    if (!read) {
      return this.td.send(o({ '@type': 'toggleChatIsMarkedAsUnread', 'chat_id': chat.id, 'is_marked_as_unread': true }));
    }
    const ids = chat.lastMsgId ? [chat.lastMsgId] : [];
    return this.td.send(o({ '@type': 'viewMessages', 'chat_id': chat.id, 'message_ids': ids,
      'source': o({ '@type': 'messageSourceChatList' }), 'force_read': true })).then((r: TdObject) => {
      if (chat.markedUnread) {
        this.td.send(o({ '@type': 'toggleChatIsMarkedAsUnread', 'chat_id': chat.id, 'is_marked_as_unread': false }))
          .catch(() => {});
      }
      return r;
    });
  }

  deleteChat(chat: ChatItem, forAll: boolean): Promise<TdObject> {
    if (chat.type === 'secret') {
      return this.td.send(o({ '@type': 'closeSecretChat', 'secret_chat_id': chat.secretChatId })).then(() =>
        this.td.send(o({ '@type': 'deleteChatHistory', 'chat_id': chat.id, 'remove_from_chat_list': true, 'revoke': true })));
    }
    if (chat.type === 'private') {
      return this.td.send(o({ '@type': 'deleteChatHistory', 'chat_id': chat.id, 'remove_from_chat_list': true,
        'revoke': forAll }));
    }
    return this.td.send(o({ '@type': 'leaveChat', 'chat_id': chat.id }));
  }

  clearHistory(chat: ChatItem, forAll: boolean): Promise<TdObject> {
    return this.td.send(o({ '@type': 'deleteChatHistory', 'chat_id': chat.id, 'remove_from_chat_list': false,
      'revoke': forAll }));
  }

  // Resolves the new secret chat's chat id.
  startSecretChat(userId: number): Promise<number> {
    return this.td.send(o({ '@type': 'createNewSecretChat', 'user_id': userId }))
      .then((c: TdObject) => c['id'] as number);
  }

  privateChatWith(userId: number): Promise<number> {
    return this.td.send(o({ '@type': 'createPrivateChat', 'user_id': userId, 'force': false }))
      .then((c: TdObject) => c['id'] as number);
  }

  setAutoDelete(chat: ChatItem, seconds: number): Promise<TdObject> {
    return this.td.send(o({ '@type': 'setChatMessageAutoDeleteTime', 'chat_id': chat.id,
      'message_auto_delete_time': seconds }));
  }

  searchChats(query: string): Promise<number[]> {
    const local = this.td.send(o({ '@type': 'searchChats', 'query': query, 'limit': 30 }));
    const remote = this.td.send(o({ '@type': 'searchPublicChats', 'query': query }))
      .catch(() => o({ 'chat_ids': [] as number[] }));
    return Promise.all([local, remote]).then((r: TdObject[]) => {
      const ids: number[] = [];
      for (const res of r) {
        for (const id of (res['chat_ids'] as number[]) ?? []) {
          if (!ids.includes(id)) {
            ids.push(id);
          }
        }
      }
      return ids;
    });
  }

  searchAllMessages(query: string): Promise<MsgItem[]> {
    return this.td.send(o({ '@type': 'searchMessages', 'chat_list': o({ '@type': 'chatListMain' }), 'query': query,
      'offset': '', 'limit': 50, 'filter': o({ '@type': 'searchMessagesFilterEmpty' }), 'min_date': 0, 'max_date': 0 }))
      .then((r: TdObject) => ((r['messages'] as TdObject[]) ?? []).map((raw: TdObject) =>
        this.actions.fetchParsed(raw)));
  }

  openLink(url: string): Promise<LinkTarget> {
    const target = new LinkTarget();
    return this.td.send(o({ '@type': 'getInternalLinkType', 'link': url })).then((t: TdObject) => {
      switch (t['@type'] as string) {
        case 'internalLinkTypePublicChat':
          return this.td.send(o({ '@type': 'searchPublicChat', 'username': t['chat_username'] as string }))
            .then((c: TdObject) => {
              target.chatId = c['id'] as number;
              return target;
            });
        case 'internalLinkTypeChatInvite': {
          const link = t['invite_link'] as string;
          return this.td.send(o({ '@type': 'checkChatInviteLink', 'invite_link': link })).then((info: TdObject) => {
            // chat_id is set when the chat can already be opened (a member, or a public chat).
            target.chatId = (info['chat_id'] as number) ?? 0;
            if (!target.chatId) {
              target.invite = link;
              target.inviteTitle = (info['title'] as string) ?? '';
            }
            return target;
          });
        }
        case 'internalLinkTypeMessage':
          return this.td.send(o({ '@type': 'getMessageLinkInfo', 'url': url })).then((info: TdObject) => {
            target.chatId = (info['chat_id'] as number) ?? 0;
            const m = info['message'] as TdObject | undefined;
            target.messageId = m ? m['id'] as number : 0;
            return target;
          });
        case 'internalLinkTypeBotStart':
          return this.td.send(o({ '@type': 'searchPublicChat', 'username': t['bot_username'] as string }))
            .then((c: TdObject) => {
              target.chatId = c['id'] as number;
              target.botStart = true;
              target.startParam = (t['start_parameter'] as string) ?? '';
              return target;
            });
        case 'internalLinkTypeProxy': {
          const p = t['proxy'] as TdObject | undefined;
          target.proxy = p ? ProxyConfig.fromTd(p) : null;
          return target;
        }
        default:
          return target;
      }
    });
  }

  // Resolves the joined chat's id, or 0 when a join request was sent instead.
  joinByLink(link: string): Promise<number> {
    return this.td.send(o({ '@type': 'joinChatByInviteLink', 'invite_link': link })).then((r: TdObject) =>
      r['@type'] === 'chatJoinResultSuccess' ? r['chat_id'] as number : 0);
  }

  join(chat: ChatItem): Promise<TdObject> {
    return this.td.send(o({ '@type': 'joinChat', 'chat_id': chat.id }));
  }

  // True when the account has left (or never joined) this supergroup or channel.
  notMember(chat: ChatItem): Promise<boolean> {
    if (chat.type !== 'supergroup' && chat.type !== 'channel') {
      return Promise.resolve(false);
    }
    return this.td.send(o({ '@type': 'getSupergroup', 'supergroup_id': chat.groupId })).then((sg: TdObject) =>
      ((sg['status'] as TdObject)['@type'] as string) === 'chatMemberStatusLeft');
  }

  send(req: TdObject): Promise<TdObject> {
    return this.td.send(req);
  }
}

function connectionOf(type: string): ConnectionState {
  switch (type) {
    case 'connectionStateWaitingForNetwork': return 'waiting';
    case 'connectionStateConnectingToProxy': return 'proxy';
    case 'connectionStateConnecting': return 'connecting';
    case 'connectionStateUpdating': return 'updating';
    default: return 'ready';
  }
}

function describeCodeType(type: TdObject): string {
  switch (type['@type'] as string) {
    case 'authenticationCodeTypeTelegramMessage':
      return '验证码已发送到你其他设备上的 Telegram';
    case 'authenticationCodeTypeSms':
    case 'authenticationCodeTypeSmsWord':
    case 'authenticationCodeTypeSmsPhrase':
      return '验证码已通过短信发送';
    case 'authenticationCodeTypeCall':
    case 'authenticationCodeTypeFlashCall':
    case 'authenticationCodeTypeMissedCall':
      return '验证码将通过电话告知';
    case 'authenticationCodeTypeFragment':
      return '验证码已发送到 Fragment';
    default:
      return '请输入收到的验证码';
  }
}
