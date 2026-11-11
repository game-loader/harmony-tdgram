import { AccountCore } from './Core';
import { o, TdObject } from './TdClient';
import { ChatItem, ChatPos, SecretChatItem, TopicItem, UserItem } from './Models';
import { fillMessage, localPath, summary } from './Parse';
import { MsgItem } from './Models';

export class FolderItem {
  id: number = 0; // 0 = main list, -1 = archive
  name: string = '';
}

const CHAT_PAGE = 100;

export function listKey(list: TdObject): string {
  switch (list['@type'] as string) {
    case 'chatListMain': return 'main';
    case 'chatListArchive': return 'archive';
    default: return `folder:${list['chat_folder_id'] as number}`;
  }
}

export function listObject(folderId: number): TdObject {
  if (folderId === 0) {
    return o({ '@type': 'chatListMain' });
  }
  if (folderId === -1) {
    return o({ '@type': 'chatListArchive' });
  }
  return o({ '@type': 'chatListFolder', 'chat_folder_id': folderId });
}

function folderKey(folderId: number): string {
  return folderId === 0 ? 'main' : (folderId === -1 ? 'archive' : `folder:${folderId}`);
}

// Chats, users, secret chats and folders for one account.
export class ChatStore {
  private core: AccountCore;
  chats: Map<number, ChatItem> = new Map();
  users: Map<number, UserItem> = new Map();
  secretChats: Map<number, SecretChatItem> = new Map();
  // Supergroup id -> is a forum (members post in separate topics).
  forums: Map<number, boolean> = new Map();
  folders: FolderItem[] = [];
  // Typing users per chat: chat id -> (sender id -> action text).
  typing: Map<number, Map<number, string>> = new Map();
  private loadedLists: Set<string> = new Set();
  private typingTimers: Map<string, number> = new Map();
  scopeMute: Map<string, number> = new Map(); // private | group | channel -> mute_for
  // Unread unmuted chats per list (key: list key), as counted by TDLib.
  unreadChats: Map<string, number> = new Map();
  // Unread messages in unmuted chats of the main list, for the app icon badge.
  unreadMessages: number = 0;
  onUnread: () => void = () => {};
  // Called for each incoming message, for notifications.
  onIncoming: (chat: ChatItem, msg: MsgItem) => void = () => {};

  constructor(core: AccountCore) {
    this.core = core;
  }

  nameOf(id: number, isChat: boolean): string {
    if (isChat) {
      const c = this.chats.get(id);
      return c ? c.title : '';
    }
    const u = this.users.get(id);
    return u ? u.name() : '';
  }

  sorted(folderId: number): ChatItem[] {
    const key = folderKey(folderId);
    const list: ChatItem[] = [];
    this.chats.forEach((c: ChatItem) => {
      const p = c.positions.get(key);
      if (p && p.order !== '0') {
        list.push(c);
      }
    });
    list.sort((a: ChatItem, b: ChatItem) => {
      const x = BigInt(a.positions.get(key)!.order);
      const y = BigInt(b.positions.get(key)!.order);
      return x === y ? 0 : (x > y ? -1 : 1);
    });
    return list;
  }

  // Unread unmuted chats of a folder, for its tab.
  unreadIn(folderId: number): number {
    const key = folderKey(folderId);
    const counted = this.unreadChats.get(key);
    if (counted !== undefined) {
      return counted;
    }
    let n = 0;
    this.chats.forEach((c: ChatItem) => {
      const p = c.positions.get(key);
      if (p && p.order !== '0' && (c.unread > 0 || c.markedUnread) && !this.isMuted(c)) {
        n++;
      }
    });
    return n;
  }

  isForum(c: ChatItem): boolean {
    return c.type === 'supergroup' && (this.forums.get(c.groupId) ?? false);
  }

