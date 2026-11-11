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

@Component
export struct ChatRow {
  @ObjectLink row: ChatRowData;

  build() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Avatar({ title: this.row.title, seed: this.row.id, path: this.row.photo, side: 54 })
        if (this.row.online) {
          Column().width(14).height(14).borderRadius(7).backgroundColor('#4FCE5D')
            .border({ width: 2, color: $r('app.color.page_bg') })
        }
      }
      Column({ space: 4 }) {
        Row({ space: 4 }) {
          if (this.row.type === 'secret') {
            Text('🔒').fontSize(13)
          } else if (this.row.type === 'channel') {
            Text('📢').fontSize(13)
          } else if (this.row.forum) {
            Text('💬').fontSize(13)
          } else if (this.row.type === 'group' || this.row.type === 'supergroup') {
            Text('👥').fontSize(13)
          }
          Text(this.row.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.row.type === 'secret' ? $r('app.color.secret') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.row.muted) {
            Text('🔕').fontSize(12)
          }
          if (this.row.lastOutgoing) {
            Text(this.row.read ? '✓✓' : '✓').fontSize(12).fontColor($r('app.color.tick'))
          }
          Text(formatTime(this.row.lastDate))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        Row({ space: 4 }) {
          if (this.row.typing) {
            Text(this.row.typing).fontSize(14).fontColor($r('app.color.accent')).maxLines(1).layoutWeight(1)
          } else if (this.row.draft) {
            Text() {
              Span('草稿: ').fontColor($r('app.color.danger'))
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
            Text('@').fontSize(12).fontColor(Color.White).width(20).height(20).textAlign(TextAlign.Center)
              .borderRadius(10).backgroundColor($r('app.color.accent'))
          }
          if (this.row.unread > 0 || this.row.markedUnread) {
            Text(this.row.unread > 999 ? '999+' : (this.row.unread > 0 ? String(this.row.unread) : ''))
              .fontSize(12)
              .fontColor(Color.White)
              .constraintSize({ minWidth: 20 })
              .height(20)
              .textAlign(TextAlign.Center)
              .padding({ left: 6, right: 6 })
              .borderRadius(10)
              .backgroundColor(this.row.muted ? '#A0A8B0' : $r('app.color.accent'))
          } else if (this.row.pinned) {
            Text('📌').fontSize(12)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
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

  build() {
    Row() {
      Text(this.row.unread > 0 || this.row.markedUnread ? '已读' : '未读').fontSize(14).fontColor(Color.White)
        .width(64).height('100%').textAlign(TextAlign.Center).backgroundColor('#4A9BEA')
        .onClick(() => this.onRead(this.row))
      Text(this.row.pinned ? '取消置顶' : '置顶').fontSize(14).fontColor(Color.White)
        .width(64).height('100%').textAlign(TextAlign.Center).backgroundColor('#F0A030')
        .onClick(() => this.onPin(this.row))
      Text(this.archived ? '移出归档' : '归档').fontSize(14).fontColor(Color.White)
        .width(64).height('100%').textAlign(TextAlign.Center).backgroundColor('#8E99A4')
        .onClick(() => this.onArchive(this.row))
    }
    .height('100%')
  }
}
