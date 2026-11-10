import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { API_HASH, API_ID } from '../common/Config';
import { TdClient, TdObject } from './TdClient';
import { ChatItem, contentSummary, fillMessage, localPath, MsgItem } from './Models';

export type AuthStep = 'loading' | 'phone' | 'code' | 'password' | 'qr' | 'ready' | 'closed';
export type StoreEvent = 'auth' | 'chats' | 'messages' | 'files';
type StoreListener = (event: StoreEvent) => void;

const CHAT_PAGE = 50;

// Gives nested TDLib object literals an explicit type, as ArkTS requires.
function o(obj: TdObject): TdObject {
  return obj;
}
const HISTORY_PAGE = 40;

// Holds the client-side view of TDLib state that the UI renders: auth step,
// the main chat list, user names, downloaded file paths and the open chat.
export class Store {
  private static instance: Store | null = null;
  private td: TdClient = TdClient.get();
  private context: common.UIAbilityContext | null = null;
  private listeners: StoreListener[] = [];

  authStep: AuthStep = 'loading';
  authHint: string = '';
  qrLink: string = '';
  myUserId: number = 0;

  private chats: Map<number, ChatItem> = new Map();
  private users: Map<number, string> = new Map();
  private files: Map<number, string> = new Map();
  private requestedFiles: Set<number> = new Set();
  private allChatsLoaded: boolean = false;

  openChatId: number = 0;
  messages: MsgItem[] = []; // ascending by id
  historyDone: boolean = false;
  private loadingHistory: boolean = false;

  static get(): Store {
    if (!Store.instance) {
      Store.instance = new Store();
    }
    return Store.instance;
  }

  init(context: common.UIAbilityContext): void {
    if (this.context) {
      return;
    }
    this.context = context;
    this.td.addListener((u: TdObject) => this.onUpdate(u));
  }

  on(listener: StoreListener): void {
    this.listeners.push(listener);
  }

  off(listener: StoreListener): void {
    this.listeners = this.listeners.filter((l) => l !== listener);
  }

  private emit(event: StoreEvent): void {
    for (const l of this.listeners) {
      l(event);
    }
  }
  // ---- Authorization ----

  private onAuthState(state: TdObject): void {
    const type = state['@type'] as string;
    this.authHint = '';
    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        this.sendParameters();
        return;
      case 'authorizationStateWaitPhoneNumber':
        this.authStep = 'phone';
        break;
      case 'authorizationStateWaitCode': {
        const info = state['code_info'] as TdObject;
        this.authStep = 'code';
        this.authHint = describeCodeType(info['type'] as TdObject);
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
        this.td.send({ '@type': 'getMe' }).then((me: TdObject) => {
          this.myUserId = me['id'] as number;
        }).catch(() => {});
        this.loadMoreChats();
        break;
      case 'authorizationStateClosed':
        this.authStep = 'closed';
        break;
      default:
        this.authStep = 'loading';
    }
    this.emit('auth');
  }

  private sendParameters(): void {
    if (!API_ID || !API_HASH) {
      this.authStep = 'closed';
      this.authHint = '未配置 Telegram API 凭证：请在 entry/src/main/ets/common/Config.ets 填写 api_id 和 api_hash 后重新编译';
      this.emit('auth');
      return;
    }
    const dir = this.context!.filesDir + '/tdlib';
    this.td.send({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': dir,
      'files_directory': dir,
      'database_encryption_key': '',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': API_ID,
      'api_hash': API_HASH,
      'system_language_code': 'zh',
      'device_model': deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS',
      'system_version': deviceInfo.displayVersion || 'HarmonyOS',
      'application_version': '1.0.0'
    }).catch((e: Error) => {
      this.authHint = `初始化失败：${e.message}`;
      this.emit('auth');
    });
  }

  submitPhone(phone: string): Promise<TdObject> {
    return this.td.send({ '@type': 'setAuthenticationPhoneNumber', 'phone_number': phone });
  }

