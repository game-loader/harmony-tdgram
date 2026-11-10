import { decodeWaveform, formatSize, formatTime, minithumbUri } from '../common/Util';
import { InlineButton, MsgItem, PollOptionItem, ReactionItem } from '../td/Models';
import { formatDuration } from '../td/Parse';
import { FormattedText } from './FormattedText';
import { StickerView } from './StickerView';

// Everything a bubble renders, resolved by the page (file paths, names,
// playback state). `key` changes whenever any of it changes.
export class BubbleData {
  msg: MsgItem;
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
  autoplay: boolean = true;
  dayLabel: string = '';
  key: string = '';

  constructor(msg: MsgItem) {
    this.msg = msg;
  }

  seal(): BubbleData {
    this.key = [this.msg.id, this.msg.version, this.filePath, this.thumbPath, this.progress, this.replyText,
      this.read, this.playing, Math.round(this.playPos * 100), this.translated, this.selected, this.showSender,
      this.senderName, this.dayLabel].join('|');
    return this;
  }
}

export interface BubbleActions {
  onOpenMedia: (d: BubbleData) => void;
  onAudio: (d: BubbleData) => void;
  onSeek: (d: BubbleData, fraction: number) => void;
  onFile: (d: BubbleData) => void;
  onVote: (d: BubbleData, option: number) => void;
  onLocation: (d: BubbleData) => void;
  onContact: (d: BubbleData) => void;
  onButton: (d: BubbleData, b: InlineButton) => void;
  onReact: (d: BubbleData, emoji: string) => void;
  onJump: (id: number) => void;
  onMenu: (d: BubbleData) => void;
  onTap: (d: BubbleData) => boolean; // true when consumed (selection mode)
  onLink: (url: string) => void;
  onMention: (name: string, userId: number) => void;
  onSender: (d: BubbleData) => void;
}

const OUT_BG = '#D9F2C6';
const IN_BG = '#FFFFFF';
const MEDIA_W = 240;
const ACCENT = '#3A8DDE';
function mediaSize(m: MsgItem, maxW: number, maxH: number): number[] {
  if (!m.width || !m.height) {
    return [maxW, maxW * 0.75];
  }
  const scale = Math.min(maxW / m.width, maxH / m.height);
  return [Math.max(120, m.width * scale), Math.max(80, m.height * scale)];
}

@Component
export struct MessageBubble {
  @Prop data: BubbleData;
  actions: BubbleActions | null = null;

  // ---- Header pieces ----

  @Builder
  Forwarded() {
    if (this.data.msg.forwardFrom) {
      Text(`转发自 ${this.data.msg.forwardFrom}`).fontSize(12).fontColor(ACCENT).maxLines(1)
    }
  }

  @Builder
  Reply() {
    if (this.data.msg.replyToId) {
      Column() {
        Text(this.data.replyName || '回复').fontSize(12).fontColor(ACCENT).maxLines(1)
        Text(this.data.replyText || '…').fontSize(12).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor('#555555')
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8, top: 2, bottom: 2, right: 4 })
      .border({ width: { left: 2 }, color: { left: ACCENT } })
      .backgroundColor('#0F3A8DDE')
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
    .width(mediaSize(this.data.msg, MEDIA_W, 320)[0])
    .height(mediaSize(this.data.msg, MEDIA_W, 320)[1])
    .borderRadius(10)
    .clip(true)
    .onClick(() => this.tapOr(() => this.actions?.onOpenMedia(this.data)))
  }

