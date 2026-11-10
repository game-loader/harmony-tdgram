import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { BubbleData, MessageBubble } from '../components/MessageBubble';
import { copyToCache, fileNameOf } from '../common/Util';
import { MsgItem } from '../td/Models';
import { Store, StoreEvent } from '../td/Store';
import { TdError } from '../td/TdClient';

interface ChatParams {
  chatId: number;
}

class ReplyPreview {
  name: string = '';
  text: string = '';
}

@Entry
@Component
struct Chat {
  @State title: string = '';
  @State bubbles: BubbleData[] = [];
  @State draft: string = '';
  @State replyTo: MsgItem | null = null;
  @State viewerPath: string = '';
  @State sending: boolean = false;
  private chatId: number = 0;
  private isPrivate: boolean = false;
  private store: Store = Store.get();
  private scroller: Scroller = new Scroller();
  private listener = (e: StoreEvent): void => this.onStore(e);
  private replyCache: Map<number, ReplyPreview> = new Map();
  private atBottom: boolean = true;
  private firstLoad: boolean = true;

  aboutToAppear(): void {
    const params = router.getParams() as ChatParams;
    this.chatId = params.chatId;
    const chat = this.store.chat(this.chatId);
    this.title = chat ? chat.title : '';
    this.isPrivate = chat ? chat.privateUserId !== 0 : false;
    this.store.on(this.listener);
    this.store.openChat(this.chatId);
  }

  aboutToDisappear(): void {
    this.store.off(this.listener);
    this.store.closeChat();
  }

  onBackPress(): boolean {
    if (this.viewerPath) {
      this.viewerPath = '';
      return true;
    }
    return false;
  }

  onStore(e: StoreEvent): void {
    if (e === 'messages' || e === 'files') {
      this.rebuild(e === 'messages');
    }
  }

  private replyPreview(msg: MsgItem): ReplyPreview {
    const cached = this.replyCache.get(msg.replyToId);
    if (cached) {
      return cached;
    }
    const local = this.store.findMessage(msg.replyToId);
    if (local) {
      return this.previewOf(local);
    }
    // Not in the loaded window: fetch once, then rebuild with the result.
    const placeholder = new ReplyPreview();
    this.replyCache.set(msg.replyToId, placeholder);
    this.store.fetchMessage(msg.chatId, msg.replyToId).then((m: MsgItem) => {
      this.replyCache.set(msg.replyToId, this.previewOf(m));
      this.rebuild(false);
    }).catch(() => {
      placeholder.text = '消息已删除';
    });
    return placeholder;
  }

  private previewOf(m: MsgItem): ReplyPreview {
    const p = new ReplyPreview();
    p.name = m.outgoing ? '我' : this.store.userName(m.senderId);
    p.text = m.text || (m.photoFileId ? '[图片]' : (m.docFileId ? `[文件] ${m.docName}` : ''));
    return p;
  }

  rebuild(messagesChanged: boolean): void {
    const msgs = this.store.messages;
    const prevLen = this.bubbles.length;
    const prevLastId = prevLen > 0 ? this.bubbles[prevLen - 1].msg.id : 0;
    this.bubbles = msgs.map((m: MsgItem, i: number) => {
      // Group consecutive messages from one sender: the name shows once.
      const showSender = !this.isPrivate && (i === 0 || msgs[i - 1].senderId !== m.senderId);
      const reply = m.replyToId ? this.replyPreview(m) : new ReplyPreview();
      return new BubbleData(m, this.store.userName(m.senderId), showSender,
        m.photoPath || this.store.filePath(m.photoFileId, 8), m.docPath || this.cachedDoc(m.docFileId),
        reply.name, reply.text);
    });
    if (!messagesChanged || this.bubbles.length === 0) {
      return;
    }
    const lastId = this.bubbles[this.bubbles.length - 1].msg.id;
    // Stick to the bottom on first load and on new messages, unless the
    // user scrolled up to read history.
    if (this.firstLoad || (lastId !== prevLastId && this.atBottom)) {
      this.firstLoad = false;
      setTimeout((): void => { this.scroller.scrollToIndex(this.bubbles.length - 1); }, 0);
    }
  }

  // Documents are only downloaded on tap; this just reports finished ones.
  private cachedDoc(fileId: number): string {
    return this.store.knownPath(fileId);
  }
  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private replyId(): number {
    return this.replyTo ? this.replyTo.id : 0;
  }

  private afterSend(p: Promise<Object>): void {
    this.sending = true;
    this.atBottom = true;
    p.then(() => {
      this.replyTo = null;
    }).catch((e: TdError) => {
      promptAction.showToast({ message: `发送失败：${e.message}` });
    }).finally(() => {
      this.sending = false;
    });
  }

  sendText(): void {
    const text = this.draft.trim();
    if (!text || this.sending) {
      return;
    }
    this.draft = '';
    this.afterSend(this.store.sendText(text, this.replyId()));
  }

  pickPhoto(): void {
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opts.maxSelectNumber = 1;
    new photoAccessHelper.PhotoViewPicker().select(opts).then((res: photoAccessHelper.PhotoSelectResult) => {
      if (res.photoUris.length === 0) {
        return;
      }
      const uri = res.photoUris[0];
      const path = copyToCache(this.ctx(), uri, fileNameOf(uri) || 'photo.jpg');
      const caption = this.draft.trim();
      this.draft = '';
      this.afterSend(this.store.sendPhoto(path, caption, this.replyId()));
    }).catch((e: Error) => {
      promptAction.showToast({ message: `选择图片失败：${e.message}` });
    });
  }