  submitCode(code: string): Promise<TdObject> {
    return this.td.send({ '@type': 'checkAuthenticationCode', 'code': code });
  }

  submitPassword(password: string): Promise<TdObject> {
    return this.td.send({ '@type': 'checkAuthenticationPassword', 'password': password });
  }

  requestQrLogin(): Promise<TdObject> {
    return this.td.send({ '@type': 'requestQrCodeAuthentication', 'other_user_ids': [] });
  }

  logOut(): Promise<TdObject> {
    return this.td.send({ '@type': 'logOut' });
  }
  // ---- Chat list ----

  sortedChats(): ChatItem[] {
    const list: ChatItem[] = [];
    this.chats.forEach((c: ChatItem) => {
      if (c.order !== '0') {
        list.push(c);
      }
    });
    list.sort((a: ChatItem, b: ChatItem) => {
      const x = BigInt(a.order);
      const y = BigInt(b.order);
      return x === y ? 0 : (x > y ? -1 : 1);
    });
    return list;
  }

  chat(id: number): ChatItem | undefined {
    return this.chats.get(id);
  }

  loadMoreChats(): void {
    if (this.allChatsLoaded) {
      return;
    }
    this.td.send({ '@type': 'loadChats', 'chat_list': o({ '@type': 'chatListMain' }), 'limit': CHAT_PAGE })
      .catch((e: Error) => {
        // Error 404 means every chat of the list is already known.
        this.allChatsLoaded = true;
      });
  }

  private applyPositions(chat: ChatItem, positions: TdObject[]): void {
    for (const p of positions) {
      if ((p['list'] as TdObject)['@type'] === 'chatListMain') {
        chat.order = String(p['order']);
        chat.isPinned = p['is_pinned'] as boolean;
      }
    }
  }

  private setLastMessage(chat: ChatItem, msg: TdObject | undefined): void {
    if (!msg) {
      chat.lastText = '';
      return;
    }
    chat.lastText = contentSummary(msg['content'] as TdObject);
    chat.lastDate = msg['date'] as number;
  }

  userName(id: number): string {
    return this.users.get(id) ?? '';
  }

  // ---- Files ----

  // Returns the local path if already downloaded; otherwise starts a download
  // and emits 'files' once it completes.
  filePath(fileId: number, priority: number = 1): string {
    if (!fileId) {
      return '';
    }
    const path = this.files.get(fileId);
    if (path) {
      return path;
    }
    if (!this.requestedFiles.has(fileId)) {
      this.requestedFiles.add(fileId);
      this.td.send({
        '@type': 'downloadFile', 'file_id': fileId, 'priority': priority,
        'offset': 0, 'limit': 0, 'synchronous': false
      }).catch(() => this.requestedFiles.delete(fileId));
    }
    return '';
  }

  // Local path of a file already downloaded in this session; never downloads.
  knownPath(fileId: number): string {
    return fileId ? (this.files.get(fileId) ?? '') : '';
  }

  private onFile(file: TdObject): void {
    const path = localPath(file);
    if (path) {
      this.files.set(file['id'] as number, path);
      this.emit('files');
    }
  }
  // ---- Open chat and messages ----

  openChat(chatId: number): void {
    if (this.openChatId) {
      this.closeChat();
    }
    this.openChatId = chatId;
    this.messages = [];
    this.historyDone = false;
    this.td.send({ '@type': 'openChat', 'chat_id': chatId }).catch(() => {});
    this.loadOlder();
  }

  closeChat(): void {
    if (this.openChatId) {
      this.td.send({ '@type': 'closeChat', 'chat_id': this.openChatId }).catch(() => {});
    }
    this.openChatId = 0;
    this.messages = [];
  }

