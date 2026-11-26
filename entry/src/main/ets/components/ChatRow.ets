import { Avatar } from './Avatar';
import { formatTime } from '../common/Util';
import { ChatItem, ChatType } from '../td/Models';

// What a chat list row shows. One object lives as long as its row: the list
// is keyed by `key`, which never changes, and updates arrive as property
// changes. That way a new message only redraws the texts that differ; the
// row, and with it the avatar image, is not built again.
@Observed
export class ChatRowData {
  chat: ChatItem; // for actions only; what is drawn comes from the fields below
  key: string;
  id: number;
  title: string = '';
  type: ChatType = 'private';
  lastText: string = '';
  lastDate: number = 0;
  lastOutgoing: boolean = false;
  unread: number = 0;
  unreadMentions: number = 0;
  markedUnread: boolean = false;
  draft: string = '';
  photo: string = '';
  pinned: boolean = false;
  muted: boolean = false;
  typing: string = '';
  read: boolean = false;
  online: boolean = false;
  forum: boolean = false;

  constructor(chat: ChatItem, scope: string) {
    this.chat = chat;
    this.id = chat.id;
    this.key = `${scope}:${chat.id}`;
  }

  // Takes over the current state; only values that differ are written, so
  // only what depends on them is redrawn.
  apply(photo: string, pinned: boolean, muted: boolean, typing: string, read: boolean, online: boolean,
    forum: boolean): ChatRowData {
    const c = this.chat;
    if (this.title !== c.title) { this.title = c.title; }
    if (this.type !== c.type) { this.type = c.type; }
    if (this.lastText !== c.lastText) { this.lastText = c.lastText; }
    if (this.lastDate !== c.lastDate) { this.lastDate = c.lastDate; }
    const outgoing = c.lastOutgoing && c.lastMsgId !== 0;
    if (this.lastOutgoing !== outgoing) { this.lastOutgoing = outgoing; }
    if (this.unread !== c.unread) { this.unread = c.unread; }
    if (this.unreadMentions !== c.unreadMentions) { this.unreadMentions = c.unreadMentions; }
    if (this.markedUnread !== c.markedUnread) { this.markedUnread = c.markedUnread; }
    if (this.draft !== c.draft) { this.draft = c.draft; }
    if (this.photo !== photo) { this.photo = photo; }
    if (this.pinned !== pinned) { this.pinned = pinned; }
    if (this.muted !== muted) { this.muted = muted; }
    if (this.typing !== typing) { this.typing = typing; }
    if (this.read !== read) { this.read = read; }
    if (this.online !== online) { this.online = online; }
    if (this.forum !== forum) { this.forum = forum; }
    return this;
  }
}

// Read receipt drawn as one or two round-capped check strokes.
@Component
export struct Ticks {
  @Prop double: boolean = false;
  @Prop tint: ResourceColor = $r('app.color.tick');

  build() {
    Stack() {
      Polyline().width(16).height(10).points([[1, 5], [4.5, 8.5], [11, 1.5]])
        .stroke(this.tint).strokeWidth(1.6).strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round).fillOpacity(0)
      if (this.double) {
        Polyline().width(16).height(10).points([[8, 8.5], [15, 1.5]])
          .stroke(this.tint).strokeWidth(1.6).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
      }
    }
    .width(16)
    .height(10)
  }
}

@Component
export struct ChatRow {
  @ObjectLink row: ChatRowData;

  private typeGlyph(): Resource | undefined {
    if (this.row.type === 'secret') {
      return $r('sys.symbol.lock_fill');
    } else if (this.row.type === 'channel') {
      return $r('sys.symbol.speaker_wave_2_fill');
    } else if (this.row.forum) {
      return $r('sys.symbol.message_on_message_fill');
    } else if (this.row.type === 'group' || this.row.type === 'supergroup') {
      return $r('sys.symbol.person_2_fill');
    }
    return undefined;
  }

  private unreadShown(): boolean {
    return this.row.unread > 0 || this.row.markedUnread;
  }

