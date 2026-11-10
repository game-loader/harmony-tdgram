import { formatSize, formatTime } from '../common/Util';
import { MsgItem } from '../td/Models';

// Snapshot of what a bubble renders. The page rebuilds it whenever the
// message, its reply preview or a downloaded file changes.
export class BubbleData {
  msg: MsgItem;
  senderName: string;
  showSender: boolean;
  photoPath: string;
  docPath: string;
  replyName: string;
  replyText: string;
  key: string;

  constructor(msg: MsgItem, senderName: string, showSender: boolean, photoPath: string, docPath: string,
    replyName: string, replyText: string) {
    this.msg = msg;
    this.senderName = senderName;
    this.showSender = showSender;
    this.photoPath = photoPath;
    this.docPath = docPath;
    this.replyName = replyName;
    this.replyText = replyText;
    this.key = `${msg.id}|${msg.version}|${photoPath}|${docPath}|${replyText}|${showSender}`;
  }
}

const OUT_BG = '#D9F2C6';
const IN_BG = '#FFFFFF';
const MAX_PHOTO_W = 240;

@Component
export struct MessageBubble {
  @Prop data: BubbleData;
  onReply: (msg: MsgItem) => void = () => {};
  onJump: (id: number) => void = () => {};
  onOpenPhoto: (path: string) => void = () => {};
  onOpenDoc: (data: BubbleData) => void = () => {};

  photoHeight(): number {
    const m = this.data.msg;
    if (!m.photoW || !m.photoH) {
      return MAX_PHOTO_W;
    }
    return Math.min(MAX_PHOTO_W * m.photoH / m.photoW, 360);
  }

  build() {
    Row() {
      Column({ space: 4 }) {
        if (this.data.showSender && !this.data.msg.outgoing) {
          Text(this.data.senderName).fontSize(13).fontColor('#3A8DDE').fontWeight(FontWeight.Medium)
        }
        if (this.data.msg.replyToId) {
          Column() {
            Text(this.data.replyName || '回复').fontSize(12).fontColor('#3A8DDE').maxLines(1)
            Text(this.data.replyText || '…').fontSize(12).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor('#555555')
          }
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 8, top: 2, bottom: 2 })
          .border({ width: { left: 2 }, color: { left: '#3A8DDE' } })
          .onClick(() => this.onJump(this.data.msg.replyToId))
        }
        if (this.data.msg.photoFileId) {
          if (this.data.photoPath) {
            Image('file://' + this.data.photoPath)
              .width(MAX_PHOTO_W)
              .height(this.photoHeight())
              .objectFit(ImageFit.Cover)
              .borderRadius(8)
              .onClick(() => this.onOpenPhoto(this.data.photoPath))
          } else {
            Stack() {
              LoadingProgress().width(32).height(32)
            }
            .width(MAX_PHOTO_W)
            .height(this.photoHeight())
            .borderRadius(8)
            .backgroundColor('#22000000')
          }
        }
        if (this.data.msg.docFileId) {
          Row({ space: 10 }) {
            Text(this.data.docPath ? '📄' : '⬇').fontSize(28)
            Column() {
              Text(this.data.msg.docName).fontSize(14).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(formatSize(this.data.msg.docSize)).fontSize(12).fontColor('#777777')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width(MAX_PHOTO_W)
          .onClick(() => this.onOpenDoc(this.data))
        }
        if (this.data.msg.text) {
          Text(this.data.msg.text).fontSize(16).fontColor('#000000').copyOption(CopyOptions.LocalDevice)
        }
        Row({ space: 4 }) {
          Text(formatTime(this.data.msg.date)).fontSize(11).fontColor('#888888')
          if (this.data.msg.outgoing) {
            Text(this.data.msg.failed ? '⚠' : (this.data.msg.pending ? '🕓' : '✓')).fontSize(11)
              .fontColor(this.data.msg.failed ? Color.Red : '#4FAE4E')
          }
        }
        .justifyContent(FlexAlign.End)
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(12)
      .backgroundColor(this.data.msg.outgoing ? OUT_BG : IN_BG)
      .constraintSize({ maxWidth: '80%' })
      .gesture(LongPressGesture().onAction(() => this.onReply(this.data.msg)))
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .justifyContent(this.data.msg.outgoing ? FlexAlign.End : FlexAlign.Start)
  }
}