  // Loads the page older than the oldest loaded message. TDLib may return
  // fewer messages than asked while it fetches from the server, so an empty
  // page is the only end-of-history signal.
  loadOlder(): void {
    if (this.loadingHistory || this.historyDone || !this.openChatId) {
      return;
    }
    this.loadingHistory = true;
    const chatId = this.openChatId;
    const from = this.messages.length > 0 ? this.messages[0].id : 0;
    this.td.send({
      '@type': 'getChatHistory', 'chat_id': chatId, 'from_message_id': from,
      'offset': 0, 'limit': HISTORY_PAGE, 'only_local': false
    }).then((res: TdObject) => {
      this.loadingHistory = false;
      if (chatId !== this.openChatId) {
        return;
      }
      const list = (res['messages'] as TdObject[]) ?? [];
      if (list.length === 0) {
        this.historyDone = true;
      }
      const older: MsgItem[] = [];
      for (const m of list) {
        if (!this.messages.find((x: MsgItem) => x.id === (m['id'] as number))) {
          older.push(fillMessage(new MsgItem(), m));
        }
      }
      older.sort((a: MsgItem, b: MsgItem) => a.id - b.id);
      this.messages = older.concat(this.messages);
      this.markRead();
      this.emit('messages');
    }).catch(() => {
      this.loadingHistory = false;
    });
  }

  private markRead(): void {
    if (!this.openChatId || this.messages.length === 0) {
      return;
    }
    this.td.send({
      '@type': 'viewMessages', 'chat_id': this.openChatId,
      'message_ids': [this.messages[this.messages.length - 1].id],
      'source': o({ '@type': 'messageSourceChatHistory' }), 'force_read': true
    }).catch(() => {});
  }

  findMessage(id: number): MsgItem | undefined {
    return this.messages.find((m: MsgItem) => m.id === id);
  }

  // Fetches a replied-to message that is not in the loaded window.
  fetchMessage(chatId: number, id: number): Promise<MsgItem> {
    return this.td.send({ '@type': 'getMessage', 'chat_id': chatId, 'message_id': id })
      .then((m: TdObject) => fillMessage(new MsgItem(), m));
  }

  sendText(text: string, replyTo: number): Promise<TdObject> {
    return this.sendContent({
      '@type': 'inputMessageText',
      'text': o({ '@type': 'formattedText', 'text': text, 'entities': [] }),
      'clear_draft': true
    }, replyTo);
  }

  sendPhoto(path: string, caption: string, replyTo: number): Promise<TdObject> {
    return this.sendContent({
      '@type': 'inputMessagePhoto',
      'photo': o({ '@type': 'inputPhoto', 'photo': o({ '@type': 'inputFileLocal', 'path': path }),
        'added_sticker_file_ids': [], 'width': 0, 'height': 0 }),
      'caption': o({ '@type': 'formattedText', 'text': caption, 'entities': [] })
    }, replyTo);
  }

  sendDocument(path: string, caption: string, replyTo: number): Promise<TdObject> {
    return this.sendContent({
      '@type': 'inputMessageDocument',
      'document': o({ '@type': 'inputDocument', 'document': o({ '@type': 'inputFileLocal', 'path': path }) }),
      'caption': o({ '@type': 'formattedText', 'text': caption, 'entities': [] })
    }, replyTo);
  }

  private sendContent(content: TdObject, replyTo: number): Promise<TdObject> {
    const req: TdObject = { '@type': 'sendMessage', 'chat_id': this.openChatId, 'input_message_content': content };
    if (replyTo) {
      req['reply_to'] = o({ '@type': 'inputMessageReplyToMessage', 'message_id': replyTo });
    }
    return this.td.send(req);
  }

  private upsertMessage(msg: TdObject, replaceId: number = 0): void {
    if ((msg['chat_id'] as number) !== this.openChatId) {
      return;
    }
    const id = replaceId || (msg['id'] as number);
    const idx = this.messages.findIndex((m: MsgItem) => m.id === id);
    if (idx >= 0) {
      fillMessage(this.messages[idx], msg);
      this.messages = this.messages.slice();
    } else {
      this.messages = this.messages.concat([fillMessage(new MsgItem(), msg)]);
      this.markRead();
    }
    this.messages.sort((a: MsgItem, b: MsgItem) => a.id - b.id);
    this.emit('messages');
  }
  // ---- TDLib updates ----

