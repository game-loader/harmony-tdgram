import { decodeWaveform, formatSize, formatTime, minithumbUri } from '../common/Util';
import { InlineButton, MsgItem, PollOptionItem, ReactionItem } from '../td/Models';
import { formatDuration } from '../td/Parse';
import { FormattedText } from './FormattedText';
import { StickerView } from './StickerView';
import { AlbumBox, albumLayout, Cell } from './AlbumLayout';

// One photo or video of an album, resolved like a single-media bubble.
export class AlbumItem {
  msg: MsgItem;
  filePath: string = '';
  thumbPath: string = '';
  progress: number = -1;

  constructor(msg: MsgItem) {
    this.msg = msg;
  }
}

// Everything a bubble renders, resolved by the chat view (file paths, names,
// playback state). `key` changes whenever any of it changes.
export class BubbleData {
  msg: MsgItem;
  id: number = 0; // message id when sealed; identifies the row in the list
  senderName: string = '';
  showSender: boolean = false;
  filePath: string = '';
  thumbPath: string = '';
  progress: number = -1; // download/upload percent, -1 when idle
  replyName: string = '';
  replyText: string = '';
  read: boolean = false; // outgoing message read by the peer
  playing: boolean = false;
  playPos: number = 0;   // 0..1
  translated: string = '';
  selected: boolean = false;
  highlight: boolean = false; // just jumped to
  autoplay: boolean = true;
  dayLabel: string = '';
  unreadDivider: boolean = false; // "unread messages" line above this bubble
  mapPath: string = '';   // map image of a location message
  canThread: boolean = false; // show the comments / replies row
  // Albums: every item, in order. `msg` is the item carrying the caption.
  album: AlbumItem[] = [];
  key: string = '';

  constructor(msg: MsgItem) {
    this.msg = msg;
  }

  seal(): BubbleData {
    this.id = this.msg.id;
    this.key = [this.msg.id, this.msg.version, this.filePath, this.thumbPath, this.progress, this.replyText,
      this.read, this.playing, Math.round(this.playPos * 100), this.translated, this.selected, this.showSender,
      this.senderName, this.dayLabel, this.highlight, this.unreadDivider, this.mapPath, this.canThread].join('|') +
    this.album.map((a: AlbumItem) => `#${a.msg.id}.${a.msg.version}.${a.filePath}.${a.thumbPath}.${a.progress}`).join('');
    return this;
  }

  // Message ids this bubble stands for.
  ids(): number[] {
    return this.album.length > 0 ? this.album.map((a: AlbumItem) => a.msg.id) : [this.msg.id];
  }
}

export interface BubbleActions {
  onOpenMedia: (d: BubbleData) => void;
  onOpenAlbumItem: (d: BubbleData, index: number) => void;
  onAudio: (d: BubbleData) => void;
  onSeek: (d: BubbleData, fraction: number) => void;
  onFile: (d: BubbleData) => void;
  onVote: (d: BubbleData, options: number[]) => void;
  onThread: (d: BubbleData) => void;
  onRetry: (d: BubbleData) => void;
  onLocation: (d: BubbleData) => void;
  onContact: (d: BubbleData) => void;
  onButton: (d: BubbleData, b: InlineButton) => void;
  onReact: (d: BubbleData, emoji: string) => void;
  onJump: (id: number) => void;
  onMenu: (d: BubbleData) => void;
  onTap: (d: BubbleData) => boolean; // true when consumed (selection mode)
  onLink: (url: string) => void;
  onMention: (d: BubbleData, name: string, userId: number) => void;
  onSender: (d: BubbleData) => void;
}

function chunk(list: ReactionItem[], size: number): ReactionItem[][] {
  const out: ReactionItem[][] = [];
  for (let i = 0; i < list.length; i += size) {
    out.push(list.slice(i, i + size));
  }
  return out;
}

function mediaSize(m: MsgItem, maxW: number, maxH: number): number[] {
  if (!m.width || !m.height) {
    return [maxW, maxW * 0.75];
  }
  const scale = Math.min(maxW / m.width, maxH / m.height);
  return [Math.max(120, m.width * scale), Math.max(80, m.height * scale)];
}