  pickDocument(): void {
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    new picker.DocumentViewPicker(this.ctx()).select(opts).then((uris: string[]) => {
      if (uris.length === 0) {
        return;
      }
      const path = copyToCache(this.ctx(), uris[0], fileNameOf(uris[0]) || 'file');
      const caption = this.draft.trim();
      this.draft = '';
      this.afterSend(this.store.sendDocument(path, caption, this.replyId()));
    }).catch((e: Error) => {
      promptAction.showToast({ message: `选择文件失败：${e.message}` });
    });
  }

  // First tap downloads; once downloaded, a tap exports via the save picker.
  openDocument(data: BubbleData): void {
    if (!data.docPath) {
      this.store.filePath(data.msg.docFileId, 16);
      promptAction.showToast({ message: '开始下载…' });
      return;
    }
    const opts = new picker.DocumentSaveOptions();
    opts.newFileNames = [data.msg.docName];
    new picker.DocumentViewPicker(this.ctx()).save(opts).then((uris: string[]) => {
      if (uris.length === 0) {
        return;
      }
      const src = fs.openSync(data.docPath, fs.OpenMode.READ_ONLY);
      const dst = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const buf = new ArrayBuffer(64 * 1024);
        let n = fs.readSync(src.fd, buf);
        while (n > 0) {
          fs.writeSync(dst.fd, buf.slice(0, n));
          n = fs.readSync(src.fd, buf);
        }
      } finally {
        fs.closeSync(src);
        fs.closeSync(dst);
      }
      promptAction.showToast({ message: '已保存' });
    }).catch((e: Error) => {
      promptAction.showToast({ message: `保存失败：${e.message}` });
    });
  }

  jumpTo(id: number): void {
    const idx = this.bubbles.findIndex((b: BubbleData) => b.msg.id === id);
    if (idx >= 0) {
      this.scroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    } else {
      promptAction.showToast({ message: '原消息不在已加载的范围内' });
    }
  }
  @Builder
  ReplyBar() {
    if (this.replyTo) {
      Row({ space: 8 }) {
        Column() {
          Text(`回复 ${this.previewOf(this.replyTo).name}`).fontSize(12).fontColor('#3A8DDE')
          Text(this.previewOf(this.replyTo).text).fontSize(13).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('✕', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.replyTo = null; })
      }
      .padding({ left: 12, right: 4 })
      .width('100%')
      .border({ width: { left: 3 }, color: { left: '#3A8DDE' } })
    }
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 4 }) {
          Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => router.back())
          Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
        .padding({ right: 12, top: 4, bottom: 4 })
        .width('100%')

        List({ scroller: this.scroller }) {
          ForEach(this.bubbles, (b: BubbleData) => {
            ListItem() {
              MessageBubble({
                data: b,
                onReply: (m: MsgItem) => { this.replyTo = m; },
                onJump: (id: number) => this.jumpTo(id),
                onOpenPhoto: (path: string) => { this.viewerPath = path; },
                onOpenDoc: (d: BubbleData) => this.openDocument(d)
              })
            }
          }, (b: BubbleData) => b.key)
        }
        .layoutWeight(1)
        .width('100%')
        .backgroundColor('#E6EBEE')
        .onReachStart(() => this.store.loadOlder())
        .onReachEnd(() => { this.atBottom = true; })
        .onScrollIndex((start: number, end: number) => {
          this.atBottom = end >= this.bubbles.length - 1;
        })

        this.ReplyBar()

        Row({ space: 4 }) {
          Button('🖼', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.pickPhoto())
          Button('📎', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.pickDocument())
          TextArea({ placeholder: '消息', text: this.draft })
            .layoutWeight(1)
            .constraintSize({ maxHeight: 120 })
            .onChange((v: string) => { this.draft = v; })
          Button('发送').enabled(!this.sending && this.draft.trim().length > 0).onClick(() => this.sendText())
        }
        .padding(6)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_background'))

      if (this.viewerPath) {
        // Full-screen photo viewer with pinch-to-zoom; tap to close.
        PhotoViewer({ path: this.viewerPath, onClose: () => { this.viewerPath = ''; } })
      }
    }
  }
}

@Component
struct PhotoViewer {
  @Prop path: string = '';
  onClose: () => void = () => {};
  @State scaleV: number = 1;
  @State offX: number = 0;
  @State offY: number = 0;
  private baseScale: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;

  build() {
    Stack() {
      Image('file://' + this.path)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .height('100%')
        .scale({ x: this.scaleV, y: this.scaleV })
        .translate({ x: this.offX, y: this.offY })
        .gesture(GestureGroup(GestureMode.Exclusive,
          PinchGesture()
            .onActionStart(() => { this.baseScale = this.scaleV; })
            .onActionUpdate((e: GestureEvent) => {
              this.scaleV = Math.min(Math.max(this.baseScale * e.scale, 1), 5);
            }),
          PanGesture()
            .onActionStart(() => { this.baseX = this.offX; this.baseY = this.offY; })
            .onActionUpdate((e: GestureEvent) => {
              if (this.scaleV > 1) {
                this.offX = this.baseX + e.offsetX;
                this.offY = this.baseY + e.offsetY;
              }
            }),
          TapGesture({ count: 2 }).onAction(() => { this.scaleV = 1; this.offX = 0; this.offY = 0; }),
          TapGesture().onAction(() => this.onClose())
        ))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