  private onUpdate(u: TdObject): void {
    switch (u['@type'] as string) {
      case 'updateAuthorizationState':
        this.onAuthState(u['authorization_state'] as TdObject);
        break;
      case 'updateNewChat': {
        const c = u['chat'] as TdObject;
        const item = new ChatItem();
        item.id = c['id'] as number;
        item.title = c['title'] as string;
        item.unread = c['unread_count'] as number;
        const type = c['type'] as TdObject;
        if (type['@type'] === 'chatTypePrivate') {
          item.privateUserId = type['user_id'] as number;
        }
        const photo = c['photo'] as TdObject | undefined;
        if (photo) {
          const small = photo['small'] as TdObject;
          item.photoFileId = small['id'] as number;
          item.photoPath = localPath(small);
        }
        this.applyPositions(item, (c['positions'] as TdObject[]) ?? []);
        this.setLastMessage(item, c['last_message'] as TdObject | undefined);
        this.chats.set(item.id, item);
        this.emit('chats');
        break;
      }
      case 'updateChatTitle':
        this.patchChat(u, (c: ChatItem) => { c.title = u['title'] as string; });
        break;
      case 'updateChatPhoto':
        this.patchChat(u, (c: ChatItem) => {
          const photo = u['photo'] as TdObject | undefined;
          const small = photo ? photo['small'] as TdObject : undefined;
          c.photoFileId = small ? small['id'] as number : 0;
          c.photoPath = small ? localPath(small) : '';
        });
        break;
      case 'updateChatPosition':
        this.patchChat(u, (c: ChatItem) => { this.applyPositions(c, [u['position'] as TdObject]); });
        break;
      case 'updateChatLastMessage':
        this.patchChat(u, (c: ChatItem) => {
          this.setLastMessage(c, u['last_message'] as TdObject | undefined);
          this.applyPositions(c, (u['positions'] as TdObject[]) ?? []);
        });
        break;
      case 'updateChatReadInbox':
        this.patchChat(u, (c: ChatItem) => { c.unread = u['unread_count'] as number; });
        break;
      case 'updateUser': {
        const user = u['user'] as TdObject;
        const name = `${user['first_name'] as string} ${user['last_name'] as string}`.trim();
        this.users.set(user['id'] as number, name);
        break;
      }
      case 'updateFile':
        this.onFile(u['file'] as TdObject);
        break;
      case 'updateNewMessage':
        this.upsertMessage(u['message'] as TdObject);
        break;
      case 'updateMessageSendSucceeded':
      case 'updateMessageSendFailed':
        this.upsertMessage(u['message'] as TdObject, u['old_message_id'] as number);
        break;
      case 'updateMessageContent': {
        if ((u['chat_id'] as number) !== this.openChatId) {
          break;
        }
        const m = this.findMessage(u['message_id'] as number);
        if (m) {
          this.td.send({ '@type': 'getMessage', 'chat_id': this.openChatId, 'message_id': m.id })
            .then((full: TdObject) => this.upsertMessage(full)).catch(() => {});
        }
        break;
      }
      case 'updateDeleteMessages': {
        if ((u['chat_id'] as number) !== this.openChatId || u['from_cache']) {
          break;
        }
        const ids = new Set<number>((u['message_ids'] as number[]) ?? []);
        this.messages = this.messages.filter((m: MsgItem) => !ids.has(m.id));
        this.emit('messages');
        break;
      }
      default:
        break;
    }
  }

  private patchChat(u: TdObject, fn: (c: ChatItem) => void): void {
    const c = this.chats.get(u['chat_id'] as number);
    if (c) {
      fn(c);
      this.emit('chats');
    } else {
      hilog.debug(0x0000, 'tdgram', 'update for unknown chat');
    }
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