  // Topics of a forum, pinned first then by recent activity.
  topics(chatId: number): Promise<TopicItem[]> {
    return this.core.td.send(o({
      '@type': 'getForumTopics', 'chat_id': chatId, 'query': '', 'offset_date': 0,
      'offset_message_id': 0, 'offset_forum_topic_id': 0, 'limit': 100
    })).then((r: TdObject) => ((r['topics'] as TdObject[]) ?? []).map((t: TdObject) => this.topic(t)));
  }

  private topic(t: TdObject): TopicItem {
    const info = t['info'] as TdObject;
    const item = new TopicItem();
    item.id = info['forum_topic_id'] as number;
    item.name = info['name'] as string;
    item.color = ((info['icon'] as TdObject)['color'] as number) || 0x6FB9F0;
    item.isGeneral = info['is_general'] as boolean;
    item.isClosed = info['is_closed'] as boolean;
    item.isPinned = t['is_pinned'] as boolean;
    item.unread = (t['unread_count'] as number) ?? 0;
    item.unreadMentions = (t['unread_mention_count'] as number) ?? 0;
    item.lastReadInboxId = (t['last_read_inbox_message_id'] as number) ?? 0;
    item.order = String(t['order'] ?? '0');
    const last = t['last_message'] as TdObject | undefined;
    if (last) {
      const m = new MsgItem();
      try {
        fillMessage(m, last, (id: number, isChat: boolean) => this.nameOf(id, isChat));
      } catch (e) {
        m.kind = 'unsupported';
        m.text = '消息';
        m.date = (last['date'] as number) ?? 0;
        m.id = (last['id'] as number) ?? 0;
      }
      const who = m.outgoing ? '我' : this.nameOf(m.senderId, m.senderIsChat).split(' ')[0];
      item.lastText = who && m.kind !== 'service' ? `${who}: ${summary(m)}` : summary(m);
      item.lastDate = m.date;
      item.lastMsgId = m.id;
    }
    return item;
  }

  isPinned(c: ChatItem, folderId: number): boolean {
    const p = c.positions.get(folderKey(folderId));
    return p ? p.pinned : false;
  }

  isMuted(c: ChatItem): boolean {
    let muteFor = c.muteFor;
    if (c.useDefaultMute) {
      const scope = c.type === 'channel' ? 'channel' :
        (c.type === 'private' || c.type === 'secret' ? 'private' : 'group');
      muteFor = this.scopeMute.get(scope) ?? 0;
    }
    return muteFor > 0;
  }

  loadMore(folderId: number): void {
    const key = folderKey(folderId);
    if (this.loadedLists.has(key)) {
      return;
    }
    this.core.td.send(o({ '@type': 'loadChats', 'chat_list': listObject(folderId), 'limit': CHAT_PAGE }))
      .catch(() => {
        // 404: every chat of the list is already known.
        this.loadedLists.add(key);
      });
  }

  typingText(chatId: number): string {
    const t = this.typing.get(chatId);
    if (!t || t.size === 0) {
      return '';
    }
    const c = this.chats.get(chatId);
    const entries = Array.from(t.entries());
    if (c && (c.type === 'private' || c.type === 'secret')) {
      return entries[0][1];
    }
    const names = entries.map((e: [number, string]) => this.nameOf(e[0], false).split(' ')[0]);
    return `${names.slice(0, 2).join('、')}${names.length > 2 ? ' 等人' : ''} ${entries[0][1]}`;
  }
  private applyPositions(c: ChatItem, positions: TdObject[]): void {
    for (const p of positions) {
      const pos = new ChatPos();
      pos.order = String(p['order']);
      pos.pinned = p['is_pinned'] as boolean;
      c.positions.set(listKey(p['list'] as TdObject), pos);
    }
  }

