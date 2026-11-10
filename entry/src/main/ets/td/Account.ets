import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { API_HASH, API_ID } from '../common/Config';
import { AccountCore, AccountEvent, AccountListener } from './Core';
import { ChatStore } from './ChatStore';
import { FileStore } from './FileStore';
import { MessageStore } from './MessageStore';
import { o, TdClient, TdObject } from './TdClient';
import { ChatItem, MsgItem, UserItem } from './Models';

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
  files: FileStore;
  chats: ChatStore;
  messages: MessageStore;
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
    const nameOf = (id: number, isChat: boolean): string => this.chats.nameOf(id, isChat);
    this.messages = new MessageStore(this, nameOf);
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
    this.files.onUpdate(u);
    this.chats.onUpdate(u);
    this.messages.onUpdate(u);
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
      'application_version': '1.0.0'
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
        this.messages.fetchParsed(raw)));
  }

  openLink(url: string): Promise<number> {
    return this.td.send(o({ '@type': 'getInternalLinkType', 'link': url })).then((t: TdObject) => {
      if (t['@type'] === 'internalLinkTypePublicChat') {
        return this.td.send(o({ '@type': 'searchPublicChat', 'username': t['chat_username'] as string }))
          .then((c: TdObject) => c['id'] as number);
      }
      if (t['@type'] === 'internalLinkTypeChatInvite') {
        return this.td.send(o({ '@type': 'joinChatByInviteLink', 'invite_link': t['invite_link'] as string }))
          .then(() => this.td.send(o({ '@type': 'checkChatInviteLink', 'invite_link': t['invite_link'] as string })))
          .then((info: TdObject) => info['chat_id'] as number);
      }
      if (t['@type'] === 'internalLinkTypeMessage') {
        return this.td.send(o({ '@type': 'getMessageLinkInfo', 'url': url }))
          .then((info: TdObject) => info['chat_id'] as number);
      }
      return 0;
    });
  }

  join(chat: ChatItem): Promise<TdObject> {
    return this.td.send(o({ '@type': 'joinChat', 'chat_id': chat.id }));
  }

  send(req: TdObject): Promise<TdObject> {
    return this.td.send(req);
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
