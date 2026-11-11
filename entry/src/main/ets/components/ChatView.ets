import { router, promptAction } from '@kit.ArkUI';
import { common, abilityAccessCtrl, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { geoLocationManager } from '@kit.LocationKit';
import { AlbumItem, BubbleActions, BubbleData, MessageBubble } from './MessageBubble';
import { Avatar } from './Avatar';
import { StickerPanel } from './StickerPanel';
import { AppState, copyText, ForwardRequest, ViewerItem } from '../common/AppState';
import { copyToCache, fileNameOf, formatDay, lastSeen } from '../common/Util';
import { pickAction } from '../common/Menu';
import { Account } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { AccountEvent } from '../td/Core';
import { ChatItem, InlineButton, MsgItem } from '../td/Models';
import { formatTimer, summary } from '../td/Parse';
import { SendOptions } from '../td/MessageStore';
import { TdError, TdObject } from '../td/TdClient';
import { AudioService, VoiceRecorder } from '../services/AudioService';
import { EncodedVoice } from 'libtdbridge.so';

class ReplyPreview {
  name: string = '';
  text: string = '';
}

function isAlbumKind(m: MsgItem): boolean {
  return m.kind === 'photo' || m.kind === 'video';
}

const QUICK_REACTIONS: string[] = ['👍', '❤', '😂', '😮', '😢', '🔥', '👏', '🎉'];
const AUTO_DELETE_OPTIONS: number[] = [0, 5, 30, 60, 3600, 86400, 604800];

// Lets the hosting page forward the system back gesture to the chat.
export class ChatController {
  back: () => boolean = (): boolean => false;
}

// One open conversation. Hosted full-screen by pages/Chat, or as the right
// pane (wide windows) / the whole window (narrow windows) by pages/Main.
@Component
export struct ChatView {
  chatId: number = 0;
  messageId: number = 0;
  topicId: number = 0;    // forum topic shown, 0 for an ordinary chat
  topicName: string = '';
  showBack: boolean = true;
  controller: ChatController = new ChatController();
  onBack: () => void = (): void => {};
  onOpenChat: (chatId: number) => void = (): void => {};
  @State title: string = '';
  @State subtitle: string = '';
  @State photo: string = '';
  @State bubbles: BubbleData[] = [];
  @State draft: string = '';
  @State replyTo: MsgItem | null = null;
  @State editing: MsgItem | null = null;
  @State selected: number[] = [];
  @State pinnedText: string = '';
  @State secretBanner: string = '';
  @State canSend: boolean = true;
  @State showPanel: boolean = false;
  @State showAttach: boolean = false;
  @State recording: boolean = false;
  @State recordSecs: number = 0;
  @State showScrollDown: boolean = false;
  @State searchMode: boolean = false;
  @State searchQuery: string = '';
  private session: number = 0;
  private chat: ChatItem | undefined = undefined;
  private acc: Account = Accounts.get().active();
  private audioPlayer: AudioService = AudioService.get();
  private recorder: VoiceRecorder = new VoiceRecorder();
  private recordTimer: number = -1;
  private scroller: Scroller = new Scroller();
  private listener = (e: AccountEvent): void => this.onEvent(e);
  private audioListener = (): void => this.rebuild(false);
  private replyCache: Map<number, ReplyPreview> = new Map();
  private translations: Map<number, string> = new Map();
  private atBottom: boolean = true;
  private firstLoad: boolean = true;
  private pendingJump: number = 0;
  private lastShownId: number = 0;
  private lastTyping: number = 0;
  private searchResults: number[] = [];
  private searchIndex: number = 0;

  aboutToAppear(): void {
    this.pendingJump = this.messageId;
    this.controller.back = (): boolean => this.handleBack();
    this.chat = this.acc.chat(this.chatId);
    this.draft = this.chat && !this.topicId ? this.chat.draft : '';
    this.acc.on(this.listener);
    this.audioPlayer.on(this.audioListener);
    this.audioPlayer.onEnded = (key: string) => this.playNextVoice(key);
    this.session = this.acc.messages.open(this.chatId, this.topicId);
    this.refreshHeader();
    if (this.pendingJump) {
      this.jumpTo(this.pendingJump);
    }
  }

  aboutToDisappear(): void {
    // Drafts are per chat; a topic's draft would overwrite the chat's.
    if (this.chat && !this.topicId && !this.editing && this.draft !== this.chat.draft) {
      this.acc.messages.setDraft(this.chatId, this.draft.trim(), this.replyTo ? this.replyTo.id : 0);
    }
    this.acc.off(this.listener);
    this.audioPlayer.off(this.audioListener);
    this.acc.messages.close(this.session);
    if (this.recording) {
      this.recorder.stop(true);
    }
  }

  handleBack(): boolean {
    if (this.selected.length > 0) {
      this.selected = [];
      this.rebuild(false);
      return true;
    }
    if (this.showPanel || this.showAttach || this.searchMode) {
      this.showPanel = false;
      this.showAttach = false;
      this.searchMode = false;
      return true;
    }
    return false;
  }

  onEvent(e: AccountEvent): void {
    if (e === 'messages' || e === 'files') {
      this.rebuild(e === 'messages');
    } else if (e === 'typing' || e === 'chats') {
      this.refreshHeader();
    } else if (e === 'pinned') {
      const p = this.acc.messages.pinned;
      this.pinnedText = p ? summary(p) : '';
    }
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }
  private refreshHeader(): void {
    const c = this.acc.chat(this.chatId);
    if (!c) {
      return;
    }
    this.chat = c;
    this.title = this.topicId ? this.topicName : (c.userId === this.acc.myUserId ? '收藏夹' : c.title);
    this.photo = c.photoPath || this.acc.files.path(c.photoFileId);
    this.canSend = c.canSend;
    const typing = this.acc.chats.typingText(c.id);
    if (typing) {
      this.subtitle = typing;
    } else if (c.userId) {
      const u = this.acc.user(c.userId);
      this.subtitle = u ? (u.isBot ? '机器人' : lastSeen(u.status)) : '';
    } else {
      this.subtitle = this.topicId ? c.title : (c.type === 'channel' ? '频道' : '群组');
    }
    if (c.autoDeleteTime) {
      this.subtitle += ` · ${formatTimer(c.autoDeleteTime)}后自动删除`;
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
    const local = this.acc.messages.find(m.replyToId);
    if (local) {
      return this.previewOf(local);
    }
    const placeholder = new ReplyPreview();
    this.replyCache.set(m.replyToId, placeholder);
    this.acc.messages.fetch(m.chatId, m.replyToId).then((r: MsgItem) => {
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
    const msgs = this.acc.messages.messages;
    const isGroup = this.chat !== undefined && (this.chat.type === 'group' || this.chat.type === 'supergroup');
    const readUpTo = this.chat ? this.chat.lastReadOutboxId : 0;
    const settings = Accounts.get().settings;
    const prevLastId = this.lastShownId;
    const files = this.acc.files;
    const resolve = (m: MsgItem): AlbumItem => {
      const it = new AlbumItem(m);
      it.filePath = this.autoDownload(m) ? (m.filePath || files.path(m.fileId, 8)) : files.known(m.fileId, m.filePath);
      it.thumbPath = m.thumbPath || files.path(m.thumbFileId, 16);
      const prog = files.progress.get(m.fileId);
      it.progress = prog !== undefined && !it.filePath ? prog : -1;
      return it;
    };
    const out: BubbleData[] = [];
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
      const prev = i > 0 ? msgs[i - 1] : undefined;
      const captioned = group.find((x: MsgItem) => x.text !== '');
      const m = captioned ?? group[0];
      const d = new BubbleData(m);
      if (group.length > 1) {
        d.album = group.map(resolve);
      }
      d.showSender = isGroup && (!prev || prev.senderId !== m.senderId || prev.kind === 'service');
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
      d.autoplay = settings.autoplayGifs;
      if (!prev || formatDay(prev.date) !== formatDay(m.date)) {
        d.dayLabel = formatDay(m.date);
      }
      out.push(d.seal());
      i = j;
    }
    this.bubbles = out;
    const lastId = msgs.length > 0 ? msgs[msgs.length - 1].id : 0;
    this.lastShownId = lastId;
    if (!messagesChanged || this.bubbles.length === 0) {
      return;
    }
    if (this.pendingJump) {
      const idx = this.bubbles.findIndex((b: BubbleData) => b.ids().includes(this.pendingJump));
      if (idx >= 0) {
        this.pendingJump = 0;
        this.firstLoad = false;
        setTimeout((): void => { this.scroller.scrollToIndex(idx, false, ScrollAlign.CENTER); }, 0);
      }
      return;
    }
    if (this.firstLoad || (lastId !== prevLastId && this.atBottom)) {
      this.firstLoad = false;
      setTimeout((): void => { this.scroller.scrollToIndex(this.bubbles.length - 1); }, 0);
    }
  }

  jumpTo(id: number): void {
    const idx = this.bubbles.findIndex((b: BubbleData) => b.ids().includes(id));
    if (idx >= 0) {
      this.scroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
      return;
    }
    this.pendingJump = id;
    this.acc.messages.jumpTo(id).then((ok: boolean) => {
      if (!ok) {
        this.pendingJump = 0;
        promptAction.showToast({ message: '找不到原消息' });
      }
    }).catch(() => {
      this.pendingJump = 0;
    });
  }

  scrollToBottom(): void {
    if (!this.acc.messages.atLatest) {
      this.firstLoad = true;
      this.acc.messages.jumpToLatest();
    } else {
      this.scroller.scrollToIndex(this.bubbles.length - 1, true);
    }
  }
  // ---- Sending ----

  private opts(silent: boolean = false): SendOptions {
    return { replyTo: this.replyTo ? this.replyTo.id : 0, silent: silent };
  }

  private after(p: Promise<Object>): void {
    this.atBottom = true;
    this.replyTo = null;
    p.catch((e: TdError) => promptAction.showToast({ message: `发送失败：${e.message}` }));
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
      this.acc.messages.editText(m, text, md).catch((e: TdError) => promptAction.showToast({ message: e.message }));
      return;
    }
    this.draft = '';
    this.after(this.acc.messages.sendText(text, this.opts(silent), md));
    this.acc.messages.setDraft(this.chatId, '', 0);
  }

  onDraftChange(v: string): void {
    this.draft = v;
    const now = Date.now();
    if (v && now - this.lastTyping > 4000 && !Accounts.get().settings.ghostMode) {
      this.lastTyping = now;
      this.acc.messages.sendTyping('chatActionTyping');
    }
  }

  pickMedia(): void {
    this.showAttach = false;
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
    opts.maxSelectNumber = 10;
    new photoAccessHelper.PhotoViewPicker().select(opts).then((res: photoAccessHelper.PhotoSelectResult) => {
      const caption = this.draft.trim();
      this.draft = '';
      res.photoUris.forEach((uri: string, i: number) => {
        const name = fileNameOf(uri) || `media_${i}`;
        const path = copyToCache(this.ctx(), uri, name);
        const cap = i === 0 ? caption : '';
        if (/\.(mp4|mov|3gp|mkv|webm)$/i.test(name)) {
          this.sendVideoFile(path, cap);
        } else {
          this.after(this.acc.messages.sendPhoto(path, cap, this.opts(), false, 0));
        }
      });
    }).catch((e: Error) => promptAction.showToast({ message: `选择失败：${e.message}` }));
  }

  // Reads width, height and duration so the video gets a proper player bubble.
  private sendVideoFile(path: string, caption: string): void {
    media.createAVMetadataExtractor().then((ex: media.AVMetadataExtractor) => {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      ex.fdSrc = { fd: file.fd };
      return ex.fetchMetadata().then((meta: media.AVMetadata) => {
        ex.release();
        fs.closeSync(file);
        let w = Number(meta.videoWidth ?? 0);
        let h = Number(meta.videoHeight ?? 0);
        if (meta.videoOrientation === '90' || meta.videoOrientation === '270') {
          const t = w;
          w = h;
          h = t;
        }
        this.after(this.acc.messages.sendVideo(path, caption, this.opts(), w, h, Number(meta.duration ?? 0) / 1000, false));
      });
    }).catch(() => {
      this.after(this.acc.messages.sendVideo(path, caption, this.opts(), 0, 0, 0, false));
    });
  }

  pickSelfDestructPhoto(): void {
    this.showAttach = false;
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opts.maxSelectNumber = 1;
    new photoAccessHelper.PhotoViewPicker().select(opts).then((res: photoAccessHelper.PhotoSelectResult) => {
      if (res.photoUris.length === 0) {
        return;
      }
      const path = copyToCache(this.ctx(), res.photoUris[0], fileNameOf(res.photoUris[0]) || 'photo.jpg');
      this.after(this.acc.messages.sendPhoto(path, '', this.opts(), true, 10));
    }).catch(() => {});
  }

  pickDocument(): void {
    this.showAttach = false;
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 10;
    new picker.DocumentViewPicker(this.ctx()).select(opts).then((uris: string[]) => {
      for (const uri of uris) {
        const path = copyToCache(this.ctx(), uri, fileNameOf(uri) || 'file');
        this.after(this.acc.messages.sendDocument(path, '', this.opts()));
      }
    }).catch((e: Error) => promptAction.showToast({ message: `选择失败：${e.message}` }));
  }

  sendLocation(): void {
    this.showAttach = false;
    const perms: Permissions[] = ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'];
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.ctx(), perms).then(() => {
      return geoLocationManager.getCurrentLocation();
    }).then((loc: geoLocationManager.Location) => {
      this.after(this.acc.messages.sendLocation(loc.latitude, loc.longitude, this.opts()));
    }).catch(() => promptAction.showToast({ message: '无法获取位置' }));
  }

  createPoll(): void {
    this.showAttach = false;
    router.pushUrl({ url: 'pages/CreatePoll', params: { chatId: this.chatId } });
  }

  sendDice(emoji: string): void {
    this.showAttach = false;
    this.after(this.acc.messages.sendDice(emoji, this.opts()));
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
            this.acc.messages.sendTyping('chatActionRecordingVoiceNote');
          }
        }, 500);
      }).catch(() => promptAction.showToast({ message: '无法录音，请检查麦克风权限' }));
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
        this.after(this.acc.messages.sendVoice(path, res.duration, res.waveform, this.opts()));
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
      this.acc.messages.opened(m);
    }
    // Pager over every visual message of the loaded window, albums flattened.
    const visual: AlbumItem[] = [];
    for (const b of this.bubbles) {
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
      this.acc.messages.opened(m);
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
    this.audioPlayer.toggle(this.ctx(), `${m.chatId}:${m.id}`, d.filePath, isOpus, m.title || '语音消息');
  }

  // After a voice note ends, continue with the next unplayed one like official apps.
  private playNextVoice(key: string): void {
    const idx = this.bubbles.findIndex((b: BubbleData) => `${b.msg.chatId}:${b.msg.id}` === key);
    if (idx < 0) {
      return;
    }
    for (let i = idx + 1; i < this.bubbles.length; i++) {
      const b = this.bubbles[i];
      if (b.msg.kind === 'voice' && b.filePath) {
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
      promptAction.showToast({ message: '已保存' });
    }).catch((e: Error) => promptAction.showToast({ message: `保存失败：${e.message}` }));
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
        this.onOpenChat(id);
      }).catch(() => {});
    } else {
      copyText(d.msg.phone, '已复制电话号码');
    }
  }

  vote(d: BubbleData, option: number): void {
    this.acc.messages.vote(d.msg, [option]).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  pressButton(d: BubbleData, b: InlineButton): void {
    if (b.url) {
      this.openUrl(b.url);
      return;
    }
    if (b.data) {
      this.acc.messages.callback(d.msg, b.data).then((r: TdObject) => {
        const text = r['text'] as string;
        const url = r['url'] as string;
        if (url) {
          this.openUrl(url);
        } else if (text) {
          if (r['show_alert']) {
            promptAction.showDialog({ message: text, buttons: [{ text: '好', color: '#3A8DDE' }] });
          } else {
            promptAction.showToast({ message: text });
          }
        }
      }).catch(() => {});
    }
  }

  openUrl(url: string): void {
    if (/^(https?:\/\/)?(t\.me|telegram\.me)\//i.test(url) || url.startsWith('tg:')) {
      this.acc.openLink(url).then((chatId: number) => {
        if (chatId) {
          this.onOpenChat(chatId);
        }
      }).catch(() => promptAction.showToast({ message: '无法打开链接' }));
      return;
    }
    promptAction.showDialog({
      title: '打开链接？', message: url,
      buttons: [{ text: '复制', color: '#888888' }, { text: '打开', color: '#3A8DDE' }]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        this.ctx().openLink(url).catch(() => promptAction.showToast({ message: '没有可以打开此链接的应用' }));
      } else {
        copyText(url);
      }
    });
  }

  openMention(name: string, userId: number): void {
    if (userId) {
      router.pushUrl({ url: 'pages/Profile', params: { userId: userId } });
    } else if (name.startsWith('@')) {
      this.openUrl(`https://t.me/${name.substring(1)}`);
    } else if (name.startsWith('/')) {
      this.draft = name + ' ';
    }
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

  messageMenu(d: BubbleData): void {
    const m = d.msg;
    if (m.kind === 'service') {
      return;
    }
    this.acc.messages.properties(m).then((p: TdObject) => {
      const items: string[] = [];
      const actions: (() => void)[] = [];
      const add = (label: string, fn: () => void): void => {
        items.push(label);
        actions.push(fn);
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
        const pinned = this.acc.messages.pinned && this.acc.messages.pinned.id === m.id;
        add(pinned ? '取消置顶' : '置顶', () => {
          this.acc.messages.pin(m, !pinned).catch((e: TdError) => promptAction.showToast({ message: e.message }));
        });
      }
      if (m.kind === 'voice' || m.kind === 'videoNote') {
        add('转换为文字', () => {
          this.acc.messages.recognizeSpeech(m).catch((e: TdError) => promptAction.showToast({ message: e.message }));
        });
      }
      if (p['can_get_link']) {
        add('复制链接', () => {
          this.acc.messages.link(m).then((l: string) => copyText(l, '链接已复制')).catch(() => {});
        });
      }
      add('选择', () => {
        this.selected = d.ids();
        this.rebuild(false);
      });
      add('详细信息', () => this.showInfo(m));
      if (p['can_be_deleted_only_for_self'] || p['can_be_deleted_for_all_users']) {
        add('删除', () => this.confirmDelete(d.ids(), p['can_be_deleted_for_all_users'] as boolean));
      }
      this.showReactionsThenMenu(m, items, actions);
    }).catch(() => {});
  }

  // Quick reactions first (like the official app), then the action list.
  private showReactionsThenMenu(m: MsgItem, items: string[], actions: (() => void)[]): void {
    const show = (): void => {
      pickAction(items).then((index: number) => actions[index]()).catch(() => {});
    };
    if (this.chat && this.chat.type === 'secret') {
      show();
      return;
    }
    this.acc.messages.availableReactions(m).then((list: string[]) => {
      const emojis = (list.length > 0 ? list : QUICK_REACTIONS).slice(0, 6);
      items.unshift(`回应  ${emojis.join(' ')}`);
      actions.unshift(() => {
        pickAction(emojis, '回应').then((index: number) => this.react(m, emojis[index])).catch(() => {});
      });
      show();
    }).catch(() => show());
  }

  react(m: MsgItem, emoji: string): void {
    this.acc.messages.react(m, emoji).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  translateMessage(m: MsgItem): void {
    const lang = Accounts.get().settings.translateTo;
    this.acc.messages.translate(m, lang).then((t: string) => {
      this.translations.set(m.id, t);
      this.rebuild(false);
    }).catch((e: TdError) => promptAction.showToast({ message: `翻译失败：${e.message}` }));
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
          this.acc.messages.remove(this.chatId, ids, r.index === 2)
            .catch((e: TdError) => promptAction.showToast({ message: e.message }));
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
    router.pushUrl({ url: 'pages/Forward' });
  }

  // ---- Chat header menu ----

  chatMenu(): void {
    const c = this.chat;
    if (!c) {
      return;
    }
    const items: string[] = ['搜索消息', this.acc.chats.isMuted(c) ? '取消静音' : '静音', '自动删除消息', '清空聊天记录'];
    if (c.type === 'private' && c.userId !== this.acc.myUserId) {
      items.push('开始私密聊天');
    }
    if (c.type === 'secret') {
      items.push('查看加密密钥');
    }
    pickAction(items).then((index: number) => {
      const label = items[index];
      if (label === '搜索消息') {
        this.searchMode = true;
      } else if (label === '静音' || label === '取消静音') {
        this.acc.mute(c, label === '静音' ? 0x7FFFFFFF : 0).catch(() => {});
      } else if (label === '自动删除消息') {
        this.autoDeleteMenu(c);
      } else if (label === '清空聊天记录') {
        promptAction.showDialog({ title: '清空聊天记录？',
          buttons: [{ text: '取消', color: '#888888' }, { text: '清空', color: '#E84026' }] })
          .then((d: promptAction.ShowDialogSuccessResponse) => {
            if (d.index === 1) {
              this.acc.clearHistory(c, false).catch(() => {});
            }
          });
      } else if (label === '开始私密聊天') {
        this.acc.startSecretChat(c.userId).then((id: number) => {
          this.onOpenChat(id);
        }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
      } else if (label === '查看加密密钥') {
        router.pushUrl({ url: 'pages/SecretKey', params: { secretChatId: c.secretChatId, title: c.title } });
      }
    }).catch(() => {});
  }

  private autoDeleteMenu(c: ChatItem): void {
    pickAction(AUTO_DELETE_OPTIONS.map((x: number) => x === 0 ? '关闭' : formatTimer(x)), '自动删除消息')
      .then((index: number) => {
      this.acc.setAutoDelete(c, AUTO_DELETE_OPTIONS[index])
        .catch((e: TdError) => promptAction.showToast({ message: e.message }));
    }).catch(() => {});
  }

  runSearch(): void {
    const q = this.searchQuery.trim();
    if (!q) {
      return;
    }
    this.acc.messages.search(q, 'searchMessagesFilterEmpty', 0).then((list: MsgItem[]) => {
      this.searchResults = list.map((m: MsgItem) => m.id);
      this.searchIndex = 0;
      if (this.searchResults.length === 0) {
        promptAction.showToast({ message: '没有找到' });
      } else {
        this.jumpTo(this.searchResults[0]);
      }
    }).catch(() => {});
  }

  searchStep(delta: number): void {
    if (this.searchResults.length === 0) {
      return;
    }
    this.searchIndex = Math.min(this.searchResults.length - 1, Math.max(0, this.searchIndex + delta));
    this.jumpTo(this.searchResults[this.searchIndex]);
  }
  private actions(): BubbleActions {
    return {
      onOpenMedia: (d: BubbleData) => this.openMedia(d),
      onOpenAlbumItem: (d: BubbleData, i: number) => this.openAlbumItem(d, i),
      onAudio: (d: BubbleData) => this.playAudio(d),
      onSeek: (d: BubbleData, f: number) => this.audioPlayer.seek(f),
      onFile: (d: BubbleData) => this.openFile(d),
      onVote: (d: BubbleData, i: number) => this.vote(d, i),
      onLocation: (d: BubbleData) => this.openLocation(d),
      onContact: (d: BubbleData) => this.openContact(d),
      onButton: (d: BubbleData, b: InlineButton) => this.pressButton(d, b),
      onReact: (d: BubbleData, e: string) => this.react(d.msg, e),
      onJump: (id: number) => this.jumpTo(id),
      onMenu: (d: BubbleData) => this.messageMenu(d),
      onTap: (d: BubbleData) => this.onTap(d),
      onLink: (u: string) => this.openUrl(u),
      onMention: (n: string, id: number) => this.openMention(n, id),
      onSender: (d: BubbleData) => {
        if (!d.msg.senderIsChat) {
          router.pushUrl({ url: 'pages/Profile', params: { userId: d.msg.senderId } });
        }
      }
    };
  }

  @Builder
  Header() {
    if (this.selected.length > 0) {
      Row({ space: 8 }) {
        Button('✕', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          this.selected = [];
          this.rebuild(false);
        })
        Text(`已选择 ${this.selected.length} 条`).fontSize(17).layoutWeight(1)
        Button('复制', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          const texts = this.bubbles.filter((b: BubbleData) => b.selected)
            .map((b: BubbleData) => summary(b.msg));
          copyText(texts.join('\n'));
          this.selected = [];
          this.rebuild(false);
        })
        Button('转发', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.forward(this.selected, false))
        Button('删除', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor('#E84026')
          .onClick(() => this.confirmDelete(this.selected, true))
      }
      .padding({ left: 4, right: 4, top: 4, bottom: 4 })
      .width('100%')
    } else if (this.searchMode) {
      Row({ space: 4 }) {
        Search({ value: this.searchQuery, placeholder: '搜索此聊天' })
          .layoutWeight(1)
          .onChange((v: string) => { this.searchQuery = v; })
          .onSubmit(() => this.runSearch())
        Button('▲', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.searchStep(1))
        Button('▼', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.searchStep(-1))
        Button('✕', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.searchMode = false; })
      }
      .padding(4)
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
              .fontColor(this.chat && this.chat.type === 'secret' ? '#2E9E45' : $r('sys.color.ohos_id_color_text_primary'))
          }
          if (this.subtitle) {
            Text(this.subtitle).fontSize(12).maxLines(1)
              .fontColor(this.subtitle.endsWith('…') || this.subtitle === '在线' ? '#3A8DDE' : '#888888')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => {
          if (this.chat) {
            router.pushUrl({ url: 'pages/Profile', params: { userId: this.chat.userId, chatId: this.chat.id } });
          }
        })
        Button('⋮', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(22).onClick(() => this.chatMenu())
      }
      .padding({ left: this.showBack ? 0 : 12, right: 4, top: 2, bottom: 2 })
      .width('100%')
    }
  }

  @Builder
  ComposerBanner() {
    if (this.replyTo || this.editing) {
      Row({ space: 8 }) {
        Column() {
          Text(this.editing ? '编辑消息' : `回复 ${this.previewOf(this.replyTo!).name}`).fontSize(12).fontColor('#3A8DDE')
          Text(this.editing ? summary(this.editing) : this.previewOf(this.replyTo!).text).fontSize(13).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
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
      .border({ width: { left: 3 }, color: { left: '#3A8DDE' } })
    }
  }

  @Builder
  AttachMenu() {
    if (this.showAttach) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceAround }) {
        this.AttachItem('🖼', '图片/视频', () => this.pickMedia())
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
      .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
    }
  }

  @Builder
  AttachItem(icon: string, label: string, fn: () => void) {
    Column({ space: 4 }) {
      Text(icon).fontSize(26).width(52).height(52).textAlign(TextAlign.Center).borderRadius(26)
        .backgroundColor($r('sys.color.ohos_id_color_background'))
      Text(label).fontSize(12)
    }
    .width('25%')
    .padding(6)
    .onClick(fn)
  }

  @Builder
  Composer() {
    if (!this.canSend) {
      Row() {
        if (this.chat && this.chat.type === 'channel') {
          Button(this.chat && this.acc.chats.isMuted(this.chat) ? '取消静音' : '静音', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .onClick(() => {
              if (this.chat) {
                this.acc.mute(this.chat, this.acc.chats.isMuted(this.chat) ? 0 : 0x7FFFFFFF).catch(() => {});
              }
            })
        } else {
          Text(this.secretBanner || '你不能在此聊天中发送消息').fontSize(14).fontColor('#888888')
        }
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(52)
    } else if (this.recording) {
      Row({ space: 10 }) {
        Column().width(10).height(10).borderRadius(5).backgroundColor(Color.Red)
        Text(`${Math.floor(this.recordSecs / 60)}:${(this.recordSecs % 60 < 10 ? '0' : '')}${this.recordSecs % 60}`)
          .fontSize(16)
        Text('‹ 上滑取消').fontSize(14).fontColor('#888888').layoutWeight(1).textAlign(TextAlign.Center)
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
          })
        TextArea({ placeholder: this.chat && this.chat.type === 'secret' ? '私密消息' : '消息', text: this.draft })
          .layoutWeight(1)
          .constraintSize({ maxHeight: 140 })
          .onChange((v: string) => this.onDraftChange(v))
          .onFocus(() => { this.showPanel = false; })
        if (this.draft.trim().length > 0) {
          Button(this.editing ? '✓' : '➤', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(22)
            .onClick(() => this.sendText())
            .gesture(LongPressGesture().onAction(() => {
              pickAction(['静默发送（无通知）']).then(() => this.sendText(true)).catch(() => {});
            }))
        } else {
          Button('📎', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(20)
            .onClick(() => {
              this.showAttach = !this.showAttach;
              this.showPanel = false;
            })
          this.MicButton()
        }
      }
      .padding({ left: 2, right: 2, top: 4, bottom: 4 })
      .width('100%')
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
      .backgroundColor(this.recording ? '#3A8DDE' : Color.Transparent)
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

  build() {
    Column() {
      this.Header()
      if (this.secretBanner) {
        Text(this.secretBanner).fontSize(13).fontColor('#2E9E45').padding(6).width('100%')
          .textAlign(TextAlign.Center).backgroundColor('#E8F5E9')
      }
      if (this.pinnedText) {
        Row({ space: 8 }) {
          Column().width(3).height(30).backgroundColor('#3A8DDE')
          Column() {
            Text('置顶消息').fontSize(12).fontColor('#3A8DDE')
            Text(this.pinnedText).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .width('100%')
        .backgroundColor($r('sys.color.ohos_id_color_background'))
        .onClick(() => {
          if (this.acc.messages.pinned) {
            this.jumpTo(this.acc.messages.pinned.id);
          }
        })
      }
      Stack({ alignContent: Alignment.BottomEnd }) {
        List({ scroller: this.scroller }) {
          ForEach(this.bubbles, (b: BubbleData) => {
            ListItem() {
              Column() {
                if (b.dayLabel) {
                  Text(b.dayLabel).fontSize(12).fontColor(Color.White)
                    .padding({ left: 10, right: 10, top: 3, bottom: 3 }).borderRadius(10)
                    .backgroundColor('#55556677').margin({ top: 8, bottom: 4 })
                }
                MessageBubble({ data: b, actions: this.actions() })
              }
              .width('100%')
            }
          }, (b: BubbleData) => b.key)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#DCE5EC')
        .onReachStart(() => this.acc.messages.loadOlder())
        .onReachEnd(() => {
          this.atBottom = true;
          this.acc.messages.loadNewer();
        })
        .onScrollIndex((start: number, end: number) => {
          this.atBottom = end >= this.bubbles.length - 1 && this.acc.messages.atLatest;
          this.showScrollDown = !this.atBottom;
        })
        if (this.showScrollDown) {
          Text('⌄').fontSize(26).width(44).height(44).textAlign(TextAlign.Center).borderRadius(22)
            .backgroundColor(Color.White).shadow({ radius: 6, color: '#33000000' })
            .margin({ right: 14, bottom: 14 })
            .onClick(() => this.scrollToBottom())
        }
      }
      .layoutWeight(1)

      Column() {
        this.ComposerBanner()
        this.Composer()
        this.AttachMenu()
        if (this.showPanel) {
          StickerPanel({
            account: this.acc,
            onEmoji: (e: string) => { this.draft += e; },
            onSticker: (fileId: number) => {
              this.showPanel = false;
              this.after(this.acc.messages.sendSticker(fileId, this.opts()));
            },
            onGif: (fileId: number) => {
              this.showPanel = false;
              this.after(this.acc.messages.sendAnimation(fileId, this.opts()));
            }
          })
        }
      }
      .backgroundColor($r('sys.color.ohos_id_color_background'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