  private setLast(c: ChatItem, msg: TdObject | undefined): void {
    if (!msg) {
      c.lastText = '';
      c.lastMsgId = 0;
      return;
    }
    const m = new MsgItem();
    try {
      fillMessage(m, msg, (id: number, isChat: boolean) => this.nameOf(id, isChat));
    } catch (e) {
      m.id = (msg['id'] as number) ?? 0;
      m.date = (msg['date'] as number) ?? 0;
      m.kind = 'unsupported';
      m.text = '消息';
    }
    let text = summary(m);
    if (c.type === 'group' || c.type === 'supergroup') {
      const who = m.outgoing ? '我' : this.nameOf(m.senderId, m.senderIsChat).split(' ')[0];
      if (who && m.kind !== 'service') {
        text = `${who}: ${text}`;
      }
    }
    c.lastText = text;
    c.lastDate = m.date;
    c.lastMsgId = m.id;
    c.lastOutgoing = m.outgoing;
  }

  private applyNotify(c: ChatItem, s: TdObject): void {
    c.useDefaultMute = s['use_default_mute_for'] as boolean;
    c.muteFor = s['mute_for'] as number;
  }

  private newChat(raw: TdObject): void {
    const c = new ChatItem();
    c.id = raw['id'] as number;
    c.title = raw['title'] as string;
    const type = raw['type'] as TdObject;
    switch (type['@type'] as string) {
      case 'chatTypePrivate':
        c.type = 'private';
        c.userId = type['user_id'] as number;
        break;
      case 'chatTypeSecret':
        c.type = 'secret';
        c.userId = type['user_id'] as number;
        c.secretChatId = type['secret_chat_id'] as number;
        break;
      case 'chatTypeBasicGroup':
        c.type = 'group';
        c.groupId = type['basic_group_id'] as number;
        break;
      default:
        c.type = type['is_channel'] ? 'channel' : 'supergroup';
        c.groupId = type['supergroup_id'] as number;
    }
    c.unread = raw['unread_count'] as number;
    c.unreadMentions = raw['unread_mention_count'] as number;
    c.markedUnread = raw['is_marked_as_unread'] as boolean;
    c.lastReadOutboxId = raw['last_read_outbox_message_id'] as number;
    c.lastReadInboxId = (raw['last_read_inbox_message_id'] as number) ?? 0;
    c.autoDeleteTime = raw['message_auto_delete_time'] as number;
    c.replyMarkupId = (raw['reply_markup_message_id'] as number) ?? 0;
    const perms = raw['permissions'] as TdObject | undefined;
    c.canSend = c.type !== 'channel' && (!perms || (perms['can_send_basic_messages'] as boolean) !== false);
    const photo = raw['photo'] as TdObject | undefined;
    if (photo) {
      const small = photo['small'] as TdObject;
      c.photoFileId = small['id'] as number;
      c.photoPath = localPath(small);
    }
    this.applyNotify(c, raw['notification_settings'] as TdObject);
    this.applyPositions(c, (raw['positions'] as TdObject[]) ?? []);
    this.chats.set(c.id, c);
    this.setLast(c, raw['last_message'] as TdObject | undefined);
    const draft = raw['draft_message'] as TdObject | undefined;
    c.draft = draft ? draftText(draft) : '';
  }

  private onUser(raw: TdObject): void {
    const u = this.users.get(raw['id'] as number) ?? new UserItem();
    u.id = raw['id'] as number;
    u.firstName = raw['first_name'] as string;
    u.lastName = raw['last_name'] as string;
    const names = raw['usernames'] as TdObject | undefined;
    const active = names ? ((names['active_usernames'] as string[]) ?? []) : [];
    u.username = active.length > 0 ? active[0] : '';
    u.phone = raw['phone_number'] as string;
    u.isBot = ((raw['type'] as TdObject)['@type'] as string) === 'userTypeBot';
    u.isPremium = raw['is_premium'] as boolean;
    u.status = raw['status'] as TdObject;
    const photo = raw['profile_photo'] as TdObject | undefined;
    u.photoFileId = photo ? (photo['small'] as TdObject)['id'] as number : 0;
    this.users.set(u.id, u);
  }

  private onSecret(raw: TdObject): void {
    const s = new SecretChatItem();
    s.id = raw['id'] as number;
    s.userId = raw['user_id'] as number;
    const st = (raw['state'] as TdObject)['@type'] as string;
    s.state = st === 'secretChatStateReady' ? 'ready' : (st === 'secretChatStateClosed' ? 'closed' : 'pending');
    s.outbound = raw['is_outbound'] as boolean;
    s.keyHash = (raw['key_hash'] as string) ?? '';
    this.secretChats.set(s.id, s);
  }