  build() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Avatar({ title: this.row.title, seed: this.row.id, path: this.row.photo, side: 56 })
        if (this.row.online) {
          Column().width(15).height(15).borderRadius(7.5).backgroundColor('#2FC26B')
            .border({ width: 2.5, color: $r('app.color.page_bg') })
        }
      }
      Column({ space: 5 }) {
        Row({ space: 4 }) {
          if (this.typeGlyph() !== undefined) {
            SymbolGlyph(this.typeGlyph()).fontSize(14)
              .fontColor([this.row.type === 'secret' ? $r('app.color.secret') : $r('app.color.text_secondary')])
          }
          Text(this.row.title)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.row.type === 'secret' ? $r('app.color.secret') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          if (this.row.muted) {
            SymbolGlyph($r('sys.symbol.speaker_slash_fill')).fontSize(13).fontColor([$r('app.color.text_secondary')])
          }
          Blank()
          if (this.row.lastOutgoing) {
            Ticks({ double: this.row.read })
          }
          Text(formatTime(this.row.lastDate))
            .fontSize(13)
            .fontColor(this.unreadShown() && !this.row.muted ? $r('app.color.accent') : $r('app.color.text_secondary'))
        }
        .width('100%')
        Row({ space: 6 }) {
          if (this.row.typing) {
            Text(this.row.typing).fontSize(14).fontColor($r('app.color.accent')).maxLines(1).layoutWeight(1)
          } else if (this.row.draft) {
            Text() {
              Span('草稿 ').fontColor($r('app.color.danger')).fontWeight(FontWeight.Medium)
              Span(this.row.draft).fontColor($r('app.color.text_secondary'))
            }
            .fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          } else {
            Text(this.row.lastText)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          if (this.row.unreadMentions > 0) {
            Stack() {
              SymbolGlyph($r('sys.symbol.at')).fontSize(13).fontColor([Color.White])
            }
            .width(22).height(22).borderRadius(11)
            .linearGradient({ angle: 135, colors: [[$r('app.color.accent'), 0], [$r('app.color.accent_end'), 1]] })
          }
          if (this.unreadShown()) {
            Text(this.row.unread > 999 ? '999+' : (this.row.unread > 0 ? String(this.row.unread) : ''))
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .constraintSize({ minWidth: 22 })
              .height(22)
              .textAlign(TextAlign.Center)
              .padding({ left: 7, right: 7 })
              .borderRadius(11)
              .backgroundColor(this.row.muted ? '#9AA5B3' : $r('app.color.accent'))
          } else if (this.row.pinned) {
            SymbolGlyph($r('sys.symbol.pin_fill')).fontSize(15).fontColor([$r('app.color.text_secondary')])
              .rotate({ angle: 45 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .width('100%')
  }
}

// The buttons revealed by swiping a chat row to the left. A component of
// its own so the labels follow the row while it stays in the list.
@Component
export struct ChatRowActions {
  @ObjectLink row: ChatRowData;
  @Prop archived: boolean = false; // the list shown is the archive
  onRead: (row: ChatRowData) => void = (): void => {};
  onPin: (row: ChatRowData) => void = (): void => {};
  onArchive: (row: ChatRowData) => void = (): void => {};
  onDelete: (row: ChatRowData) => void = (): void => {};

  @Builder
  Action(glyph: Resource, label: string, tint: string, fn: () => void) {
    Column({ space: 5 }) {
      SymbolGlyph(glyph).fontSize(22).fontColor([Color.White])
      Text(label).fontSize(12).fontWeight(FontWeight.Medium).fontColor(Color.White).maxLines(1)
    }
    .width(68)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(tint)
    .onClick(fn)
  }

  build() {
    Row() {
      if (this.row.unread > 0 || this.row.markedUnread) {
        this.Action($r('sys.symbol.envelope_open_fill'), '已读', '#3F7FE6', () => this.onRead(this.row))
      } else {
        this.Action($r('sys.symbol.envelope_open_fill'), '未读', '#3F7FE6', () => this.onRead(this.row))
      }
      // Separate branches, so the label follows the row (builder arguments are not observed).
      if (this.row.pinned) {
        this.Action($r('sys.symbol.pin_slash'), '取消置顶', '#F09A2E', () => this.onPin(this.row))
      } else {
        this.Action($r('sys.symbol.pin_fill'), '置顶', '#F09A2E', () => this.onPin(this.row))
      }
      this.Action($r('sys.symbol.archivebox_fill'), this.archived ? '移出归档' : '归档', '#7D8A99',
        () => this.onArchive(this.row))
      this.Action($r('sys.symbol.trash_fill'),
        this.row.chat.type === 'private' || this.row.chat.type === 'secret' ? '删除' : '退出', '#E5484D',
        () => this.onDelete(this.row))
    }
    .height('100%')
  }
}
