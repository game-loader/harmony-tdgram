import { router, promptAction } from '@kit.ArkUI';
import { common, abilityAccessCtrl, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { geoLocationManager } from '@kit.LocationKit';
import { AlbumItem, BubbleActions, BubbleData, MessageBubble } from './MessageBubble';
import { ActionPanel, PanelItem } from './ActionPanel';
import { Avatar } from './Avatar';
import { FloatButton } from './FloatButton';
import { StickerPanel } from './StickerPanel';
import { AppState, copyText, ForwardRequest, ViewerItem } from '../common/AppState';
import { bubbleMaxWidth, columnsFor, mediaMaxHeight, mediaWidth, panelHeight, stickerSide } from '../common/Layout';
import { diffLists, DiffOp, OP_ADD, OP_DELETE } from '../common/ListDiff';
import { Nav, RouteController } from '../common/Nav';
import { normalizeTag, snippetAround } from '../common/Tags';
import { copyToCache, fileNameOf, formatDay, formatTime, lastSeen } from '../common/Util';
import { Account, LinkTarget } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { FilterConfig, Filters, reasonText } from '../td/Filters';
import { AccountEvent } from '../td/Core';
import { BotCmd, ChatItem, InlineButton, MsgItem, ReactionItem } from '../td/Models';
import { formatTimer, summary } from '../td/Parse';
import { MessageStore, OpenOptions, SearchPage, SendOptions, StoreEvent } from '../td/MessageStore';
import { TdError, TdObject } from '../td/TdClient';
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';
import { AudioService, VoiceRecorder } from '../services/AudioService';
import { EncodedVoice } from 'libtdbridge.so';

class ReplyPreview {
  name: string = '';
  text: string = '';
}

// A search result listed in the in-chat search panel.
class Hit {
  id: number = 0;
  name: string = '';
  date: number = 0;
  text: string = '';
}

// A row of the suggestion list above the composer: a member to mention or a
// bot command.
class Suggestion {
  title: string = '';
  detail: string = '';
  insert: string = '';   // text that replaces the typed token
  userId: number = 0;    // member without a username: mentioned by id
  photo: string = '';
  command: boolean = false;
}

class MenuState {
  seq: number = 0;
  title: string = '';
  emojis: string[] = [];
  chosen: string[] = [];
  items: PanelItem[] = [];
  onEmoji: (emoji: string) => void = (): void => {};
}

interface BottomP {
  label: string;
  fn: () => void;
}

class MediaPick {
  path: string = '';
  video: boolean = false;
}

function isAlbumKind(m: MsgItem): boolean {
  return m.kind === 'photo' || m.kind === 'video';
}

const QUICK_REACTIONS: string[] = ['👍', '❤', '😂', '😮', '😢', '🔥', '👏', '🎉'];
const AUTO_DELETE_OPTIONS: number[] = [0, 5, 30, 60, 3600, 86400, 604800];
const MUTE_FOREVER = 0x7FFFFFFF;
const KEY_ENTER = 2054;

// Rows of the message list. Changes are reported item by item so the list
// keeps the reading position when older messages are inserted above.
class BubbleSource implements IDataSource {
  private list: BubbleData[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.list.length;
  }

  getData(index: number): BubbleData {
    return this.list[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((l: DataChangeListener) => l !== listener);
  }

  items(): BubbleData[] {
    return this.list;
  }

  update(next: BubbleData[]): void {
    const old = this.list;
    const ops: DiffOp[] | null = diffLists(old.map((b: BubbleData) => b.id), old.map((b: BubbleData) => b.key),
      next.map((b: BubbleData) => b.id), next.map((b: BubbleData) => b.key));
    this.list = next;
    const oldIds = new Set<number>(old.map((b: BubbleData) => b.id));
    const shared = next.some((b: BubbleData) => oldIds.has(b.id));
    // A window with nothing in common (first load, jump elsewhere) reloads.
    if (ops === null || !shared) {
      for (const l of this.listeners) {
        l.onDataReloaded();
      }
      return;
    }
    for (const op of ops) {
      for (const l of this.listeners) {
        if (op.type === OP_ADD) {
          l.onDataAdd(op.index);
        } else if (op.type === OP_DELETE) {
          l.onDataDelete(op.index);
        } else {
          l.onDataChange(op.index);
        }
      }
    }
  }
}

// One open conversation, shown in the detail pane: beside the chat list on
// wide windows, over it on narrow ones. Every view owns its message store.
@Component
export struct ChatView {
  chatId: number = 0;
  messageId: number = 0;
  topicId: number = 0;    // forum topic shown, 0 for an ordinary chat
  topicName: string = '';
  readFrom: number = 0;    // topics: last read incoming message
  unreadCount: number = 0; // topics: unread messages
  threadId: number = 0;    // comments or reply thread shown instead of the chat
  threadTitle: string = '';
  startParam: string = '';  // bot deep link: sent when "Start" is pressed
  nav: Nav = new Nav();
  controller: RouteController = new RouteController();
  onBack: () => void = (): void => {};
  @Prop showBack: boolean = true;
  // False while another route covers this chat: nothing is marked as read.
  @Prop @Watch('onActiveChanged') active: boolean = true;
  @State title: string = '';
  @State subtitle: string = '';
  @State photo: string = '';
  @State count: number = -1; // rows shown; -1 until the first page arrives
  @State draft: string = '';
  @State replyTo: MsgItem | null = null;
  @State editing: MsgItem | null = null;
  @State selected: number[] = [];
  @State pinnedText: string = '';
  @State secretBanner: string = '';
  @State canSend: boolean = true;
  @State joinable: boolean = false;
  @State muted: boolean = false;
  @State showPanel: boolean = false;
  @State showAttach: boolean = false;
  @State recording: boolean = false;
  @State recordSecs: number = 0;
  @State showScrollDown: boolean = false;
  @State unread: number = 0;
  @State paneW: number = 360;
  @State paneH: number = 640;
  @State menus: MenuState[] = []; // zero or one, keyed so each menu is a fresh panel
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State hits: Hit[] = [];
  @State hitId: number = 0;
  @State searchTotal: number = 0;
  @State searchBusy: boolean = false;
  @State playerOn: boolean = false;
  @State playerTitle: string = '';
  @State playerPlaying: boolean = false;
  @State playerSpeed: number = 1;
  @State suggestions: Suggestion[] = [];
  @State keyboard: string[][] = [];   // bot reply keyboard
  @State showKeyboard: boolean = false;
  @State botStart: boolean = false;   // empty chat with a bot: offer "Start"
  @State mentionCount: number = 0;
  @State swipeId: number = 0;         // bubble being dragged left to reply
  @State swipeX: number = 0;
  @State dropping: boolean = false;   // files are dragged over the chat
  private chat: ChatItem | undefined = undefined;
  private acc: Account = Accounts.get().active();
  private store: MessageStore = Accounts.get().active().store(0);
  private source: BubbleSource = new BubbleSource();
  private bubbleActions: BubbleActions | null = null;
  private audioPlayer: AudioService = AudioService.get();
  private recorder: VoiceRecorder = new VoiceRecorder();
  private recordTimer: number = -1;
  private scroller: Scroller = new Scroller();
  private hitScroller: Scroller = new Scroller();
  private input: TextAreaController = new TextAreaController();
  private listener = (e: AccountEvent): void => this.onEvent(e);
  private audioListener = (): void => this.onAudio();
  private replyCache: Map<number, ReplyPreview> = new Map();
  private translations: Map<number, string> = new Map();
  private atBottom: boolean = true;
  private firstLoad: boolean = true;
  private pendingJump: number = 0;
  private highlightId: number = 0;
  private highlightTimer: number = -1;
  private lastShownId: number = 0;
  private lastTyping: number = 0;
  private visStart: number = 0;
  private visEnd: number = -1;
  private viewTimer: number = -1;
  private menuSeq: number = 0;
  private searchSeq: number = 0;
  private searchNext: string = '';
  private searchedFor: string = '';
  private caret: number = 0;
  private suggestSeq: number = 0;
  private commands: BotCmd[] | null = null;
  private mentions: Map<string, number> = new Map(); // picked members without a username
  private keyboardMsgId: number = 0;
  private keyboardOneTime: boolean = false;
  private mentionIds: number[] = [];
  private filters: Filters = Filters.get();
  private filterListener = (): void => this.onFilters();
  private revealed: Set<number> = new Set(); // filtered messages the user chose to look at
  private orphanViewed: number[] = [];       // filtered messages with no row to be reported with

  aboutToAppear(): void {
    this.bubbleActions = this.makeActions();
    this.pendingJump = this.messageId;
    this.highlightId = this.messageId;
    if (this.messageId) {
      this.revealed.add(this.messageId);
    }
    this.controller.back = (): boolean => this.handleBack();
    this.controller.jumpTo = (id: number): void => this.jumpTo(id);
    this.chat = this.acc.chat(this.chatId);
    this.draft = this.chat && !this.topicId && !this.threadId ? this.chat.draft : '';
    const opt = new OpenOptions();
    opt.messageId = this.messageId;
    if (this.threadId) {
      // Threads open at their newest replies.
    } else if (this.topicId) {
      opt.lastReadId = this.readFrom;
      opt.unread = this.unreadCount;
    } else if (this.chat) {
      opt.lastReadId = this.chat.lastReadInboxId;
      opt.unread = this.chat.unread;
    }
    this.store = this.acc.openSession(this.chatId, this.topicId, opt, this.threadId);
    this.store.onChange = (e: StoreEvent): void => this.onStore(e);
    Accounts.get().clearNotifications(this.acc, this.chatId);
    this.acc.on(this.listener);
    this.filters.on(this.filterListener);
    this.audioPlayer.on(this.audioListener);
    this.audioPlayer.onEnded = (key: string) => this.playNextVoice(key);
    this.refreshHeader();
    this.onAudio();
    // Comments can be written without joining the discussion group.
    if (this.chat && !this.threadId) {
      this.acc.notMember(this.chat).then((left: boolean) => {
        this.joinable = left;
      }).catch(() => {});
    }
  }

  aboutToDisappear(): void {
    // Drafts are kept per chat; a topic's draft would overwrite the chat's.
    if (this.chat && !this.topicId && !this.threadId && !this.editing && this.draft !== this.chat.draft) {
      this.store.setDraft(this.draft.trim(), this.replyTo ? this.replyTo.id : 0);
    }
    this.acc.off(this.listener);
    this.filters.off(this.filterListener);
    this.audioPlayer.off(this.audioListener);
    this.acc.closeSession(this.store);
    clearTimeout(this.viewTimer);
    clearTimeout(this.highlightTimer);
    if (this.recording) {
      clearInterval(this.recordTimer);
      this.recorder.stop(true);
    }
  }

  handleBack(): boolean {
    if (this.menus.length > 0) {
      this.menus = [];
      return true;
    }
    if (this.selected.length > 0) {
      this.selected = [];
      this.rebuild(false);
      return true;
    }
    if (this.showPanel || this.showAttach || this.searchOpen || this.showKeyboard || this.suggestions.length > 0) {
      this.showPanel = false;
      this.showAttach = false;
      this.searchOpen = false;
      this.showKeyboard = false;
      this.suggestions = [];
      return true;
    }
    return false;
  }

  onActiveChanged(): void {
    if (this.active) {
      this.scheduleView();
    }
  }

  onEvent(e: AccountEvent): void {
    if (e === 'files') {
      this.rebuild(false);
    } else if (e === 'typing' || e === 'chats' || e === 'connection') {
      this.refreshHeader();
    }
  }

  // A rule or a classifier answer changed what is filtered.
  private onFilters(): void {
    this.rebuild(false);
    this.scheduleView();
  }

  private onStore(e: StoreEvent): void {
    if (e === 'messages') {
      this.rebuild(true);
    } else {
      const p = this.store.pinned;
      this.pinnedText = p ? summary(p) : '';
    }
  }

  private onAudio(): void {
    const a = this.audioPlayer;
    this.playerOn = a.hasTrack();
    this.playerTitle = a.title;
    this.playerPlaying = a.playing;
    this.playerSpeed = a.speed;
    this.rebuild(false);
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message });
  }

  private refreshHeader(): void {
    const c = this.acc.chat(this.chatId);
    if (!c) {
      return;
    }
    this.chat = c;
    this.title = this.threadId ? this.threadTitle :
      (this.topicId ? this.topicName : (c.userId === this.acc.myUserId ? '收藏夹' : c.title));
    this.photo = c.photoPath || this.acc.files.path(c.photoFileId);
    this.canSend = c.canSend;
    this.muted = this.acc.chats.isMuted(c);
    this.unread = this.topicId || this.threadId ? 0 : c.unread;
    this.mentionCount = this.topicId || this.threadId ? 0 : c.unreadMentions;
    if (!this.threadId && c.replyMarkupId !== this.keyboardMsgId) {
      this.loadKeyboard(c.replyMarkupId);
    }
    const typing = this.acc.chats.typingText(c.id);
    const conn = this.acc.connection;
    if (conn !== 'ready') {
      this.subtitle = conn === 'waiting' ? '等待网络…' : (conn === 'proxy' ? '正在连接代理…' :
        (conn === 'updating' ? '正在更新…' : '正在连接…'));
    } else if (typing) {
      this.subtitle = typing;
    } else if (c.userId) {
      const u = this.acc.user(c.userId);
      this.subtitle = c.userId === this.acc.myUserId ? '' : (u ? (u.isBot ? '机器人' : lastSeen(u.status)) : '');
    } else {
      this.subtitle = this.topicId || this.threadId ? c.title : (c.type === 'channel' ? '频道' : '群组');
    }
    if (c.autoDeleteTime && conn === 'ready') {
      this.subtitle += `${this.subtitle ? ' · ' : ''}${formatTimer(c.autoDeleteTime)}后自动删除`;
    }
    if (c.type === 'secret') {
      const s = this.acc.chats.secretChats.get(c.secretChatId);
      const st = s ? s.state : 'pending';
      this.secretBanner = st === 'ready' ? '' :
        (st === 'closed' ? '私密聊天已关闭' : `等待 ${c.title} 上线以建立私密聊天…`);
      this.canSend = st === 'ready';
    }
  }

  private replyPreview(m: MsgItem): ReplyPreview {
    const cached = this.replyCache.get(m.replyToId);
    if (cached) {
      return cached;
    }
    const local = this.store.find(m.replyToId);
    if (local) {
      return this.previewOf(local);
    }
    const placeholder = new ReplyPreview();
    this.replyCache.set(m.replyToId, placeholder);
    this.store.fetch(m.chatId, m.replyToId).then((r: MsgItem) => {
      this.replyCache.set(m.replyToId, this.previewOf(r));
      this.rebuild(false);
    }).catch(() => {
      placeholder.text = '消息已删除';
    });
    return placeholder;
  }

  previewOf(m: MsgItem): ReplyPreview {
    const p = new ReplyPreview();
    p.name = m.outgoing ? '我' : this.acc.chats.nameOf(m.senderId, m.senderIsChat);
    p.text = summary(m);
    return p;
  }

  private autoDownload(m: MsgItem): boolean {
    const k = m.kind;
    if (k === 'sticker' || k === 'voice' || k === 'videoNote' || k === 'photo') {
      return true;
    }
    return k === 'animation' && Accounts.get().settings.autoDownloadMedia && m.fileSize < 10 * 1024 * 1024;
  }

  rebuild(messagesChanged: boolean): void {
    const msgs = this.store.messages;
    const isGroup = this.chat !== undefined && (this.chat.type === 'group' || this.chat.type === 'supergroup');
    const readUpTo = this.chat ? this.chat.lastReadOutboxId : 0;
    const settings = Accounts.get().settings;
    const prevLastId = this.lastShownId;
    const files = this.acc.files;
    const firstUnread = this.store.firstUnreadId;
    const resolve = (m: MsgItem): AlbumItem => {
      const it = new AlbumItem(m);
      it.filePath = this.autoDownload(m) ? (m.filePath || files.path(m.fileId, 8)) : files.known(m.fileId, m.filePath);
      it.thumbPath = m.thumbPath || files.path(m.thumbFileId, 16);
      const prog = files.progress.get(m.fileId);
      it.progress = prog !== undefined && !it.filePath ? prog : -1;
      return it;
    };
    const out: BubbleData[] = [];
    const filters = this.filters;
    const hideMode = filters.config.mode === 'hide';
    let run: BubbleData | null = null; // the line standing for consecutive filtered messages
    let carryViewed: number[] = [];    // hide mode: filtered messages waiting for a row to be reported with
    let carryDivider = false;
    let prevShown: MsgItem | undefined = undefined;
    let afterBreak = false;
    let hiddenTotal = 0;
    let i = 0;
    while (i < msgs.length) {
      // Consecutive photos and videos sharing media_album_id become one bubble.
      let j = i + 1;
      if (msgs[i].albumId !== '0' && isAlbumKind(msgs[i])) {
        while (j < msgs.length && msgs[j].albumId === msgs[i].albumId && isAlbumKind(msgs[j])) {
          j++;
        }
      }
      const group = msgs.slice(i, j);
      i = j;
      const captioned = group.find((x: MsgItem) => x.text !== '');
      const m = captioned ?? group[0];
      const hasUnread = firstUnread !== 0 && group.some((x: MsgItem) => x.id === firstUnread);
      const reason = filters.check(m, this.chat);
      if (reason && !group.some((x: MsgItem) => this.revealed.has(x.id))) {
        hiddenTotal += group.length;
        if (hideMode) {
          group.forEach((x: MsgItem) => carryViewed.push(x.id));
          carryDivider = carryDivider || hasUnread;
          continue;
        }
        if (!run) {
          run = new BubbleData(m);
          run.filtered = reason;
          if (!prevShown || formatDay(prevShown.date) !== formatDay(m.date)) {
            run.dayLabel = formatDay(m.date);
          }
          out.push(run);
        } else if (run.filtered !== reason) {
          run.filtered = 'mixed';
        }
        const line = run;
        group.forEach((x: MsgItem) => line.hidden.push(x));
        line.unreadDivider = line.unreadDivider || hasUnread;
        prevShown = m;
        afterBreak = true;
        continue;
      }
      run = null;
      const d = new BubbleData(m);
      d.filtered = reason;
      d.viewAlso = carryViewed;
      carryViewed = [];
      if (group.length > 1) {
        d.album = group.map(resolve);
      }
      d.showSender = isGroup && (!prevShown || afterBreak || prevShown.senderId !== m.senderId ||
        prevShown.kind === 'service');
      d.senderName = this.acc.chats.nameOf(m.senderId, m.senderIsChat);
      const self = resolve(m);
      d.filePath = self.filePath;
      d.thumbPath = self.thumbPath;
      d.progress = self.progress;
      if (m.replyToId) {
        const r = this.replyPreview(m);
        d.replyName = r.name;
        d.replyText = r.text;
      }
      const lastOfGroup = group[group.length - 1];
      d.read = m.outgoing && lastOfGroup.id <= readUpTo;
      const key = `${m.chatId}:${m.id}`;
      d.playing = this.audioPlayer.key === key;
      d.playPos = d.playing && this.audioPlayer.duration > 0 ? this.audioPlayer.position / this.audioPlayer.duration : 0;
      d.translated = this.translations.get(m.id) ?? '';
      d.selected = group.some((x: MsgItem) => this.selected.includes(x.id));
      d.highlight = this.highlightId !== 0 && group.some((x: MsgItem) => x.id === this.highlightId);
      d.unreadDivider = hasUnread || carryDivider;
      carryDivider = false;
      d.autoplay = settings.autoplayGifs;
      d.canThread = !this.threadId && !this.topicId && m.hasThread && !m.pending && !m.failed &&
        (m.isChannelPost || m.replyCount > 0);
      // Not in secret chats: the map image is requested from Telegram's servers.
      if (m.kind === 'location' && !(this.chat && this.chat.type === 'secret')) {
        d.mapPath = files.path(this.acc.mapFile(m.lat, m.lon, m.chatId), 4);
      }
      if (!prevShown || formatDay(prevShown.date) !== formatDay(m.date)) {
        d.dayLabel = formatDay(m.date);
      }
      prevShown = m;
      afterBreak = false;
      out.push(d);
    }
    // Filtered messages at the very end are reported with the last row, so
    // the chat does not stay unread because of messages that are not shown.
    if (out.length > 0 && carryViewed.length > 0) {
      const tail = out[out.length - 1];
      tail.viewAlso = tail.viewAlso.concat(carryViewed);
      carryViewed = [];
    }
    this.orphanViewed = carryViewed;
    out.forEach((b: BubbleData) => b.seal());
    this.source.update(out);
    this.count = messagesChanged || this.count >= 0 ? out.length : this.count;
    if (messagesChanged) {
      // An empty chat with a bot starts with the "Start" button.
      const u = this.chat && this.chat.type === 'private' ? this.acc.user(this.chat.userId) : undefined;
      this.botStart = u !== undefined && u.isBot && (this.startParam !== '' || (msgs.length === 0 && this.store.olderDone));
    }
    const lastId = msgs.length > 0 ? msgs[msgs.length - 1].id : 0;
    this.lastShownId = lastId;
    // Hiding messages may leave too little to scroll, and so nothing that
    // would ask for older history. Bounded, in case a whole chat is filtered.
    if (hiddenTotal > 0 && out.length < 12 && msgs.length < 300 && !this.store.olderDone) {
      this.store.loadOlder();
    }
    if (messagesChanged && out.length === 0 && this.orphanViewed.length > 0) {
      this.scheduleView();
    }
    if (!messagesChanged || out.length === 0) {
      return;
    }
    this.scheduleView();
    if (this.pendingJump) {
      const idx = out.findIndex((b: BubbleData) => b.ids().includes(this.pendingJump));
      if (idx >= 0) {
        this.pendingJump = 0;
        this.firstLoad = false;
        this.atBottom = false;
        setTimeout((): void => { this.scroller.scrollToIndex(idx, false, ScrollAlign.CENTER); }, 0);
        this.fadeHighlight();
      }
      return;
    }
    if (this.firstLoad) {
      this.firstLoad = false;
      const idx = firstUnread ? out.findIndex((b: BubbleData) => b.unreadDivider) : -1;
      if (idx >= 0) {
        // Open where reading stopped: the "unread messages" line at the top.
        this.atBottom = false;
        setTimeout((): void => { this.scroller.scrollToIndex(idx, false, ScrollAlign.START); }, 0);
      } else {
        setTimeout((): void => { this.scroller.scrollToIndex(out.length - 1, false, ScrollAlign.END); }, 0);
      }
      return;
    }
    if (lastId !== prevLastId && this.atBottom) {
      setTimeout((): void => { this.scroller.scrollToIndex(out.length - 1, true, ScrollAlign.END); }, 0);
    }
  }

  // Reports the messages on screen so TDLib moves the read position there.
  private scheduleView(): void {
    if (this.viewTimer >= 0) {
      return;
    }
    this.viewTimer = setTimeout(() => {
      this.viewTimer = -1;
      if (!this.active || !Accounts.get().appInForeground) {
        return;
      }
      const rows = this.source.items();
      const ids: number[] = rows.length === 0 ? this.orphanViewed.slice() : [];
      for (let i = Math.max(0, this.visStart); i <= this.visEnd && i < rows.length; i++) {
        for (const id of rows[i].viewIds()) {
          ids.push(id);
        }
      }
      this.store.view(ids);
    }, 250);
  }

  private fadeHighlight(): void {
    clearTimeout(this.highlightTimer);
    this.highlightTimer = setTimeout(() => {
      this.highlightId = 0;
      this.rebuild(false);
    }, 1800);
  }

  jumpTo(id: number): void {
    this.highlightId = id;
    // A filtered message that is asked for by name is shown.
    this.revealed.add(id);
    this.rebuild(false);
    const idx = this.source.items().findIndex((b: BubbleData) => b.ids().includes(id));
    if (idx >= 0) {
      this.scroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
      this.fadeHighlight();
      return;
    }
    this.pendingJump = id;
    this.store.jumpTo(id).then((ok: boolean) => {
      if (!ok) {
        this.pendingJump = 0;
        this.highlightId = 0;
        this.toast('找不到这条消息');
      }
    }).catch(() => {
      this.pendingJump = 0;
    });
  }

  scrollToBottom(): void {
    if (!this.store.atLatest) {
      this.firstLoad = true;
      this.store.firstUnreadId = 0;
      this.store.jumpToLatest();
    } else {
      this.scroller.scrollToIndex(this.source.totalCount() - 1, true, ScrollAlign.END);
    }
  }

  // ---- Sending ----

  private opts(silent: boolean = false): SendOptions {
    return { replyTo: this.replyTo ? this.replyTo.id : 0, silent: silent };
  }

  private after(p: Promise<Object>): void {
    this.atBottom = true;
    this.replyTo = null;
    if (this.store.firstUnreadId) {
      this.store.firstUnreadId = 0;
    }
    if (!this.store.atLatest) {
      this.firstLoad = true;
    }
    p.catch((e: TdError) => this.toast(`发送失败：${e.message}`));
  }

  sendText(silent: boolean = false): void {
    const text = this.draft.trim();
    if (!text) {
      return;
    }
    const md = Accounts.get().settings.markdown;
    if (this.editing) {
      const m = this.editing;
      this.editing = null;
      this.draft = '';
      this.store.editText(m, text, md).catch((e: TdError) => this.toast(e.message));
      return;
    }
    this.draft = '';
    this.suggestions = [];
    const mentions = this.mentions;
    this.mentions = new Map();
    this.after(this.store.sendText(text, this.opts(silent), md, mentions));
    if (!this.topicId && !this.threadId) {
      this.store.setDraft('', 0);
    }
  }

  // Sends text as is (a bot keyboard button or a command).
  private sendPlain(text: string): void {
    this.after(this.store.sendText(text, this.opts(), false));
  }

  onDraftChange(v: string): void {
    this.draft = v;
    this.suggest();
    const now = Date.now();
    if (v && now - this.lastTyping > 4000 && !Accounts.get().settings.ghostMode) {
      this.lastTyping = now;
      this.store.sendTyping('chatActionTyping');
    }
  }

  private closePanels(): void {
    this.showAttach = false;
    this.showPanel = false;
    this.showKeyboard = false;
  }

  // ---- @mention and /command suggestions ----

  // The token being typed: from the last '@' or '/' before the caret, when
  // it starts a word and contains no whitespace.
  private caretAt(): number {
    return this.caret > 0 && this.caret <= this.draft.length ? this.caret : this.draft.length;
  }

  private token(): string {
    const upTo = this.draft.substring(0, this.caretAt());
    const m = /(^|\s)([@\/][^\s@\/]*)$/.exec(upTo);
    return m ? m[2] : '';
  }

  private suggest(): void {
    // The caret position arrives just after the text change.
    setTimeout((): void => this.updateSuggestions(), 0);
  }

  private updateSuggestions(): void {
    const tok = this.token();
    const c = this.chat;
    const seq = ++this.suggestSeq;
    if (!tok || !c || this.editing) {
      this.suggestions = [];
      return;
    }
    if (tok.startsWith('/')) {
      // Commands only make sense at the start of the message.
      if (this.draft.trim() !== tok) {
        this.suggestions = [];
        return;
      }
      const show = (list: BotCmd[]): void => {
        if (seq !== this.suggestSeq) {
          return;
        }
        const q = tok.substring(1).toLowerCase();
        this.suggestions = list.filter((b: BotCmd) => b.command.toLowerCase().startsWith(q)).slice(0, 12)
          .map((b: BotCmd) => {
            const s = new Suggestion();
            s.command = true;
            s.insert = `/${b.command}${b.bot ? '@' + b.bot : ''}`;
            s.title = s.insert;
            s.detail = b.description;
            return s;
          });
      };
      if (this.commands) {
        show(this.commands);
      } else {
        this.acc.botCommands(c).then((list: BotCmd[]) => {
          this.commands = list;
          show(list);
        }).catch(() => {
          this.commands = [];
        });
      }
      return;
    }
    if (c.type !== 'group' && c.type !== 'supergroup') {
      this.suggestions = [];
      return;
    }
    this.store.searchMembers(tok.substring(1)).then((ids: number[]) => {
      if (seq !== this.suggestSeq) {
        return;
      }
      const list: Suggestion[] = [];
      for (const id of ids) {
        const u = this.acc.user(id);
        if (!u || id === this.acc.myUserId) {
          continue;
        }
        const s = new Suggestion();
        s.title = u.name();
        s.detail = u.username ? '@' + u.username : '';
        s.insert = u.username ? '@' + u.username : u.firstName || u.name();
        s.userId = u.username ? 0 : id;
        s.photo = this.acc.files.path(u.photoFileId);
        list.push(s);
      }
      this.suggestions = list;
    }).catch(() => {
      if (seq === this.suggestSeq) {
        this.suggestions = [];
      }
    });
  }

  private pickSuggestion(s: Suggestion): void {
    const at = this.caretAt();
    const tok = this.token();
    const head = this.draft.substring(0, at - tok.length);
    const tail = this.draft.substring(at);
    this.suggestions = [];
    this.suggestSeq++;
    if (s.command) {
      // Picking a command sends it, as in the official apps.
      this.draft = '';
      this.sendPlain(s.insert);
      return;
    }
    if (s.userId) {
      this.mentions.set(s.insert, s.userId);
    }
    this.draft = `${head}${s.insert} ${tail}`;
    const pos = head.length + s.insert.length + 1;
    this.caret = pos;
    setTimeout((): void => { this.input.caretPosition(pos); }, 0);
  }

  // ---- Bot reply keyboard ----

  private loadKeyboard(msgId: number): void {
    this.keyboardMsgId = msgId;
    if (!msgId) {
      this.keyboard = [];
      this.showKeyboard = false;
      return;
    }
    this.store.fetch(this.chatId, msgId).then((m: MsgItem) => {
      if (msgId !== this.keyboardMsgId) {
        return;
      }
      this.keyboard = m.keyboard;
      this.keyboardOneTime = m.keyboardOneTime;
      // A new keyboard opens itself unless the user is typing.
      this.showKeyboard = m.keyboard.length > 0 && !this.showPanel && !this.showAttach && this.draft.length === 0;
    }).catch(() => {});
  }

  private pressKey(text: string): void {
    this.sendPlain(text);
    if (this.keyboardOneTime) {
      this.showKeyboard = false;
      this.store.keyboardUsed(this.keyboardMsgId);
    }
  }

  private pressStart(): void {
    if (this.chat) {
      this.botStart = false;
      this.after(this.store.startBot(this.chat.userId, this.startParam));
      this.startParam = '';
    }
  }

  // ---- Unread mentions ----

  private nextMention(): void {
    const jump = (): void => {
      const id = this.mentionIds.pop();
      if (id) {
        this.jumpTo(id);
      }
    };
    if (this.mentionIds.length > 0) {
      jump();
      return;
    }
    this.store.search('', 'searchMessagesFilterUnreadMention', '').then((p: SearchPage) => {
      // Newest first from the server; the oldest unread mention comes first.
      this.mentionIds = p.items.map((m: MsgItem) => m.id);
      if (this.mentionIds.length === 0) {
        this.toast('没有未读的提及');
      }
      jump();
    }).catch(() => {});
  }

  // ---- Files dragged in from another app (split screen, floating window) ----

  private handleDrop(e: DragEvent): void {
    this.dropping = false;
    if (!this.canSend || this.joinable) {
      e.setResult(DragResult.DRAG_FAILED);
      return;
    }
    const picks: MediaPick[] = [];
    const texts: string[] = [];
    let files = 0;
    try {
      for (const r of e.getData().getRecords()) {
        const type = r.getType();
        if (type === uniformTypeDescriptor.UniformDataType.IMAGE || type === uniformTypeDescriptor.UniformDataType.VIDEO) {
          const f = r as unifiedDataChannel.File;
          const p = new MediaPick();
          p.video = type === uniformTypeDescriptor.UniformDataType.VIDEO;
          p.path = copyToCache(this.ctx(), f.uri, fileNameOf(f.uri) || (p.video ? 'video.mp4' : 'image.jpg'));
          picks.push(p);
        } else if (type === uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) {
          texts.push((r as unifiedDataChannel.PlainText).textContent);
        } else if (type === uniformTypeDescriptor.UniformDataType.HYPERLINK) {
          texts.push((r as unifiedDataChannel.Hyperlink).url);
        } else {
          const f = r as unifiedDataChannel.File;
          if (f.uri) {
            this.after(this.store.sendDocument(copyToCache(this.ctx(), f.uri, fileNameOf(f.uri) || 'file'), '', this.opts()));
            files++;
          }
        }
      }
    } catch (err) {
      this.toast('无法读取拖入的内容');
      e.setResult(DragResult.DRAG_FAILED);
      return;
    }
    if (picks.length > 0) {
      this.sendMedia(picks.slice(0, 10), '');
    }
    if (texts.length > 0) {
      // Dropped text lands in the composer for review instead of being sent.
      this.draft = `${this.draft}${this.draft ? ' ' : ''}${texts.join('\n')}`;
    }
    e.setResult(picks.length > 0 || texts.length > 0 || files > 0 ? DragResult.DRAG_SUCCESSFUL : DragResult.DRAG_FAILED);
  }

  // Reads width, height and duration so a video gets a proper player bubble.
  private videoContent(path: string, caption: string): Promise<TdObject> {
    return media.createAVMetadataExtractor().then((ex: media.AVMetadataExtractor) => {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      ex.fdSrc = { fd: file.fd };
      return ex.fetchMetadata().then((meta: media.AVMetadata) => {
        let w = Number(meta.videoWidth ?? 0);
        let h = Number(meta.videoHeight ?? 0);
        if (meta.videoOrientation === '90' || meta.videoOrientation === '270') {
          const t = w;
          w = h;
          h = t;
        }
        return this.store.videoContent(path, caption, w, h, Number(meta.duration ?? 0) / 1000);
      }).finally(() => {
        ex.release();
        fs.closeSync(file);
      });
    }).catch(() => this.store.videoContent(path, caption, 0, 0, 0));
  }

  // Several photos and videos go out together as one album.
  private sendMedia(picks: MediaPick[], caption: string): void {
    if (picks.length === 0) {
      return;
    }
    const opts = this.opts();
    const jobs = picks.map((p: MediaPick, i: number): Promise<TdObject> => {
      const cap = i === 0 ? caption : '';
      return p.video ? this.videoContent(p.path, cap) : Promise.resolve(this.store.photoContent(p.path, cap, false, 0));
    });
    Promise.all(jobs).then((contents: TdObject[]) => {
      if (this.chat && this.chat.type === 'secret') {
        for (const c of contents) {
          this.after(this.store.sendAlbum([c], opts));
        }
      } else {
        this.after(this.store.sendAlbum(contents, opts));
      }
    }).catch(() => this.toast('发送失败'));
  }

  pickMedia(): void {
    this.closePanels();
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
    opts.maxSelectNumber = 10;
    new photoAccessHelper.PhotoViewPicker().select(opts).then((res: photoAccessHelper.PhotoSelectResult) => {
      const picks = res.photoUris.map((uri: string, i: number) => {
        const name = fileNameOf(uri) || `media_${i}`;
        const p = new MediaPick();
        p.path = copyToCache(this.ctx(), uri, name);
        p.video = /\.(mp4|mov|3gp|mkv|webm)$/i.test(name);
        return p;
      });
      if (picks.length > 0) {
        const caption = this.draft.trim();
        this.draft = '';
        this.sendMedia(picks, caption);
      }
    }).catch((e: Error) => this.toast(`选择失败：${e.message}`));
  }

  takePhoto(): void {
    this.closePanels();
    const profile: cameraPicker.PickerProfile = { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK };
    cameraPicker.pick(this.ctx(), [cameraPicker.PickerMediaType.PHOTO, cameraPicker.PickerMediaType.VIDEO], profile)
      .then((res: cameraPicker.PickerResult) => {
        if (res.resultCode !== 0 || !res.resultUri) {
          return;
        }
        const p = new MediaPick();
        p.video = res.mediaType === cameraPicker.PickerMediaType.VIDEO;
        p.path = copyToCache(this.ctx(), res.resultUri, p.video ? 'camera.mp4' : 'camera.jpg');
        this.sendMedia([p], '');
      }).catch((e: Error) => this.toast(`无法打开相机：${e.message}`));
  }

  pickSelfDestructPhoto(): void {
    this.closePanels();
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opts.maxSelectNumber = 1;
    new photoAccessHelper.PhotoViewPicker().select(opts).then((res: photoAccessHelper.PhotoSelectResult) => {
      if (res.photoUris.length === 0) {
        return;
      }
      const path = copyToCache(this.ctx(), res.photoUris[0], fileNameOf(res.photoUris[0]) || 'photo.jpg');
      this.after(this.store.sendPhoto(path, '', this.opts(), true, 10));
    }).catch(() => {});
  }

  pickDocument(): void {
    this.closePanels();
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 10;
    new picker.DocumentViewPicker(this.ctx()).select(opts).then((uris: string[]) => {
      for (const uri of uris) {
        const path = copyToCache(this.ctx(), uri, fileNameOf(uri) || 'file');
        this.after(this.store.sendDocument(path, '', this.opts()));
      }
    }).catch((e: Error) => this.toast(`选择失败：${e.message}`));
  }

  sendLocation(): void {
    this.closePanels();
    const perms: Permissions[] = ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'];
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.ctx(), perms).then(() => {
      return geoLocationManager.getCurrentLocation();
    }).then((loc: geoLocationManager.Location) => {
      this.after(this.store.sendLocation(loc.latitude, loc.longitude, this.opts()));
    }).catch(() => this.toast('无法获取位置'));
  }

  createPoll(): void {
    this.closePanels();
    const r = this.nav.push('poll');
    r.chatId = this.chatId;
    r.topicId = this.topicId;
    this.nav.commit();
  }

  sendDice(emoji: string): void {
    this.closePanels();
    this.after(this.store.sendDice(emoji, this.opts()));
  }

  // ---- Voice recording: hold the mic button, slide up to cancel ----

  startRecording(): void {
    const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.ctx(), perms)
      .then((r: PermissionRequestResult) => {
        if (r.authResults[0] !== 0) {
          throw new Error('denied');
        }
        return this.recorder.start(this.ctx());
      }).then(() => {
        this.recording = true;
        this.recordSecs = 0;
        this.recordTimer = setInterval(() => {
          this.recordSecs = Math.floor((Date.now() - this.recorder.startedAt) / 1000);
          if (this.recordSecs % 4 === 0 && !Accounts.get().settings.ghostMode) {
            this.store.sendTyping('chatActionRecordingVoiceNote');
          }
        }, 500);
      }).catch(() => this.toast('无法录音，请检查麦克风权限'));
  }

  stopRecording(cancel: boolean): void {
    if (!this.recording) {
      return;
    }
    this.recording = false;
    clearInterval(this.recordTimer);
    const path = this.recorder.path;
    this.recorder.stop(cancel).then((res: EncodedVoice | null) => {
      if (res) {
        this.after(this.store.sendVoice(path, res.duration, res.waveform, this.opts()));
      }
    });
  }

  // ---- Media interaction ----

  openMedia(d: BubbleData): void {
    this.openMediaMsg(d.msg, d.filePath);
  }

  openAlbumItem(d: BubbleData, index: number): void {
    const a = d.album[index];
    if (a) {
      this.openMediaMsg(a.msg, a.filePath);
    }
  }

  private openMediaMsg(m: MsgItem, filePath: string): void {
    if (m.kind === 'sticker') {
      return;
    }
    // Videos stream in the viewer; photos and GIFs download first.
    if (!filePath && m.kind !== 'video') {
      if (this.acc.files.isDownloading(m.fileId)) {
        this.acc.files.cancel(m.fileId);
      } else {
        this.acc.files.download(m.fileId, 32);
      }
      if (m.kind === 'photo') {
        return;
      }
    }
    if (m.selfDestructTime) {
      this.store.markOpened(m);
    }
    // Pager over every visual message of the loaded window, albums flattened.
    const visual: AlbumItem[] = [];
    for (const b of this.source.items()) {
      if (b.hidden.length > 0) {
        continue;
      }
      if (b.album.length > 0) {
        b.album.forEach((a: AlbumItem) => visual.push(a));
      } else if (b.msg.kind === 'photo' || b.msg.kind === 'video' || b.msg.kind === 'animation') {
        const a = new AlbumItem(b.msg);
        a.filePath = b.filePath;
        visual.push(a);
      }
    }
    AppState.viewer = visual.map((a: AlbumItem) => {
      const v = new ViewerItem();
      v.kind = a.msg.kind;
      v.path = a.filePath || this.acc.files.known(a.msg.fileId);
      v.caption = a.msg.text;
      v.fileId = a.msg.fileId;
      v.size = a.msg.fileSize;
      v.mime = a.msg.mime;
      v.name = a.msg.fileName || `${a.msg.id}.${a.msg.kind === 'photo' ? 'jpg' : 'mp4'}`;
      return v;
    });
    AppState.viewerIndex = Math.max(0, visual.findIndex((a: AlbumItem) => a.msg.id === m.id));
    router.pushUrl({ url: 'pages/MediaViewer' });
  }

  playAudio(d: BubbleData): void {
    const m = d.msg;
    if (!d.filePath) {
      this.acc.files.download(m.fileId, 32);
      return;
    }
    if (!m.listened && !m.outgoing) {
      this.store.markOpened(m);
    }
    const isOpus = m.kind === 'voice' && (m.mime === 'audio/ogg' || m.mime === '' || d.filePath.endsWith('.oga') ||
      d.filePath.endsWith('.ogg'));
    if (m.kind === 'videoNote') {
      // Round videos play inline through the Video component.
      if (this.audioPlayer.key === `${m.chatId}:${m.id}`) {
        this.audioPlayer.stop();
      } else {
        this.audioPlayer.stop();
        this.audioPlayer.key = `${m.chatId}:${m.id}`;
        this.rebuild(false);
      }
      return;
    }
    const name = m.kind === 'voice' ? `${d.senderName || '我'} 的语音` : (m.title || '音乐');
    this.audioPlayer.toggle(this.ctx(), `${m.chatId}:${m.id}`, d.filePath, isOpus, name);
  }

  // After a voice note ends, continue with the next one like official apps.
  private playNextVoice(key: string): void {
    const rows = this.source.items();
    const idx = rows.findIndex((b: BubbleData) => `${b.msg.chatId}:${b.msg.id}` === key);
    if (idx < 0) {
      return;
    }
    for (let i = idx + 1; i < rows.length; i++) {
      const b = rows[i];
      if (b.hidden.length === 0 && b.msg.kind === 'voice' && b.filePath) {
        this.playAudio(b);
        return;
      }
    }
  }

  openFile(d: BubbleData): void {
    const m = d.msg;
    if (!d.filePath) {
      if (this.acc.files.isDownloading(m.fileId)) {
        this.acc.files.cancel(m.fileId);
      } else {
        this.acc.files.download(m.fileId, 16);
      }
      return;
    }
    const opts = new picker.DocumentSaveOptions();
    opts.newFileNames = [m.fileName || 'file'];
    new picker.DocumentViewPicker(this.ctx()).save(opts).then((uris: string[]) => {
      if (uris.length === 0) {
        return;
      }
      const dst = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(d.filePath, dst.fd);
      } finally {
        fs.closeSync(dst);
      }
      this.toast('已保存');
    }).catch((e: Error) => this.toast(`保存失败：${e.message}`));
  }

  openLocation(d: BubbleData): void {
    const url = `geo:${d.msg.lat},${d.msg.lon}`;
    this.ctx().openLink(url).catch(() => {
      copyText(`${d.msg.lat}, ${d.msg.lon}`, '已复制坐标');
    });
  }

  openContact(d: BubbleData): void {
    if (d.msg.contactUserId) {
      this.acc.privateChatWith(d.msg.contactUserId).then((id: number) => {
        this.nav.openChat(id);
      }).catch(() => {});
    } else {
      copyText(d.msg.phone, '已复制电话号码');
    }
  }

  vote(d: BubbleData, options: number[]): void {
    this.store.vote(d.msg, options).catch((e: TdError) => this.toast(e.message));
  }

  // Comments of a channel post (they live in its discussion group) or the
  // replies to a group message.
  openThread(d: BubbleData): void {
    this.store.thread(d.msg).then((info: TdObject) => {
      this.nav.openThread(info['chat_id'] as number, info['message_thread_id'] as number,
        d.msg.isChannelPost ? '评论' : '回复');
    }).catch((e: TdError) => this.toast(`无法打开：${e.message}`));
  }

  retry(d: BubbleData): void {
    this.store.resend(d.msg).catch((e: TdError) => this.toast(`重试失败：${e.message}`));
  }

  // Opens the system date picker and jumps to the first message of that day.
  pickDate(): void {
    this.getUIContext().showDatePickerDialog({
      start: new Date(2013, 7, 1),
      end: new Date(),
      selected: new Date(),
      onDateAccept: (value: Date) => {
        const day = new Date(value.getFullYear(), value.getMonth(), value.getDate());
        // The last message before midnight; the day's first follows it.
        this.store.messageByDate(Math.floor(day.getTime() / 1000)).then((id: number) => {
          this.jumpTo(id);
        }).catch(() => this.toast('这一天之前没有消息'));
      }
    });
  }

  pressButton(d: BubbleData, b: InlineButton): void {
    if (b.url) {
      this.openUrl(b.url);
      return;
    }
    if (b.data) {
      this.store.callback(d.msg, b.data).then((r: TdObject) => {
        const text = r['text'] as string;
        const url = r['url'] as string;
        if (url) {
          this.openUrl(url);
        } else if (text) {
          if (r['show_alert']) {
            promptAction.showDialog({ message: text, buttons: [{ text: '好', color: '#3A8DDE' }] });
          } else {
            this.toast(text);
          }
        }
      }).catch(() => {});
    }
  }

  private openTarget(t: LinkTarget): void {
    if (t.proxy) {
      const mgr = Accounts.get();
      mgr.settings.proxies.push(t.proxy);
      mgr.saveSettings();
      this.toast('代理已保存，可在“设置 > 代理”中启用');
      this.nav.push('proxy');
      this.nav.commit();
    } else if (t.invite) {
      promptAction.showDialog({
        title: `加入“${t.inviteTitle}”？`,
        buttons: [{ text: '取消', color: '#888888' }, { text: '加入', color: '#3A8DDE' }]
      }).then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index !== 1) {
          return;
        }
        this.acc.joinByLink(t.invite).then((chatId: number) => {
          if (chatId) {
            this.nav.openChat(chatId);
          } else {
            this.toast('已发送加入申请');
          }
        }).catch((e: TdError) => this.toast(e.message));
      });
    } else if (t.botStart && t.chatId) {
      this.nav.openChat(t.chatId, 0, t.startParam);
    } else if (t.chatId === this.chatId && t.messageId && !this.threadId) {
      this.jumpTo(t.messageId);
    } else if (t.chatId) {
      this.nav.openChat(t.chatId, t.messageId);
    } else {
      this.toast('无法打开链接');
    }
  }

  openUrl(url: string): void {
    if (/^(https?:\/\/)?(t\.me|telegram\.me)\//i.test(url) || url.startsWith('tg:')) {
      this.acc.openLink(url).then((t: LinkTarget) => this.openTarget(t)).catch(() => this.toast('无法打开链接'));
      return;
    }
    promptAction.showDialog({
      title: '打开链接？', message: url,
      buttons: [{ text: '复制', color: '#888888' }, { text: '打开', color: '#3A8DDE' }]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        this.ctx().openLink(url).catch(() => this.toast('没有可以打开此链接的应用'));
      } else {
        copyText(url);
      }
    });
  }

  private openProfile(userId: number, chatId: number): void {
    const r = this.nav.push('profile');
    r.userId = userId;
    r.chatId = chatId;
    this.nav.commit();
  }

  openMention(name: string, userId: number, fromId: number): void {
    if (userId) {
      this.openProfile(userId, 0);
    } else if (name.startsWith('#') || name.startsWith('$')) {
      this.openSearch(normalizeTag(name), fromId);
    } else if (name.startsWith('@')) {
      this.openUrl(`https://t.me/${name.substring(1)}`);
    } else if (name.startsWith('/')) {
      this.draft = name + ' ';
    }
  }

  // ---- Search inside the chat: typed text, or a tapped #hashtag ----

  // fromId: the message a tag was tapped in; it is marked in the result list.
  openSearch(query: string, fromId: number = 0): void {
    this.closePanels();
    this.input.stopEditing();
    this.searchOpen = true;
    this.searchQuery = query;
    this.hitId = fromId;
    if (query) {
      this.runSearch(false);
    } else {
      this.hits = [];
      this.searchTotal = 0;
      this.searchedFor = '';
    }
  }

  private toHit(m: MsgItem, query: string): Hit {
    const h = new Hit();
    h.id = m.id;
    h.name = m.outgoing ? '我' : (this.acc.chats.nameOf(m.senderId, m.senderIsChat) || this.title);
    h.date = m.date;
    h.text = snippetAround(summary(m), query, 90);
    return h;
  }

  // jumpToFirst: typed searches go straight to the newest match; a tapped
  // tag only lists the matches, since the reader is already on one of them.
  runSearch(jumpToFirst: boolean): void {
    const q = this.searchQuery.trim();
    if (!q) {
      return;
    }
    const seq = ++this.searchSeq;
    this.searchBusy = true;
    this.searchedFor = q;
    this.store.search(q, 'searchMessagesFilterEmpty', '').then((p: SearchPage) => {
      if (seq !== this.searchSeq) {
        return;
      }
      this.searchBusy = false;
      this.searchNext = p.next;
      this.searchTotal = Math.max(p.total, p.items.length);
      this.hits = p.items.map((m: MsgItem) => this.toHit(m, q));
      if (jumpToFirst && this.hits.length > 0) {
        this.hitScroller.scrollEdge(Edge.Top);
        this.selectHit(this.hits[0].id);
      } else {
        // Show where the tapped message sits among the matches.
        const at = this.hits.findIndex((h: Hit) => h.id === this.hitId);
        setTimeout((): void => { this.hitScroller.scrollToIndex(Math.max(0, at)); }, 0);
      }
    }).catch((e: TdError) => {
      if (seq === this.searchSeq) {
        this.searchBusy = false;
        this.toast(`搜索失败：${e.message}`);
      }
    });
  }

  private moreHits(): Promise<void> {
    const q = this.searchedFor;
    if (!this.searchNext || this.searchBusy || !q) {
      return Promise.resolve();
    }
    const seq = this.searchSeq;
    this.searchBusy = true;
    return this.store.search(q, 'searchMessagesFilterEmpty', this.searchNext).then((p: SearchPage) => {
      if (seq !== this.searchSeq) {
        return;
      }
      this.searchBusy = false;
      this.searchNext = p.next;
      const known = new Set<number>(this.hits.map((h: Hit) => h.id));
      this.hits = this.hits.concat(p.items.filter((m: MsgItem) => !known.has(m.id)).map((m: MsgItem) => this.toHit(m, q)));
    }).catch(() => {
      this.searchBusy = false;
    });
  }

  selectHit(id: number): void {
    this.hitId = id;
    this.jumpTo(id);
  }

  // delta 1 = the next older match, -1 = the next newer one.
  stepHit(delta: number): void {
    if (this.hits.length === 0) {
      return;
    }
    const at = this.hits.findIndex((h: Hit) => h.id === this.hitId);
    const next = at < 0 ? 0 : at + delta;
    if (next < 0) {
      return;
    }
    if (next >= this.hits.length) {
      this.moreHits().then(() => {
        if (next < this.hits.length) {
          this.selectHit(this.hits[next].id);
          this.hitScroller.scrollToIndex(next);
        }
      });
      return;
    }
    this.selectHit(this.hits[next].id);
    this.hitScroller.scrollToIndex(next);
  }

  // ---- Message menu, selection, forwarding ----

  onTap(d: BubbleData): boolean {
    if (this.selected.length === 0) {
      return false;
    }
    const ids = d.ids();
    this.selected = d.selected ? this.selected.filter((x: number) => !ids.includes(x)) :
      this.selected.concat(ids.filter((x: number) => !this.selected.includes(x)));
    this.rebuild(false);
    return true;
  }

  private showMenu(m: MenuState): void {
    m.seq = ++this.menuSeq;
    this.input.stopEditing();
    this.menus = [m];
  }

  messageMenu(d: BubbleData): void {
    const m = d.msg;
    if (m.kind === 'service' || this.selected.length > 0) {
      return;
    }
    this.store.properties(m).then((p: TdObject) => {
      const menu = new MenuState();
      menu.title = `${m.outgoing ? '我' : d.senderName}  ${formatTime(m.date)}`.trim();
      const add = (label: string, fn: () => void, danger: boolean = false): void => {
        menu.items.push(new PanelItem(label, fn, danger));
      };
      if (this.canSend && p['can_be_replied']) {
        add('回复', () => { this.replyTo = m; });
      }
      if (m.text) {
        add('复制', () => copyText(m.text));
        add('翻译', () => this.translateMessage(m));
      }
      if (p['can_be_edited'] && (m.kind === 'text' || m.text || m.kind === 'photo' || m.kind === 'video')) {
        add('编辑', () => {
          this.editing = m;
          this.draft = m.text;
          this.replyTo = null;
        });
      }
      if (p['can_be_forwarded']) {
        add('转发', () => this.forward(d.ids(), false));
        add('转发（不显示来源）', () => this.forward(d.ids(), true));
      }
      if (p['can_be_pinned']) {
        const pinned = this.store.pinned !== null && this.store.pinned.id === m.id;
        add(pinned ? '取消置顶' : '置顶', () => {
          this.store.pin(m, !pinned).catch((e: TdError) => this.toast(e.message));
        });
      }
      if (m.failed && m.canRetry) {
        add('重新发送', () => this.retry(d));
      }
      if (!this.threadId && !this.topicId && p['can_get_message_thread']) {
        add(m.isChannelPost ? '查看评论' : '查看回复', () => this.openThread(d));
      }
      if (m.kind === 'sticker') {
        add('添加到收藏的贴纸', () => {
          this.store.favoriteSticker(m.fileId).then(() => this.toast('已收藏')).catch((e: TdError) => this.toast(e.message));
        });
      }
      if (m.kind === 'animation') {
        add('保存 GIF', () => {
          this.store.saveAnimation(m.fileId).then(() => this.toast('已保存到 GIF')).catch((e: TdError) => this.toast(e.message));
        });
      }
      if (m.kind === 'voice' || m.kind === 'videoNote') {
        add('转换为文字', () => {
          this.store.recognizeSpeech(m).catch((e: TdError) => this.toast(e.message));
        });
      }
      if (p['can_get_link']) {
        add('复制链接', () => {
          this.store.link(m).then((l: string) => copyText(l, '链接已复制')).catch(() => {});
        });
      }
      add('选择', () => {
        this.selected = d.ids();
        this.rebuild(false);
      });
      if (d.filtered) {
        add('不再过滤这类消息', () => {
          this.filters.unblock(m);
          this.toast('已取消过滤');
        });
      } else if (!m.outgoing) {
        add('屏蔽相同内容的消息', () => this.blockMenu([m]));
      }
      add('详细信息', () => this.showInfo(m));
      if (p['can_be_deleted_only_for_self'] || p['can_be_deleted_for_all_users']) {
        add('删除', () => this.confirmDelete(d.ids(), p['can_be_deleted_for_all_users'] as boolean), true);
      }
      menu.chosen = m.reactions.filter((r: ReactionItem) => r.chosen).map((r: ReactionItem) => r.emoji);
      menu.onEmoji = (e: string): void => this.react(m, e);
      if (this.chat && this.chat.type === 'secret') {
        this.showMenu(menu);
        return;
      }
      // Reactions the chat allows, most used first; the row scrolls sideways.
      this.store.availableReactions(m).then((list: string[]) => {
        menu.emojis = (list.length > 0 ? list : QUICK_REACTIONS).slice(0, 24);
        this.showMenu(menu);
      }).catch(() => this.showMenu(menu));
    }).catch(() => {});
  }

  react(m: MsgItem, emoji: string): void {
    this.store.react(m, emoji).catch((e: TdError) => this.toast(e.message));
  }

  translateMessage(m: MsgItem): void {
    const lang = Accounts.get().settings.translateTo;
    this.store.translate(m, lang).then((t: string) => {
      this.translations.set(m.id, t);
      this.rebuild(false);
    }).catch((e: TdError) => this.toast(`翻译失败：${e.message}`));
  }

  // ---- Message filter ----

  private blockMenu(list: MsgItem[]): void {
    const menu = new MenuState();
    menu.title = '以后遇到内容相同的消息就过滤掉';
    menu.items.push(new PanelItem('仅在这个聊天', () => this.block(list, false)));
    menu.items.push(new PanelItem('在所有聊天', () => this.block(list, true)));
    menu.items.push(new PanelItem('过滤设置…', () => this.openFilters()));
    this.showMenu(menu);
  }

  private block(list: MsgItem[], everywhere: boolean): void {
    list.forEach((m: MsgItem) => this.revealed.delete(m.id));
    const n = this.filters.block(list, this.chat, everywhere);
    if (n === 0) {
      this.toast('这条消息没有可以用来识别的内容（文字、按钮或文件）');
    } else {
      this.toast(n === list.length ? '已屏蔽，内容相同的消息不再显示' : `已屏蔽 ${n} 条，其余没有可识别的内容`);
    }
  }

  private blockSelected(): void {
    const list = this.source.items().filter((b: BubbleData) => b.selected && !b.msg.outgoing)
      .map((b: BubbleData) => b.msg);
    this.selected = [];
    this.rebuild(false);
    if (list.length === 0) {
      this.toast('自己发送的消息不会被过滤');
      return;
    }
    this.blockMenu(list);
  }

  private openFilters(): void {
    this.nav.push('filters');
    this.nav.commit();
  }

  // Shows the messages behind a "filtered" line, or folds them again.
  private reveal(b: BubbleData, show: boolean): void {
    for (const id of b.ids()) {
      if (show) {
        this.revealed.add(id);
      } else {
        this.revealed.delete(id);
      }
    }
    this.rebuild(false);
  }

  private filteredLabel(b: BubbleData): string {
    const why = reasonText(b.filtered);
    return `已过滤 ${b.hidden.length} 条消息${why ? ' · ' + why : ''}`;
  }

  private showInfo(m: MsgItem): void {
    const lines = [`消息 ID：${m.id}`, `发送时间：${new Date(m.date * 1000).toLocaleString()}`];
    if (m.editDate) {
      lines.push(`编辑时间：${new Date(m.editDate * 1000).toLocaleString()}`);
    }
    if (m.senderId) {
      lines.push(`发送者 ID：${m.senderId}`);
    }
    if (m.forwardFrom) {
      lines.push(`转发自：${m.forwardFrom}`);
    }
    if (m.fileSize) {
      lines.push(`文件大小：${(m.fileSize / 1024).toFixed(1)} KB`);
    }
    const ad = this.filters.probability(m);
    if (ad >= 0) {
      lines.push(`AI 判断为广告的概率：${Math.round(ad * 100)}%`);
    }
    promptAction.showDialog({ title: '消息信息', message: lines.join('\n'),
      buttons: [{ text: '复制 ID', color: '#888888' }, { text: '关闭', color: '#3A8DDE' }] })
      .then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 0) {
          copyText(String(m.id));
        }
      });
  }

  confirmDelete(ids: number[], canRevoke: boolean): void {
    const buttons: promptAction.Button[] = [{ text: '取消', color: '#888888' }, { text: '仅为我删除', color: '#E84026' }];
    if (canRevoke) {
      buttons.push({ text: '为所有人删除', color: '#E84026' });
    }
    promptAction.showDialog({ title: ids.length > 1 ? `删除 ${ids.length} 条消息？` : '删除消息？', buttons: buttons })
      .then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index >= 1) {
          this.store.remove(this.chatId, ids, r.index === 2).catch((e: TdError) => this.toast(e.message));
          this.selected = [];
          this.rebuild(false);
        }
      });
  }

  forward(ids: number[], asCopy: boolean): void {
    const req = new ForwardRequest();
    req.fromChatId = this.chatId;
    req.ids = ids.slice().sort((a: number, b: number) => a - b);
    req.asCopy = asCopy;
    AppState.forward = req;
    this.selected = [];
    this.rebuild(false);
    this.nav.push('forward');
    this.nav.commit();
  }

  // ---- Chat header menu ----

  chatMenu(): void {
    const c = this.chat;
    if (!c) {
      return;
    }
    const menu = new MenuState();
    const add = (label: string, fn: () => void, danger: boolean = false): void => {
      menu.items.push(new PanelItem(label, fn, danger));
    };
    add('搜索消息', () => this.openSearch(''));
    if (this.threadId) {
      this.showMenu(menu);
      return;
    }
    if (!this.topicId) {
      add('跳转到日期', () => this.pickDate());
    }
    add(this.muted ? '取消静音' : '静音', () => {
      this.acc.mute(c, this.muted ? 0 : MUTE_FOREVER).catch(() => {});
    });
    add('自动删除消息', () => this.autoDeleteMenu(c));
    add('消息过滤…', () => this.openFilters());
    const cfg = this.filters.config;
    if (this.filters.aiReady() && c.type !== 'secret' && !(cfg.aiChannels && c.type === 'channel')) {
      const on = cfg.aiChats.includes(c.id);
      add(`${on ? '✓ ' : ''}用 AI 识别这个聊天里的广告`, () => {
        this.filters.update((f: FilterConfig) => {
          f.aiChats = on ? f.aiChats.filter((id: number) => id !== c.id) : f.aiChats.concat([c.id]);
        });
        this.toast(on ? '已关闭' : '已开启：这个聊天收到的消息会发给 AI 接口判断');
      });
    }
    if (c.type === 'private' && c.userId !== this.acc.myUserId) {
      add('开始私密聊天', () => {
        this.acc.startSecretChat(c.userId).then((id: number) => {
          this.nav.openChat(id);
        }).catch((e: TdError) => this.toast(e.message));
      });
    }
    if (c.type === 'secret') {
      add('查看加密密钥', () => {
        const r = this.nav.push('secretKey');
        r.secretChatId = c.secretChatId;
        r.title = c.title;
        this.nav.commit();
      });
    }
    add('清空聊天记录', () => {
      promptAction.showDialog({ title: '清空聊天记录？',
        buttons: [{ text: '取消', color: '#888888' }, { text: '清空', color: '#E84026' }] })
        .then((d: promptAction.ShowDialogSuccessResponse) => {
          if (d.index === 1) {
            this.acc.clearHistory(c, false).catch((e: TdError) => this.toast(e.message));
          }
        });
    }, true);
    this.showMenu(menu);
  }

  private autoDeleteMenu(c: ChatItem): void {
    const menu = new MenuState();
    menu.title = '自动删除消息';
    for (const secs of AUTO_DELETE_OPTIONS) {
      menu.items.push(new PanelItem(`${secs === c.autoDeleteTime ? '✓ ' : ''}${secs === 0 ? '关闭' : formatTimer(secs)}`,
        () => {
          this.acc.setAutoDelete(c, secs).catch((e: TdError) => this.toast(e.message));
        }));
    }
    this.showMenu(menu);
  }

  private joinChat(): void {
    if (this.chat) {
      this.acc.join(this.chat).then(() => {
        this.joinable = false;
      }).catch((e: TdError) => this.toast(e.message));
    }
  }

  private makeActions(): BubbleActions {
    return {
      onOpenMedia: (d: BubbleData) => this.openMedia(d),
      onOpenAlbumItem: (d: BubbleData, i: number) => this.openAlbumItem(d, i),
      onAudio: (d: BubbleData) => this.playAudio(d),
      onSeek: (d: BubbleData, f: number) => this.audioPlayer.seek(f),
      onFile: (d: BubbleData) => this.openFile(d),
      onVote: (d: BubbleData, options: number[]) => this.vote(d, options),
      onThread: (d: BubbleData) => this.openThread(d),
      onRetry: (d: BubbleData) => this.retry(d),
      onLocation: (d: BubbleData) => this.openLocation(d),
      onContact: (d: BubbleData) => this.openContact(d),
      onButton: (d: BubbleData, b: InlineButton) => this.pressButton(d, b),
      onReact: (d: BubbleData, e: string) => this.react(d.msg, e),
      onJump: (id: number) => this.jumpTo(id),
      onMenu: (d: BubbleData) => this.messageMenu(d),
      onTap: (d: BubbleData) => this.onTap(d),
      onLink: (u: string) => this.openUrl(u),
      onMention: (d: BubbleData, n: string, id: number) => this.openMention(n, id, d.msg.id),
      onSender: (d: BubbleData) => {
        if (!d.msg.senderIsChat) {
          this.openProfile(d.msg.senderId, 0);
        }
      }
    };
  }

  @Builder
  Header() {
    if (this.selected.length > 0) {
      Row({ space: 4 }) {
        Button('✕', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          this.selected = [];
          this.rebuild(false);
        })
        Text(`已选择 ${this.selected.length} 条`).fontSize(17).layoutWeight(1).fontColor($r('app.color.text_primary'))
        Button('复制', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          const texts = this.source.items().filter((b: BubbleData) => b.selected)
            .map((b: BubbleData) => summary(b.msg));
          copyText(texts.join('\n'));
          this.selected = [];
          this.rebuild(false);
        })
        Button('转发', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.forward(this.selected, false))
        Button('屏蔽', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.blockSelected())
        Button('删除', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.danger'))
          .onClick(() => this.confirmDelete(this.selected, true))
      }
      .padding({ left: 4, right: 4 })
      .height(52)
      .width('100%')
    } else {
      Row({ space: 8 }) {
        if (this.showBack) {
          Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => this.onBack())
        }
        Avatar({ title: this.title, seed: this.chatId, path: this.photo, side: 38 })
        Column() {
          Row({ space: 4 }) {
            if (this.chat && this.chat.type === 'secret') {
              Text('🔒').fontSize(14)
            }
            Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.chat && this.chat.type === 'secret' ? $r('app.color.secret') : $r('app.color.text_primary'))
          }
          if (this.subtitle) {
            Text(this.subtitle).fontSize(12).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.subtitle.endsWith('…') || this.subtitle === '在线' ? $r('app.color.accent') :
                $r('app.color.text_secondary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => {
          if (this.chat) {
            this.openProfile(this.chat.userId, this.chat.id);
          }
        })
        Button('⋮', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(22).onClick(() => this.chatMenu())
      }
      .padding({ left: this.showBack ? 0 : 12, right: 4 })
      .height(52)
      .width('100%')
    }
  }

  // Voice note or music playing anywhere keeps its controls in reach.
  @Builder
  PlayerBar() {
    if (this.playerOn) {
      Row({ space: 6 }) {
        Text(this.playerPlaying ? '❚❚' : '▶').fontSize(14).fontColor($r('app.color.accent')).width(36).height(36)
          .textAlign(TextAlign.Center).onClick(() => this.audioPlayer.togglePause())
        Text(this.playerTitle).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).fontColor($r('app.color.text_primary'))
        Text(`${this.playerSpeed}x`).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(this.playerSpeed === 1 ? $r('app.color.text_secondary') : $r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(10).backgroundColor($r('app.color.chip'))
          .onClick(() => this.audioPlayer.cycleSpeed())
        Text('✕').fontSize(14).fontColor($r('app.color.text_secondary')).width(36).height(36)
          .textAlign(TextAlign.Center).onClick(() => this.audioPlayer.stop())
      }
      .padding({ left: 6, right: 4 })
      .width('100%')
      .backgroundColor($r('app.color.page_bg'))
      .border({ width: { top: 0.5 }, color: $r('app.color.separator') })
    }
  }

  @Builder
  ComposerBanner() {
    if (this.replyTo || this.editing) {
      Row({ space: 8 }) {
        Column() {
          Text(this.editing ? '编辑消息' : `回复 ${this.previewOf(this.replyTo!).name}`).fontSize(12)
            .fontColor($r('app.color.accent'))
          Text(this.editing ? summary(this.editing) : this.previewOf(this.replyTo!).text).fontSize(13).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('✕', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          if (this.editing) {
            this.draft = '';
          }
          this.replyTo = null;
          this.editing = null;
        })
      }
      .padding({ left: 12, right: 4 })
      .width('100%')
      .border({ width: { left: 3 }, color: { left: $r('app.color.accent') } })
    }
  }

  @Builder
  AttachMenu() {
    if (this.showAttach) {
      Flex({ wrap: FlexWrap.Wrap }) {
        this.AttachItem('🖼', '图片/视频', () => this.pickMedia())
        this.AttachItem('📷', '拍摄', () => this.takePhoto())
        this.AttachItem('📎', '文件', () => this.pickDocument())
        this.AttachItem('📍', '位置', () => this.sendLocation())
        if (this.chat && this.chat.type !== 'secret' && this.chat.type !== 'private') {
          this.AttachItem('📊', '投票', () => this.createPoll())
        } else {
          this.AttachItem('🔥', '阅后即焚', () => this.pickSelfDestructPhoto())
        }
        this.AttachItem('🎲', '骰子', () => this.sendDice('🎲'))
        this.AttachItem('🎯', '飞镖', () => this.sendDice('🎯'))
        this.AttachItem('🏀', '篮球', () => this.sendDice('🏀'))
        this.AttachItem('🎰', '老虎机', () => this.sendDice('🎰'))
      }
      .padding(10)
      .width('100%')
      .backgroundColor($r('app.color.page_alt'))
    }
  }

  @Builder
  AttachItem(icon: string, label: string, fn: () => void) {
    Column({ space: 4 }) {
      Text(icon).fontSize(26).width(52).height(52).textAlign(TextAlign.Center).borderRadius(26)
        .backgroundColor($r('app.color.card'))
      Text(label).fontSize(12).fontColor($r('app.color.text_primary'))
    }
    // One row on the unfolded screen, two or three on the cover screen.
    .width(`${100 / columnsFor(this.paneW - 20, 84, 4, 9)}%`)
    .padding(6)
    .onClick(fn)
  }

  @Builder
  BottomAction(p: BottomP) {
    Row() {
      Button(p.label, { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => p.fn())
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(52)
  }

  @Builder
  Composer() {
    if (this.joinable) {
      this.BottomAction({ label: this.chat && this.chat.type === 'channel' ? '关注频道' : '加入群组', fn: () => this.joinChat() })
    } else if (this.botStart && this.canSend) {
      this.BottomAction({ label: '开始', fn: () => this.pressStart() })
    } else if (!this.canSend) {
      if (this.chat && this.chat.type === 'channel') {
        this.BottomAction({ label: this.muted ? '取消静音' : '静音', fn: () => {
          if (this.chat) {
            this.acc.mute(this.chat, this.muted ? 0 : MUTE_FOREVER).catch(() => {});
          }
        } })
      } else {
        Row() {
          Text(this.secretBanner || '你不能在此聊天中发送消息').fontSize(14).fontColor($r('app.color.text_secondary'))
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height(52)
      }
    } else if (this.recording) {
      Row({ space: 10 }) {
        Column().width(10).height(10).borderRadius(5).backgroundColor(Color.Red)
        Text(`${Math.floor(this.recordSecs / 60)}:${(this.recordSecs % 60 < 10 ? '0' : '')}${this.recordSecs % 60}`)
          .fontSize(16).fontColor($r('app.color.text_primary'))
        Text('‹ 上滑取消').fontSize(14).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          .textAlign(TextAlign.Center)
        this.MicButton()
      }
      .padding({ left: 16, right: 6, top: 6, bottom: 6 })
      .width('100%')
    } else {
      Row({ space: 2 }) {
        Button(this.showPanel ? '⌨' : '😀', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(20)
          .onClick(() => {
            this.showPanel = !this.showPanel;
            this.showAttach = false;
            this.showKeyboard = false;
            if (this.showPanel) {
              this.input.stopEditing();
            }
          })
        TextArea({ placeholder: this.chat && this.chat.type === 'secret' ? '私密消息' : '消息', text: this.draft,
          controller: this.input })
          .layoutWeight(1)
          .constraintSize({ maxHeight: Math.min(140, Math.max(60, this.paneH * 0.3)) })
          .onChange((v: string) => this.onDraftChange(v))
          .onTextSelectionChange((start: number, end: number) => {
            this.caret = end;
            if (this.suggestions.length > 0 || this.draft.includes('@') || this.draft.startsWith('/')) {
              this.suggest();
            }
          })
          .onFocus(() => { this.closePanels(); })
          // A hardware keyboard sends with Enter; Shift+Enter starts a new line.
          .onKeyPreIme((e: KeyEvent): boolean => {
            if (e.keyCode !== KEY_ENTER || e.keySource !== KeySource.Keyboard) {
              return false;
            }
            if (e.getModifierKeyState && e.getModifierKeyState(['Shift'])) {
              return false;
            }
            if (e.type === KeyType.Down) {
              this.sendText();
            }
            return true;
          })
        if (this.draft.trim().length > 0) {
          Button(this.editing ? '✓' : '➤', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(22)
            .onClick(() => this.sendText())
            .gesture(LongPressGesture().onAction(() => {
              if (!this.editing) {
                const menu = new MenuState();
                menu.items.push(new PanelItem('静默发送（对方不会收到提示音）', () => this.sendText(true)));
                this.showMenu(menu);
              }
            }))
        } else {
          if (this.keyboard.length > 0) {
            Button(this.showKeyboard ? '⌄' : '⌘', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(18)
              .onClick(() => {
                this.showKeyboard = !this.showKeyboard;
                this.showAttach = false;
                this.showPanel = false;
                if (this.showKeyboard) {
                  this.input.stopEditing();
                }
              })
          }
          Button('📎', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(20)
            .onClick(() => {
              this.showAttach = !this.showAttach;
              this.showPanel = false;
              this.showKeyboard = false;
              if (this.showAttach) {
                this.input.stopEditing();
              }
            })
          this.MicButton()
        }
      }
      .padding({ left: 2, right: 2, top: 4, bottom: 4 })
      .width('100%')
    }
  }

  // Members to mention or bot commands matching what is being typed.
  @Builder
  Suggestions() {
    if (this.suggestions.length > 0) {
      List() {
        ForEach(this.suggestions, (s: Suggestion) => {
          ListItem() {
            Row({ space: 10 }) {
              if (!s.command) {
                Avatar({ title: s.title, seed: s.userId || s.title.length, path: s.photo, side: 30 })
              }
              Text(s.title).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(s.command ? $r('app.color.link') : $r('app.color.text_primary'))
              Text(s.detail).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('app.color.text_secondary')).layoutWeight(1)
            }
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .width('100%')
            .onClick(() => this.pickSuggestion(s))
          }
        }, (s: Suggestion) => `${s.insert}|${s.userId}|${s.photo}`)
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.min(200, Math.max(90, this.paneH * 0.3)) })
      .backgroundColor($r('app.color.page_bg'))
      .border({ width: { top: 0.5 }, color: $r('app.color.separator') })
    }
  }

  // Buttons a bot offers instead of typing; tapping one sends its text.
  @Builder
  BotKeyboard() {
    if (this.showKeyboard && this.keyboard.length > 0) {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.keyboard, (row: string[], ri: number) => {
            Row({ space: 6 }) {
              ForEach(row, (label: string, i: number) => {
                Button(label, { buttonStyle: ButtonStyleMode.NORMAL }).fontSize(14).height(40).layoutWeight(1)
                  .borderRadius(8).onClick(() => this.pressKey(label))
              }, (label: string, i: number) => `${ri}|${i}|${label}`)
            }
            .width('100%')
          }, (row: string[], ri: number) => `${ri}|${row.join('|')}`)
        }
        .padding(8)
      }
      .width('100%')
      .constraintSize({ maxHeight: panelHeight(this.paneH) })
      .backgroundColor($r('app.color.page_alt'))
    }
  }

  @Builder
  MicButton() {
    Text('🎤')
      .fontSize(22)
      .width(44)
      .height(44)
      .textAlign(TextAlign.Center)
      .borderRadius(22)
      .backgroundColor(this.recording ? $r('app.color.accent') : Color.Transparent)
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          this.startRecording();
        } else if (e.type === TouchType.Up) {
          this.stopRecording(false);
        } else if (e.type === TouchType.Move && e.touches[0].y < -80) {
          this.stopRecording(true);
        } else if (e.type === TouchType.Cancel) {
          this.stopRecording(true);
        }
      })
  }

  // Matches of a search or a tapped #hashtag. The panel is part of the
  // layout rather than an overlay, so the message it jumps to stays visible.
  @Builder
  SearchPanel() {
    Column() {
      Row({ space: 2 }) {
        Search({ value: this.searchQuery, placeholder: '搜索此聊天，或输入 #标签' })
          .layoutWeight(1)
          .height(38)
          .onChange((v: string) => { this.searchQuery = v; })
          .onSubmit(() => this.runSearch(true))
        Button('▲', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(13).onClick(() => this.stepHit(1))
        Button('▼', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(13).onClick(() => this.stepHit(-1))
        Button('✕', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.searchOpen = false; })
      }
      .padding({ left: 8, right: 2, top: 6, bottom: 2 })
      .width('100%')

      Text(this.searchBusy && this.hits.length === 0 ? '正在搜索…' :
        (this.searchedFor ? (this.hits.length === 0 ? `没有找到“${this.searchedFor}”` :
          `“${this.searchedFor}” · ${this.searchTotal} 条，点击跳转`) : '输入关键词后按回车搜索'))
        .fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 14, right: 14, top: 2, bottom: 4 })
        .width('100%')

      List({ scroller: this.hitScroller }) {
        ForEach(this.hits, (h: Hit) => {
          ListItem() {
            Column({ space: 2 }) {
              Row({ space: 6 }) {
                Text(h.name).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                Text(formatTime(h.date)).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              Text(h.text).fontSize(14).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('app.color.text_primary')).width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .width('100%')
            .backgroundColor(h.id === this.hitId ? $r('app.color.accent_soft') : Color.Transparent)
            .onClick(() => this.selectHit(h.id))
          }
        }, (h: Hit) => `${h.id}|${h.id === this.hitId}`)
      }
      .layoutWeight(1)
      .width('100%')
      .divider({ strokeWidth: 0.5, color: $r('app.color.separator'), startMargin: 14 })
      .onReachEnd(() => {
        this.moreHits();
      })
    }
    .width('100%')
    .height(panelHeight(this.paneH))
    .backgroundColor($r('app.color.page_bg'))
    .border({ width: { top: 0.5 }, color: $r('app.color.separator') })
  }

  @Builder
  Messages() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      List({ scroller: this.scroller }) {
        LazyForEach(this.source, (b: BubbleData) => {
          ListItem() {
            Column() {
              if (b.dayLabel) {
                Text(b.dayLabel).fontSize(12).fontColor(Color.White)
                  .padding({ left: 10, right: 10, top: 3, bottom: 3 }).borderRadius(10)
                  .backgroundColor($r('app.color.service_bg')).margin({ top: 8, bottom: 4 })
              }
              if (b.unreadDivider) {
                Text('未读消息').fontSize(12).fontColor($r('app.color.accent')).textAlign(TextAlign.Center)
                  .width('100%').padding({ top: 4, bottom: 4 }).margin({ top: 4, bottom: 4 })
                  .backgroundColor($r('app.color.accent_soft'))
              }
              if (b.hidden.length > 0) {
                // Filtered messages fold into one line; a tap shows them.
                Text(this.filteredLabel(b)).fontSize(12).fontColor($r('app.color.text_secondary'))
                  .padding({ left: 12, right: 12, top: 4, bottom: 4 }).borderRadius(11)
                  .backgroundColor($r('app.color.chip')).margin({ top: 3, bottom: 3 })
                  .onClick(() => this.reveal(b, true))
              } else {
                if (b.filtered) {
                  Text(`已过滤的消息${reasonText(b.filtered) ? ' · ' + reasonText(b.filtered) : ''} · 点击收起`)
                    .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
                    .padding({ left: 18, right: 18, top: 2 })
                    .textAlign(b.msg.outgoing ? TextAlign.End : TextAlign.Start)
                    .onClick(() => this.reveal(b, false))
                }
                MessageBubble({
                  data: b, actions: this.bubbleActions,
                  bubbleMax: bubbleMaxWidth(this.paneW), mediaW: mediaWidth(this.paneW),
                  mediaH: mediaMaxHeight(this.paneH), stickerSide: stickerSide(this.paneW)
                })
                  .translate({ x: this.swipeId === b.id ? this.swipeX : 0 })
              }
            }
            .width('100%')
            // Drag a message to the left to reply to it.
            .gesture(PanGesture({ direction: PanDirection.Left, distance: 12 })
              .onActionStart(() => {
                if (this.canSwipeReply(b)) {
                  this.swipeId = b.id;
                  this.swipeX = 0;
                }
              })
              .onActionUpdate((e: GestureEvent) => {
                if (this.swipeId === b.id) {
                  this.swipeX = Math.max(-72, Math.min(0, e.offsetX * 0.6));
                }
              })
              .onActionEnd(() => this.endSwipe(b, true))
              .onActionCancel(() => this.endSwipe(b, false)))
          }
        }, (b: BubbleData) => b.key)
      }
      .width('100%')
      .height('100%')
      .cachedCount(4)
      .scrollBar(BarState.Off)
      // Older messages inserted above must not move what is being read.
      .maintainVisibleContentPosition(true)
      .onReachStart(() => this.store.loadOlder())
      .onReachEnd(() => {
        this.atBottom = this.store.atLatest;
        this.store.loadNewer();
      })
      .onScrollIndex((start: number, end: number) => {
        this.visStart = start;
        this.visEnd = end;
        this.atBottom = end >= this.source.totalCount() - 1 && this.store.atLatest;
        this.showScrollDown = !this.atBottom;
        this.scheduleView();
      })

      if (this.count === 0) {
        Column() {
          Text('暂无消息').fontSize(13).fontColor(Color.White).padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(12).backgroundColor($r('app.color.service_bg'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      } else if (this.count < 0) {
        Column() {
          LoadingProgress().width(36).height(36).color($r('app.color.accent'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.mentionCount > 0) {
        FloatButton({ label: '@', count: this.mentionCount })
          .margin({ right: 12, bottom: this.showScrollDown ? 74 : 14 })
          .onClick(() => this.nextMention())
      }

      if (this.dropping) {
        Column() {
          Text('松开发送到此聊天').fontSize(16).fontColor(Color.White).padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .borderRadius(18).backgroundColor($r('app.color.accent'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.scrim'))
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.showScrollDown) {
        FloatButton({ count: this.unread })
          .margin({ right: 12, bottom: 14 })
          .onClick(() => this.scrollToBottom())
      }
    }
    .layoutWeight(1)
    .width('100%')
    .backgroundColor($r('app.color.chat_bg'))
    // Photos, videos, files and text dragged in from another window.
    .allowDrop([uniformTypeDescriptor.UniformDataType.IMAGE, uniformTypeDescriptor.UniformDataType.VIDEO,
      uniformTypeDescriptor.UniformDataType.FILE, uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
      uniformTypeDescriptor.UniformDataType.HYPERLINK])
    .onDragEnter(() => { this.dropping = this.canSend && !this.joinable; })
    .onDragLeave(() => { this.dropping = false; })
    .onDrop((e: DragEvent) => this.handleDrop(e))
  }

  private canSwipeReply(b: BubbleData): boolean {
    return this.canSend && !this.joinable && this.selected.length === 0 && b.msg.kind !== 'service' &&
      b.hidden.length === 0 && !b.msg.pending && !b.msg.failed;
  }

  private endSwipe(b: BubbleData, commit: boolean): void {
    if (this.swipeId !== b.id) {
      return;
    }
    const far = this.swipeX <= -48;
    animateTo({ duration: 140 }, () => {
      this.swipeX = 0;
    });
    setTimeout((): void => {
      if (this.swipeId === b.id) {
        this.swipeId = 0;
      }
    }, 160);
    if (commit && far) {
      this.editing = null;
      this.replyTo = b.msg;
    }
  }

  build() {
    Stack() {
      Column() {
        this.Header()
        this.PlayerBar()
        if (this.secretBanner) {
          Text(this.secretBanner).fontSize(13).fontColor($r('app.color.secret')).padding(6).width('100%')
            .textAlign(TextAlign.Center).backgroundColor($r('app.color.inset'))
        }
        if (this.pinnedText) {
          Row({ space: 8 }) {
            Column().width(3).height(30).backgroundColor($r('app.color.accent'))
            Column() {
              Text('置顶消息').fontSize(12).fontColor($r('app.color.accent'))
              Text(this.pinnedText).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor($r('app.color.text_primary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .width('100%')
          .onClick(() => {
            if (this.store.pinned) {
              this.jumpTo(this.store.pinned.id);
            }
          })
        }
        this.Messages()
        if (this.searchOpen) {
          this.SearchPanel()
        } else {
          Column() {
            this.Suggestions()
            this.ComposerBanner()
            this.Composer()
            this.BotKeyboard()
            this.AttachMenu()
            if (this.showPanel) {
              StickerPanel({
                account: this.acc,
                paneW: this.paneW,
                panelH: panelHeight(this.paneH),
                onEmoji: (e: string) => { this.draft += e; },
                onSticker: (fileId: number) => {
                  this.showPanel = false;
                  this.after(this.store.sendSticker(fileId, this.opts()));
                },
                onGif: (fileId: number) => {
                  this.showPanel = false;
                  this.after(this.store.sendAnimation(fileId, this.opts()));
                }
              })
            }
          }
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')

      ForEach(this.menus, (m: MenuState) => {
        ActionPanel({
          title: m.title, emojis: m.emojis, chosen: m.chosen, items: m.items, maxH: this.paneH,
          onEmoji: m.onEmoji,
          onClose: (): void => { this.menus = []; }
        })
      }, (m: MenuState) => `${m.seq}`)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .onAreaChange((_: Area, area: Area) => {
      this.paneW = Number(area.width);
      this.paneH = Number(area.height);
    })
  }
}