  private onTyping(u: TdObject): void {
    const chatId = u['chat_id'] as number;
    const sender = u['sender_id'] as TdObject;
    const senderId = (sender['user_id'] as number) ?? (sender['chat_id'] as number);
    const text = actionText(u['action'] as TdObject);
    const map = this.typing.get(chatId) ?? new Map<number, string>();
    const key = `${chatId}:${senderId}`;
    const old = this.typingTimers.get(key);
    if (old !== undefined) {
      clearTimeout(old);
    }
    if (text) {
      map.set(senderId, text);
      // TDLib resends actions every few seconds; expire stale ones.
      this.typingTimers.set(key, setTimeout(() => {
        map.delete(senderId);
        this.core.emit('typing');
      }, 6000));
    } else {
      map.delete(senderId);
    }
    this.typing.set(chatId, map);
    this.core.emit('typing');
  }

  private patch(u: TdObject, fn: (c: ChatItem) => void): void {
    const c = this.chats.get(u['chat_id'] as number);
    if (c) {
      fn(c);
      this.core.emit('chats');
    }
  }

  onUpdate(u: TdObject): void {
    switch (u['@type'] as string) {
      case 'updateNewChat':
        this.newChat(u['chat'] as TdObject);
        this.core.emit('chats');
        break;
      case 'updateChatTitle':
        this.patch(u, (c: ChatItem) => { c.title = u['title'] as string; });
        break;
      case 'updateChatPhoto':
        this.patch(u, (c: ChatItem) => {
          const photo = u['photo'] as TdObject | undefined;
          const small = photo ? photo['small'] as TdObject : undefined;
          c.photoFileId = small ? small['id'] as number : 0;
          c.photoPath = small ? localPath(small) : '';
        });
        break;
      case 'updateChatPosition':
        this.patch(u, (c: ChatItem) => this.applyPositions(c, [u['position'] as TdObject]));
        break;
      case 'updateChatLastMessage':
        this.patch(u, (c: ChatItem) => {
          this.setLast(c, u['last_message'] as TdObject | undefined);
          this.applyPositions(c, (u['positions'] as TdObject[]) ?? []);
        });
        break;
      case 'updateChatReadInbox':
        this.patch(u, (c: ChatItem) => {
          c.unread = u['unread_count'] as number;
          c.lastReadInboxId = u['last_read_inbox_message_id'] as number;
        });
        break;
      case 'updateChatReadOutbox':
        this.patch(u, (c: ChatItem) => { c.lastReadOutboxId = u['last_read_outbox_message_id'] as number; });
        break;
      case 'updateChatUnreadMentionCount':
      case 'updateMessageMentionRead':
        this.patch(u, (c: ChatItem) => { c.unreadMentions = u['unread_mention_count'] as number; });
        break;
      case 'updateChatIsMarkedAsUnread':
        this.patch(u, (c: ChatItem) => { c.markedUnread = u['is_marked_as_unread'] as boolean; });
        break;
      case 'updateChatNotificationSettings':
        this.patch(u, (c: ChatItem) => this.applyNotify(c, u['notification_settings'] as TdObject));
        break;
      case 'updateChatDraftMessage':
        this.patch(u, (c: ChatItem) => {
          const d = u['draft_message'] as TdObject | undefined;
          c.draft = d ? draftText(d) : '';
          this.applyPositions(c, (u['positions'] as TdObject[]) ?? []);
        });
        break;
      case 'updateChatMessageAutoDeleteTime':
        this.patch(u, (c: ChatItem) => { c.autoDeleteTime = u['message_auto_delete_time'] as number; });
        break;
      case 'updateChatReplyMarkup':
        this.patch(u, (c: ChatItem) => {
          const m = u['reply_markup_message'] as TdObject | undefined;
          c.replyMarkupId = m ? m['id'] as number : 0;
        });
        break;
      case 'updateUnreadChatCount':
        this.unreadChats.set(listKey(u['chat_list'] as TdObject), u['unread_unmuted_count'] as number);
        this.core.emit('chats');
        break;
      case 'updateUnreadMessageCount':
        if (listKey(u['chat_list'] as TdObject) === 'main') {
          this.unreadMessages = u['unread_unmuted_count'] as number;
          this.onUnread();
        }
        break;
      case 'updateChatPermissions':
        this.patch(u, (c: ChatItem) => {
          const p = u['permissions'] as TdObject;
          c.canSend = c.type !== 'channel' && (p['can_send_basic_messages'] as boolean) !== false;
        });
        break;
      case 'updateScopeNotificationSettings': {
        const scope = (u['scope'] as TdObject)['@type'] as string;
        const key = scope === 'notificationSettingsScopePrivateChats' ? 'private' :
          (scope === 'notificationSettingsScopeChannelChats' ? 'channel' : 'group');
        this.scopeMute.set(key, (u['notification_settings'] as TdObject)['mute_for'] as number);
        break;
      }
      case 'updateUser':
        this.onUser(u['user'] as TdObject);
        break;
      case 'updateSupergroup': {
        const sg = u['supergroup'] as TdObject;
        this.forums.set(sg['id'] as number, sg['is_forum'] as boolean);
        this.core.emit('chats');
        break;
      }
      case 'updateForumTopicInfo':
      case 'updateForumTopic':
        this.core.emit('topics');
        break;
      case 'updateUserStatus': {
        const user = this.users.get(u['user_id'] as number);
        if (user) {
          user.status = u['status'] as TdObject;
          this.core.emit('typing');
        }
        break;
      }
      case 'updateSecretChat':
        this.onSecret(u['secret_chat'] as TdObject);
        this.core.emit('chats');
        break;
      case 'updateChatAction':
        this.onTyping(u);
        break;
      case 'updateChatFolders':
        this.folders = ((u['chat_folders'] as TdObject[]) ?? []).map((f: TdObject) => {
          const item = new FolderItem();
          item.id = f['id'] as number;
          item.name = ((f['name'] as TdObject)['text'] as TdObject)['text'] as string;
          return item;
        });
        this.core.emit('folders');
        break;
      case 'updateNewMessage': {
        const raw = u['message'] as TdObject;
        const c = this.chats.get(raw['chat_id'] as number);
        if (c && !(raw['is_outgoing'] as boolean)) {
          try {
            this.onIncoming(c, fillMessage(new MsgItem(), raw, (id: number, isChat: boolean) => this.nameOf(id, isChat)));
          } catch (e) {
            // No notification for a message that cannot be parsed.
          }
        }
        break;
      }
      default:
        break;
    }
  }
}

function draftText(d: TdObject): string {
  const content = d['content'] as TdObject | undefined;
  if (content && content['@type'] === 'draftMessageContentText') {
    return ((content['text'] as TdObject)['text'] as string) ?? '';
  }
  return '';
}

function actionText(a: TdObject): string {
  switch (a['@type'] as string) {
    case 'chatActionTyping': return '正在输入…';
    case 'chatActionRecordingVoiceNote': return '正在录音…';
    case 'chatActionUploadingVoiceNote': return '正在发送语音…';
    case 'chatActionRecordingVideo':
    case 'chatActionRecordingVideoNote': return '正在录视频…';
    case 'chatActionUploadingVideo':
    case 'chatActionUploadingVideoNote': return '正在发送视频…';
    case 'chatActionUploadingPhoto': return '正在发送图片…';
    case 'chatActionUploadingDocument': return '正在发送文件…';
    case 'chatActionChoosingSticker': return '正在选择贴纸…';
    case 'chatActionChoosingLocation': return '正在选择位置…';
    case 'chatActionChoosingContact': return '正在选择联系人…';
    case 'chatActionStartPlayingGame': return '正在玩游戏…';
    default: return '';
  }
}