  @Builder
  VideoNote() {
    Stack() {
      if (this.data.playing && this.data.filePath) {
        Video({ src: 'file://' + this.data.filePath })
          .width(200).height(200).autoPlay(true).controls(false).objectFit(ImageFit.Cover)
          .onFinish(() => this.actions?.onAudio(this.data))
      } else if (this.data.thumbPath && !this.data.msg.thumbIsVideo) {
        Image('file://' + this.data.thumbPath).width(200).height(200).objectFit(ImageFit.Cover)
      } else if (this.data.msg.minithumb) {
        Image(minithumbUri(this.data.msg.minithumb)).width(200).height(200).objectFit(ImageFit.Cover).blur(8)
      } else {
        Column().width(200).height(200).backgroundColor('#33000000')
      }
      if (this.data.progress >= 0) {
        this.Progress()
      } else if (!this.data.playing) {
        Text('▶').fontSize(20).fontColor(Color.White).width(44).height(44).textAlign(TextAlign.Center)
          .borderRadius(22).backgroundColor('#66000000')
      }
      Text(formatDuration(this.data.msg.duration)).fontSize(11).fontColor(Color.White)
        .padding({ left: 5, right: 5 }).borderRadius(6).backgroundColor('#66000000')
        .position({ x: 16, y: 170 })
    }
    .width(200).height(200).borderRadius(100).clip(true)
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
                .backgroundColor(i / 40 <= this.data.playPos && this.data.playing ? ACCENT :
                  (this.data.msg.outgoing ? '#8BC37A' : '#B5C7D8'))
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
              .fontSize(12).fontColor('#777777')
            if (!this.data.msg.listened && !this.data.msg.outgoing) {
              Column().width(6).height(6).borderRadius(3).backgroundColor(ACCENT)
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
      if (this.data.msg.recognized) {
        Text(this.data.msg.recognized).fontSize(14).fontColor('#333333').constraintSize({ maxWidth: MEDIA_W })
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
    .width(44).height(44).borderRadius(22).backgroundColor(ACCENT)
    .onClick(() => this.tapOr(() => this.actions?.onAudio(this.data)))
  }

  @Builder
  Audio() {
    Row({ space: 10 }) {
      this.PlayButton()
      Column({ space: 2 }) {
        Text(this.data.msg.title).fontSize(14).fontWeight(FontWeight.Medium).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.data.msg.performer || formatSize(this.data.msg.fileSize)).fontSize(12).fontColor('#777777').maxLines(1)
        if (this.data.playing) {
          Slider({ value: this.data.playPos * 100, min: 0, max: 100 })
            .width(150).blockSize({ width: 10, height: 10 })
            .onChange((v: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End) {
                this.actions?.onSeek(this.data, v / 100);
              }
            })
        } else {
          Text(formatDuration(this.data.msg.duration)).fontSize(12).fontColor('#777777')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width(MEDIA_W)
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
      .width(48).height(48).borderRadius(8).backgroundColor(ACCENT)
      Column({ space: 2 }) {
        Text(this.data.msg.fileName).fontSize(14).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.data.progress >= 0 ? `${this.data.progress}% · ${formatSize(this.data.msg.fileSize)}` :
          formatSize(this.data.msg.fileSize)).fontSize(12).fontColor('#777777')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width(MEDIA_W)
    .onClick(() => this.tapOr(() => this.actions?.onFile(this.data)))
  }
  @Builder
  Poll() {
    Column({ space: 6 }) {
      Text(this.data.msg.pollQuestion).fontSize(15).fontWeight(FontWeight.Medium)
      Text(`${this.data.msg.pollQuiz ? '测验' : '投票'}${this.data.msg.pollClosed ? ' · 已结束' : ''}`)
        .fontSize(12).fontColor('#777777')
      ForEach(this.data.msg.pollOptions, (op: PollOptionItem, i: number) => {
        Column({ space: 2 }) {
          Row() {
            Text(`${op.chosen ? '✓ ' : ''}${op.text}`).fontSize(14).layoutWeight(1)
            if (this.data.msg.pollVoted || this.data.msg.pollClosed) {
              Text(`${op.percent}%`).fontSize(13).fontColor('#555555')
            }
          }
          if (this.data.msg.pollVoted || this.data.msg.pollClosed) {
            Progress({ value: op.percent, total: 100, type: ProgressType.Linear }).color(ACCENT).height(4)
          }
        }
        .width('100%')
        .padding(6)
        .borderRadius(6)
        .backgroundColor('#0D000000')
        .onClick(() => {
          if (!this.data.msg.pollVoted && !this.data.msg.pollClosed) {
            this.actions?.onVote(this.data, i);
          }
        })
      }, (op: PollOptionItem, i: number) => `${i}|${op.voters}|${op.chosen}`)
      Text(`${this.data.msg.pollTotal} 人参与`).fontSize(12).fontColor('#777777')
    }
    .alignItems(HorizontalAlign.Start)
    .width(MEDIA_W)
  }

  @Builder
  Location() {
    Column({ space: 4 }) {
      Stack() {
        Text('📍').fontSize(40)
      }
      .width(MEDIA_W).height(120).borderRadius(8).backgroundColor('#DDE8D4')
      if (this.data.msg.title) {
        Text(this.data.msg.title).fontSize(14).fontWeight(FontWeight.Medium)
      }
      Text(this.data.msg.address || `${this.data.msg.lat.toFixed(5)}, ${this.data.msg.lon.toFixed(5)}`)
        .fontSize(12).fontColor('#555555')
    }
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.tapOr(() => this.actions?.onLocation(this.data)))
  }

  @Builder
  Contact() {
    Row({ space: 10 }) {
      Text('👤').fontSize(26).width(44).height(44).textAlign(TextAlign.Center).borderRadius(22)
        .backgroundColor('#E0E8F0')
      Column() {
        Text(this.data.msg.title).fontSize(14).fontWeight(FontWeight.Medium)
        Text(this.data.msg.phone).fontSize(12).fontColor('#555555')
      }
      .alignItems(HorizontalAlign.Start)
    }
    .onClick(() => this.tapOr(() => this.actions?.onContact(this.data)))
  }

  @Builder
  Content() {
    if (this.data.msg.kind === 'photo' || this.data.msg.kind === 'animation') {
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
            .fontColor(this.data.msg.callMissed ? Color.Red : '#000000')
          if (this.data.msg.duration) {
            Text(formatDuration(this.data.msg.duration)).fontSize(12).fontColor('#777777')
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
    }
    if (this.data.msg.text && this.data.msg.kind !== 'unsupported') {
      FormattedText({
        text: this.data.msg.text, entities: this.data.msg.entities,
        onLink: (u: string) => this.actions?.onLink(u),
        onMention: (n: string, id: number) => this.actions?.onMention(n, id)
      })
        .constraintSize({ maxWidth: this.isMediaKind() ? MEDIA_W : '100%' })
    } else if (this.data.msg.kind === 'unsupported') {
      Text(this.data.msg.text).fontSize(14).fontColor('#777777').fontStyle(FontStyle.Italic)
    }
    if (this.data.translated) {
      Text(this.data.translated).fontSize(14).fontColor('#2F6F3F').padding({ top: 4 })
        .border({ width: { top: 0.5 }, color: { top: '#33000000' } })
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
          .fontSize(11).fontColor('#888888')
      }
      if (this.data.msg.editDate) {
        Text('已编辑').fontSize(11).fontColor('#888888')
      }
      Text(formatTime(this.data.msg.date)).fontSize(11).fontColor('#888888')
      if (this.data.msg.outgoing) {
        Text(this.data.msg.failed ? '⚠' : (this.data.msg.pending ? '🕓' : (this.data.read ? '✓✓' : '✓')))
          .fontSize(11).fontColor(this.data.msg.failed ? Color.Red : '#4FAE4E')
      }
    }
    .justifyContent(FlexAlign.End)
    .width('100%')
  }

  @Builder
  Reactions() {
    if (this.data.msg.reactions.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.data.msg.reactions, (r: ReactionItem) => {
          Text(`${r.emoji} ${r.count}`).fontSize(13)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .margin({ right: 4, top: 4 })
            .borderRadius(12)
            .backgroundColor(r.chosen ? ACCENT : '#1A3A8DDE')
            .fontColor(r.chosen ? Color.White : ACCENT)
            .onClick(() => this.actions?.onReact(this.data, r.emoji))
        }, (r: ReactionItem) => `${r.emoji}|${r.count}|${r.chosen}`)
      }
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
                .onClick(() => this.actions?.onButton(this.data, b))
            }, (b: InlineButton, i: number) => `${ri}|${i}|${b.text}`)
          }
          .width('100%')
        }, (row: InlineButton[], ri: number) => `${ri}`)
      }
      .width('100%')
      .margin({ top: 4 })
    }
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
          .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12).backgroundColor('#66556677')
          .constraintSize({ maxWidth: '85%' })
      }
      .width('100%').justifyContent(FlexAlign.Center).padding({ top: 4, bottom: 4 })
    } else {
      Row() {
        Column({ space: 4 }) {
          if (this.data.showSender && !this.data.msg.outgoing) {
            Text(this.data.senderName).fontSize(13).fontColor(ACCENT).fontWeight(FontWeight.Medium)
              .onClick(() => this.actions?.onSender(this.data))
          }
          this.Forwarded()
          this.Reply()
          if (this.data.msg.kind === 'sticker') {
            StickerView({ path: this.data.filePath, format: this.data.msg.stickerFormat,
              thumbPath: this.data.thumbPath, side: 180, autoplay: this.data.autoplay })
              .onClick(() => this.tapOr(() => this.actions?.onOpenMedia(this.data)))
          } else if (this.data.msg.kind === 'videoNote') {
            this.VideoNote()
          } else {
            this.Content()
          }
          this.Buttons()
          this.Reactions()
          this.Footer()
        }
        .alignItems(HorizontalAlign.Start)
        .padding(this.isBare() ? 2 : { left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor(this.isBare() ? Color.Transparent : (this.data.msg.outgoing ? OUT_BG : IN_BG))
        .constraintSize({ maxWidth: '82%' })
        .gesture(LongPressGesture().onAction(() => this.actions?.onMenu(this.data)))
        .onClick(() => {
          this.actions?.onTap(this.data);
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .justifyContent(this.data.msg.outgoing ? FlexAlign.End : FlexAlign.Start)
      .backgroundColor(this.data.selected ? '#333A8DDE' : Color.Transparent)
    }
  }
}