@Component
export struct MessageBubble {
  // Rows are re-created whenever data.key changes, so this is not state.
  data: BubbleData = new BubbleData(new MsgItem());
  actions: BubbleActions | null = null;
  // Sizes follow the width of the chat pane (cover screen, unfolded, split).
  @Prop bubbleMax: number = 320;
  @Prop mediaW: number = 240;
  @Prop mediaH: number = 320;
  @Prop stickerSide: number = 180;
  @State picked: number[] = []; // options ticked in a multiple-choice poll, before voting

  // ---- Header pieces ----

  @Builder
  Forwarded() {
    if (this.data.msg.forwardFrom) {
      Text(`转发自 ${this.data.msg.forwardFrom}`).fontSize(12).fontColor($r('app.color.link')).maxLines(1)
    }
  }

  @Builder
  Reply() {
    if (this.data.msg.replyToId) {
      Column() {
        Text(this.data.replyName || '回复').fontSize(12).fontColor($r('app.color.link')).maxLines(1)
        Text(this.data.replyText || '…').fontSize(12).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.bubble_meta'))
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8, top: 2, bottom: 2, right: 4 })
      .border({ width: { left: 2 }, color: { left: $r('app.color.link') } })
      .backgroundColor($r('app.color.inset'))
      .borderRadius(4)
      .onClick(() => this.actions?.onJump(this.data.msg.replyToId))
    }
  }

  // ---- Media ----

  @Builder
  Progress() {
    if (this.data.progress >= 0) {
      Stack() {
        Progress({ value: this.data.progress, total: 100, type: ProgressType.Ring })
          .width(44).height(44).color(Color.White)
          .style({ strokeWidth: 3 })
      }
      .width(52).height(52).borderRadius(26).backgroundColor('#66000000')
    }
  }

  @Builder
  Visual(isVideo: boolean) {
    Stack() {
      if (this.data.msg.kind === 'photo' && this.data.filePath) {
        Image('file://' + this.data.filePath).width('100%').height('100%').objectFit(ImageFit.Cover)
          .blur(this.data.msg.hasSpoiler ? 30 : 0)
      } else if (this.data.msg.kind === 'animation' && this.data.filePath && this.data.autoplay) {
        Video({ src: 'file://' + this.data.filePath })
          .width('100%').height('100%').autoPlay(true).loop(true).muted(true).controls(false)
          .objectFit(ImageFit.Cover)
      } else if (this.data.thumbPath && !this.data.msg.thumbIsVideo) {
        Image('file://' + this.data.thumbPath).width('100%').height('100%').objectFit(ImageFit.Cover)
          .blur(this.data.msg.hasSpoiler ? 30 : 0)
      } else if (this.data.msg.minithumb) {
        Image(minithumbUri(this.data.msg.minithumb)).width('100%').height('100%').objectFit(ImageFit.Cover)
          .blur(12)
      } else {
        Column().width('100%').height('100%').backgroundColor('#33000000')
      }
      if (this.data.progress >= 0) {
        this.Progress()
      } else if (isVideo) {
        Text('▶').fontSize(22).fontColor(Color.White).width(48).height(48).textAlign(TextAlign.Center)
          .borderRadius(24).backgroundColor('#66000000')
      } else if (this.data.msg.hasSpoiler) {
        Text('点击查看').fontSize(14).fontColor(Color.White).padding(6).borderRadius(8).backgroundColor('#66000000')
      }
      if (this.data.msg.kind === 'video' || this.data.msg.kind === 'animation') {
        Text(this.data.msg.kind === 'animation' ? 'GIF' : formatDuration(this.data.msg.duration))
          .fontSize(11).fontColor(Color.White).padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .borderRadius(6).backgroundColor('#66000000')
          .position({ x: 6, y: 6 })
      }
      if (this.data.msg.selfDestructTime) {
        Text(`🔥 ${this.data.msg.selfDestructTime}s`).fontSize(11).fontColor(Color.White)
          .padding(4).borderRadius(6).backgroundColor('#99E84026').position({ x: 6, y: 28 })
      }
    }
    .width(mediaSize(this.data.msg, this.mediaW, this.mediaH)[0])
    .height(mediaSize(this.data.msg, this.mediaW, this.mediaH)[1])
    .borderRadius(10)
    .clip(true)
    .onClick(() => this.tapOr(() => this.actions?.onOpenMedia(this.data)))
  }

  @Builder
  AlbumCell(a: AlbumItem, c: Cell, index: number) {
    Stack() {
      if (a.msg.kind === 'photo' && a.filePath) {
        Image('file://' + a.filePath).width('100%').height('100%').objectFit(ImageFit.Cover)
          .blur(a.msg.hasSpoiler ? 30 : 0)
      } else if (a.thumbPath && !a.msg.thumbIsVideo) {
        Image('file://' + a.thumbPath).width('100%').height('100%').objectFit(ImageFit.Cover)
          .blur(a.msg.hasSpoiler ? 30 : 0)
      } else if (a.msg.minithumb) {
        Image(minithumbUri(a.msg.minithumb)).width('100%').height('100%').objectFit(ImageFit.Cover).blur(12)
      } else {
        Column().width('100%').height('100%').backgroundColor('#33000000')
      }
      if (a.progress >= 0) {
        Stack() {
          Progress({ value: a.progress, total: 100, type: ProgressType.Ring })
            .width(36).height(36).color(Color.White).style({ strokeWidth: 3 })
        }
        .width(42).height(42).borderRadius(21).backgroundColor('#66000000')
      } else if (a.msg.kind === 'video') {
        Text('▶').fontSize(18).fontColor(Color.White).width(40).height(40).textAlign(TextAlign.Center)
          .borderRadius(20).backgroundColor('#66000000')
      }
      if (a.msg.kind === 'video') {
        Text(formatDuration(a.msg.duration)).fontSize(11).fontColor(Color.White)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 }).borderRadius(6).backgroundColor('#66000000')
          .position({ x: 4, y: 4 })
      }
    }
    .position({ x: c.x, y: c.y })
    .width(c.w)
    .height(c.h)
    .clip(true)
    .onClick(() => this.tapOr(() => this.actions?.onOpenAlbumItem(this.data, index)))
  }

  @Builder
  Album() {
    Stack() {
      ForEach(this.data.album, (a: AlbumItem, i: number) => {
        this.AlbumCell(a, this.layout().cells[i], i)
      }, (a: AlbumItem) => `${a.msg.id}|${a.msg.version}|${a.filePath}|${a.thumbPath}|${a.progress}|${this.albumW()}`)
    }
    .width(this.layout().width)
    .height(this.layout().height)
    .borderRadius(10)
    .clip(true)
  }

  private cachedLayout: AlbumBox | null = null;
  private cachedFor: string = '';

  private albumW(): number {
    return Math.min(this.mediaW + 20, this.bubbleMax - 20);
  }

  layout(): AlbumBox {
    const sig = this.data.album.map((a: AlbumItem) => `${a.msg.width}x${a.msg.height}`).join(',') +
      `|${this.albumW()}|${this.mediaH}`;
    if (!this.cachedLayout || this.cachedFor !== sig) {
      this.cachedFor = sig;
      this.cachedLayout = albumLayout(this.data.album.map((a: AlbumItem) =>
        a.msg.width && a.msg.height ? a.msg.width / a.msg.height : 1), this.albumW(), this.mediaH + 20);
    }
    return this.cachedLayout;
  }

  private noteSide(): number {
    return Math.min(200, this.mediaW);
  }

  @Builder
  VideoNote() {
    Stack() {
      if (this.data.playing && this.data.filePath) {
        Video({ src: 'file://' + this.data.filePath })
          .width('100%').height('100%').autoPlay(true).controls(false).objectFit(ImageFit.Cover)
          .onFinish(() => this.actions?.onAudio(this.data))
      } else if (this.data.thumbPath && !this.data.msg.thumbIsVideo) {
        Image('file://' + this.data.thumbPath).width('100%').height('100%').objectFit(ImageFit.Cover)
      } else if (this.data.msg.minithumb) {
        Image(minithumbUri(this.data.msg.minithumb)).width('100%').height('100%').objectFit(ImageFit.Cover).blur(8)
      } else {
        Column().width('100%').height('100%').backgroundColor('#33000000')
      }
      if (this.data.progress >= 0) {
        this.Progress()
      } else if (!this.data.playing) {
        Text('▶').fontSize(20).fontColor(Color.White).width(44).height(44).textAlign(TextAlign.Center)
          .borderRadius(22).backgroundColor('#66000000')
      }
      Text(formatDuration(this.data.msg.duration)).fontSize(11).fontColor(Color.White)
        .padding({ left: 5, right: 5 }).borderRadius(6).backgroundColor('#66000000')
        .position({ x: this.noteSide() * 0.08, y: this.noteSide() * 0.85 })
    }
    .width(this.noteSide()).height(this.noteSide()).borderRadius(this.noteSide() / 2).clip(true)
    .onClick(() => this.tapOr(() => this.actions?.onAudio(this.data)))
  }

  @Builder
  Voice() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        this.PlayButton()
        Column({ space: 2 }) {
          Row({ space: 1 }) {
            ForEach(decodeWaveform(this.data.msg.waveform, 40), (v: number, i: number) => {
              Column()
                .width(3)
                .height(Math.max(3, v * 24))
                .borderRadius(1.5)
                .backgroundColor(i / 40 <= this.data.playPos && this.data.playing ? $r('app.color.link') :
                  (this.data.msg.outgoing ? $r('app.color.wave_out') : $r('app.color.wave_in')))
            }, (v: number, i: number) => `${i}`)
          }
          .height(26)
          .alignItems(VerticalAlign.Center)
          .onTouch((e: TouchEvent) => {
            if (this.data.playing && e.type === TouchType.Up) {
              this.actions?.onSeek(this.data, Math.min(1, Math.max(0, e.touches[0].x / 160)));
            }
          })
          Row({ space: 6 }) {
            Text(formatDuration(this.data.playing ? this.data.playPos * this.data.msg.duration : this.data.msg.duration))
              .fontSize(12).fontColor($r('app.color.bubble_meta'))
            if (!this.data.msg.listened && !this.data.msg.outgoing) {
              Column().width(6).height(6).borderRadius(3).backgroundColor($r('app.color.link'))
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
      if (this.data.msg.recognized) {
        Text(this.data.msg.recognized).fontSize(14).fontColor($r('app.color.text_primary'))
          .constraintSize({ maxWidth: this.mediaW })
      }
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PlayButton() {
    Stack() {
      if (this.data.progress >= 0) {
        Progress({ value: this.data.progress, total: 100, type: ProgressType.Ring })
          .width(40).height(40).color(Color.White).style({ strokeWidth: 3 })
      } else {
        Text(this.data.playing ? '❚❚' : (this.data.filePath ? '▶' : '⬇')).fontSize(16).fontColor(Color.White)
      }
    }
    .width(44).height(44).borderRadius(22).backgroundColor($r('app.color.accent'))
    .onClick(() => this.tapOr(() => this.actions?.onAudio(this.data)))
  }

  @Builder
  Audio() {
    Row({ space: 10 }) {
      this.PlayButton()
      Column({ space: 2 }) {
        Text(this.data.msg.title).fontSize(14).fontWeight(FontWeight.Medium).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        Text(this.data.msg.performer || formatSize(this.data.msg.fileSize)).fontSize(12)
          .fontColor($r('app.color.bubble_meta')).maxLines(1)
        if (this.data.playing) {
          Slider({ value: this.data.playPos * 100, min: 0, max: 100 })
            .width(150).blockSize({ width: 10, height: 10 })
            .onChange((v: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End) {
                this.actions?.onSeek(this.data, v / 100);
              }
            })
        } else {
          Text(formatDuration(this.data.msg.duration)).fontSize(12).fontColor($r('app.color.bubble_meta'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width(this.mediaW)
  }

  @Builder
  Document() {
    Row({ space: 10 }) {
      Stack() {
        if (this.data.thumbPath) {
          Image('file://' + this.data.thumbPath).width(48).height(48).objectFit(ImageFit.Cover).borderRadius(8)
        }
        if (this.data.progress >= 0) {
          Progress({ value: this.data.progress, total: 100, type: ProgressType.Ring })
            .width(36).height(36).color(Color.White).style({ strokeWidth: 3 })
        } else if (!this.data.thumbPath) {
          Text(this.data.filePath ? '📄' : '⬇').fontSize(20).fontColor(Color.White)
        }
      }
      .width(48).height(48).borderRadius(8).backgroundColor($r('app.color.accent'))
      Column({ space: 2 }) {
        Text(this.data.msg.fileName).fontSize(14).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'))
        Text(this.data.progress >= 0 ? `${this.data.progress}% · ${formatSize(this.data.msg.fileSize)}` :
          formatSize(this.data.msg.fileSize)).fontSize(12).fontColor($r('app.color.bubble_meta'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width(this.mediaW)
    .onClick(() => this.tapOr(() => this.actions?.onFile(this.data)))
  }

  @Builder
  Poll() {
    Column({ space: 6 }) {
      Text(this.data.msg.pollQuestion).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Text(`${this.data.msg.pollQuiz ? '测验' : '投票'}${this.data.msg.pollClosed ? ' · 已结束' : ''}`)
        .fontSize(12).fontColor($r('app.color.bubble_meta'))
      ForEach(this.data.msg.pollOptions, (op: PollOptionItem, i: number) => {
        Column({ space: 2 }) {
          Row() {
            Text(`${op.chosen || this.picked.includes(i) ? '✓ ' : ''}${op.text}`).fontSize(14).layoutWeight(1)
              .fontColor($r('app.color.text_primary'))
            if (this.data.msg.pollVoted || this.data.msg.pollClosed) {
              Text(`${op.percent}%`).fontSize(13).fontColor($r('app.color.bubble_meta'))
            }
          }
          if (this.data.msg.pollVoted || this.data.msg.pollClosed) {
            Progress({ value: op.percent, total: 100, type: ProgressType.Linear }).color($r('app.color.link')).height(4)
          }
        }
        .width('100%')
        .padding(6)
        .borderRadius(6)
        .backgroundColor(this.picked.includes(i) ? $r('app.color.accent_soft') : $r('app.color.inset'))
        .onClick(() => {
          if (this.data.msg.pollVoted || this.data.msg.pollClosed) {
            return;
          }
          if (this.data.msg.pollMultiple) {
            this.picked = this.picked.includes(i) ? this.picked.filter((x: number) => x !== i) : this.picked.concat([i]);
          } else {
            this.actions?.onVote(this.data, [i]);
          }
        })
      }, (op: PollOptionItem, i: number) => `${i}|${op.voters}|${op.chosen}`)
      if (this.data.msg.pollMultiple && !this.data.msg.pollVoted && !this.data.msg.pollClosed) {
        Button('投票', { buttonStyle: ButtonStyleMode.NORMAL }).height(32).fontSize(13).width('100%')
          .enabled(this.picked.length > 0)
          .onClick(() => this.actions?.onVote(this.data, this.picked.slice().sort((a: number, b: number) => a - b)))
      }
      Text(`${this.data.msg.pollTotal} 人参与${this.data.msg.pollMultiple ? ' · 可多选' : ''}`).fontSize(12)
        .fontColor($r('app.color.bubble_meta'))
    }
    .alignItems(HorizontalAlign.Start)
    .width(this.mediaW)
  }

  @Builder
  Location() {
    Column({ space: 4 }) {
      Stack() {
        if (this.data.mapPath) {
          Image('file://' + this.data.mapPath).width('100%').height('100%').objectFit(ImageFit.Cover)
        }
        Text('📍').fontSize(this.data.mapPath ? 30 : 40)
      }
      .width(this.mediaW).height(130).borderRadius(8).backgroundColor($r('app.color.inset')).clip(true)
      if (this.data.msg.title) {
        Text(this.data.msg.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      }
      Text(this.data.msg.address || `${this.data.msg.lat.toFixed(5)}, ${this.data.msg.lon.toFixed(5)}`)
        .fontSize(12).fontColor($r('app.color.bubble_meta'))
    }
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.tapOr(() => this.actions?.onLocation(this.data)))
  }

  @Builder
  Contact() {
    Row({ space: 10 }) {
      Text('👤').fontSize(26).width(44).height(44).textAlign(TextAlign.Center).borderRadius(22)
        .backgroundColor($r('app.color.inset'))
      Column() {
        Text(this.data.msg.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(this.data.msg.phone).fontSize(12).fontColor($r('app.color.bubble_meta'))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .onClick(() => this.tapOr(() => this.actions?.onContact(this.data)))
  }

  // Card under a text message describing the first link in it.
  @Builder
  LinkPreview() {
    if (this.data.msg.linkUrl && (this.data.msg.linkTitle || this.data.msg.linkSite || this.data.msg.linkText)) {
      Column({ space: 2 }) {
        if (this.data.msg.linkSite) {
          Text(this.data.msg.linkSite).fontSize(13).fontColor($r('app.color.link')).fontWeight(FontWeight.Medium)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.data.msg.linkTitle) {
          Text(this.data.msg.linkTitle).fontSize(14).fontWeight(FontWeight.Medium).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
        }
        if (this.data.msg.linkText) {
          Text(this.data.msg.linkText).fontSize(13).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_primary'))
        }
        if (this.data.thumbPath && this.data.msg.width > 0 && this.data.msg.height > 0) {
          Image('file://' + this.data.thumbPath).objectFit(ImageFit.Cover).borderRadius(6).margin({ top: 4 })
            .width(this.mediaW - 12)
            .height(Math.min(170, (this.mediaW - 12) * this.data.msg.height / this.data.msg.width))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width(this.mediaW)
      .padding({ left: 8, right: 4, top: 4, bottom: 4 })
      .border({ width: { left: 2 }, color: { left: $r('app.color.link') } })
      .backgroundColor($r('app.color.inset'))
      .borderRadius(4)
      .onClick(() => this.tapOr(() => this.actions?.onLink(this.data.msg.linkUrl)))
    }
  }

  @Builder
  Content() {
    if (this.data.album.length > 0) {
      this.Album()
    } else if (this.data.msg.kind === 'photo' || this.data.msg.kind === 'animation') {
      this.Visual(false)
    } else if (this.data.msg.kind === 'video') {
      this.Visual(true)
    } else if (this.data.msg.kind === 'voice') {
      this.Voice()
    } else if (this.data.msg.kind === 'audio') {
      this.Audio()
    } else if (this.data.msg.kind === 'document') {
      this.Document()
    } else if (this.data.msg.kind === 'poll') {
      this.Poll()
    } else if (this.data.msg.kind === 'location') {
      this.Location()
    } else if (this.data.msg.kind === 'contact') {
      this.Contact()
    } else if (this.data.msg.kind === 'dice') {
      Text(`${this.data.msg.emoji}  ${this.data.msg.diceValue}`).fontSize(40)
    } else if (this.data.msg.kind === 'call') {
      Row({ space: 8 }) {
        Text(this.data.msg.callVideo ? '📹' : '📞').fontSize(22)
        Column() {
          Text(this.data.msg.outgoing ? '呼出' : (this.data.msg.callMissed ? '未接来电' : '呼入')).fontSize(14)
            .fontColor(this.data.msg.callMissed ? $r('app.color.danger') : $r('app.color.text_primary'))
          if (this.data.msg.duration) {
            Text(formatDuration(this.data.msg.duration)).fontSize(12).fontColor($r('app.color.bubble_meta'))
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
    }
    if (this.data.msg.text && this.data.msg.kind !== 'unsupported') {
      FormattedText({
        text: this.data.msg.text, entities: this.data.msg.entities,
        onLink: (u: string) => this.actions?.onLink(u),
        onMention: (n: string, id: number) => this.actions?.onMention(this.data, n, id)
      })
        .constraintSize({ maxWidth: this.data.album.length > 0 ? this.albumW() :
          (this.isMediaKind() ? this.mediaW : '100%') })
    } else if (this.data.msg.kind === 'unsupported') {
      Text(this.data.msg.text).fontSize(14).fontColor($r('app.color.bubble_meta')).fontStyle(FontStyle.Italic)
    }
    if (this.data.msg.kind === 'text') {
      this.LinkPreview()
    }
    if (this.data.translated) {
      Text(this.data.translated).fontSize(14).fontColor($r('app.color.secret')).padding({ top: 4 })
        .border({ width: { top: 0.5 }, color: { top: $r('app.color.separator') } })
    }
  }

  isMediaKind(): boolean {
    const k = this.data.msg.kind;
    return k === 'photo' || k === 'video' || k === 'animation' || k === 'document' || k === 'audio' || k === 'voice';
  }

  @Builder
  Footer() {
    Row({ space: 4 }) {
      if (this.data.msg.views) {
        Text(`👁 ${this.data.msg.views >= 1000 ? (this.data.msg.views / 1000).toFixed(1) + 'K' : this.data.msg.views}`)
          .fontSize(11).fontColor($r('app.color.bubble_meta'))
      }
      if (this.data.msg.editDate) {
        Text('已编辑').fontSize(11).fontColor($r('app.color.bubble_meta'))
      }
      Text(formatTime(this.data.msg.date)).fontSize(11).fontColor($r('app.color.bubble_meta'))
      if (this.data.msg.outgoing && this.data.msg.failed) {
        Text(this.data.msg.canRetry ? '⚠ 发送失败，点击重试' : '⚠ 发送失败').fontSize(11).fontColor($r('app.color.danger'))
          .onClick(() => {
            if (this.data.msg.canRetry) {
              this.actions?.onRetry(this.data);
            }
          })
      } else if (this.data.msg.outgoing) {
        Text(this.data.msg.pending ? '🕓' : (this.data.read ? '✓✓' : '✓')).fontSize(11).fontColor($r('app.color.tick'))
      }
    }
    // Hug the content: a full-width footer would stretch every bubble.
    .alignSelf(ItemAlign.End)
  }

  // Comments under a channel post, or the replies to a group message.
  @Builder
  ThreadRow() {
    if (this.data.canThread) {
      Row({ space: 6 }) {
        Text(this.data.msg.replyCount > 0 ? `💬 ${this.data.msg.replyCount} 条${this.data.msg.isChannelPost ? '评论' : '回复'}` :
          '💬 发表评论').fontSize(13).fontColor($r('app.color.link')).layoutWeight(1)
        Text('›').fontSize(15).fontColor($r('app.color.link'))
      }
      .width(this.threadW())
      .padding({ top: 6, bottom: 2 })
      .border({ width: { top: 0.5 }, color: { top: $r('app.color.separator') } })
      .onClick(() => this.tapOr(() => this.actions?.onThread(this.data)))
    }
  }

  private threadW(): number {
    return this.data.album.length > 0 ? this.albumW() : Math.min(this.mediaW, this.bubbleMax - 20);
  }

  @Builder
  Reactions() {
    if (this.data.msg.reactions.length > 0) {
      // Rows of four chips; a wrapping Flex would take the full bubble width.
      Column({ space: 4 }) {
        ForEach(chunk(this.data.msg.reactions, 4), (row: ReactionItem[], ri: number) => {
          Row({ space: 4 }) {
            ForEach(row, (r: ReactionItem) => {
              Text(`${r.emoji} ${r.count}`).fontSize(13)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(12)
                .backgroundColor(r.chosen ? $r('app.color.accent') : $r('app.color.accent_soft'))
                .fontColor(r.chosen ? Color.White : $r('app.color.link'))
                .onClick(() => this.actions?.onReact(this.data, r.emoji))
            }, (r: ReactionItem) => `${r.emoji}|${r.count}|${r.chosen}`)
          }
        }, (row: ReactionItem[], ri: number) => `${ri}|${row.map((r: ReactionItem) => r.emoji + r.count + r.chosen).join()}`)
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 2 })
    }
  }

  @Builder
  Buttons() {
    if (this.data.msg.buttons.length > 0) {
      Column({ space: 4 }) {
        ForEach(this.data.msg.buttons, (row: InlineButton[], ri: number) => {
          Row({ space: 4 }) {
            ForEach(row, (b: InlineButton) => {
              Button(b.url ? `${b.text} ↗` : b.text, { buttonStyle: ButtonStyleMode.NORMAL })
                .fontSize(13).height(34).layoutWeight(1).borderRadius(8)
                .labelStyle({ maxLines: 1, overflow: TextOverflow.Ellipsis })
                .onClick(() => this.actions?.onButton(this.data, b))
            }, (b: InlineButton, i: number) => `${ri}|${i}|${b.text}`)
          }
          .width('100%')
        }, (row: InlineButton[], ri: number) => `${ri}`)
      }
      // A fixed width, not '100%': the bubble has no width of its own (it hugs
      // its content up to a maximum), so a percentage would be taken from the
      // whole row and the buttons would stick out of the bubble.
      .width(this.buttonsW())
      .margin({ top: 4 })
    }
  }

  // Inline buttons span the widest bubble (minus its padding).
  private buttonsW(): number {
    return Math.min(this.bubbleMax - 20, 420);
  }

  private tapOr(fn: () => void): void {
    if (!this.actions || !this.actions.onTap(this.data)) {
      fn();
    }
  }

  // Stickers, round videos and dice are drawn without a bubble.
  isBare(): boolean {
    const k = this.data.msg.kind;
    return k === 'sticker' || k === 'videoNote' || (k === 'dice' && !this.data.msg.replyToId);
  }

  build() {
    if (this.data.msg.kind === 'service') {
      Row() {
        Text(this.data.msg.text).fontSize(13).fontColor(Color.White).textAlign(TextAlign.Center)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12)
          .backgroundColor($r('app.color.service_bg'))
          .constraintSize({ maxWidth: this.bubbleMax })
      }
      .width('100%').justifyContent(FlexAlign.Center).padding({ top: 4, bottom: 4 })
    } else {
      Row() {
        Column({ space: 4 }) {
          if (this.data.showSender && !this.data.msg.outgoing) {
            Text(this.data.senderName).fontSize(13).fontColor($r('app.color.link')).fontWeight(FontWeight.Medium)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => this.actions?.onSender(this.data))
          }
          this.Forwarded()
          this.Reply()
          if (this.data.msg.kind === 'sticker') {
            StickerView({ path: this.data.filePath, format: this.data.msg.stickerFormat,
              thumbPath: this.data.thumbPath, side: this.stickerSide, autoplay: this.data.autoplay })
              .onClick(() => this.tapOr(() => this.actions?.onOpenMedia(this.data)))
          } else if (this.data.msg.kind === 'videoNote') {
            this.VideoNote()
          } else {
            this.Content()
          }
          this.Buttons()
          this.Reactions()
          this.ThreadRow()
          this.Footer()
        }
        .alignItems(HorizontalAlign.Start)
        .padding(this.isBare() ? 2 : { left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor(this.isBare() ? Color.Transparent :
          (this.data.msg.outgoing ? $r('app.color.bubble_out') : $r('app.color.bubble_in')))
        .constraintSize({ maxWidth: this.bubbleMax })
        .gesture(LongPressGesture().onAction(() => this.actions?.onMenu(this.data)))
        .onClick(() => {
          this.actions?.onTap(this.data);
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .justifyContent(this.data.msg.outgoing ? FlexAlign.End : FlexAlign.Start)
      .backgroundColor(this.data.selected ? $r('app.color.selected') :
        (this.data.highlight ? $r('app.color.highlight') : Color.Transparent))
    }
  }
}
