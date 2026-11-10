import { Avatar } from './Avatar';
import { formatTime } from '../common/Util';
import { ChatItem } from '../td/Models';

// Snapshot of a chat list row; `key` changes whenever the row must re-render.
export class ChatRowData {
  chat: ChatItem;
  photo: string;
  pinned: boolean;
  muted: boolean;
  typing: string;
  read: boolean;
  online: boolean;
  key: string;

  constructor(chat: ChatItem, photo: string, pinned: boolean, muted: boolean, typing: string, read: boolean,
    online: boolean) {
    this.chat = chat;
    this.photo = photo;
    this.pinned = pinned;
    this.muted = muted;
    this.typing = typing;
    this.read = read;
    this.online = online;
    this.key = [chat.id, chat.title, chat.lastDate, chat.lastText, chat.unread, chat.unreadMentions, chat.markedUnread,
      chat.draft, pinned, muted, typing, read, online, photo].join('|');
  }
}

@Component
export struct ChatRow {
  @Prop row: ChatRowData;

  build() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Avatar({ title: this.row.chat.title, seed: this.row.chat.id, path: this.row.photo, side: 54 })
        if (this.row.online) {
          Column().width(14).height(14).borderRadius(7).backgroundColor('#4FCE5D')
            .border({ width: 2, color: Color.White })
        }
      }
      Column({ space: 4 }) {
        Row({ space: 4 }) {
          if (this.row.chat.type === 'secret') {
            Text('🔒').fontSize(13)
          } else if (this.row.chat.type === 'channel') {
            Text('📢').fontSize(13)
          } else if (this.row.chat.type === 'group' || this.row.chat.type === 'supergroup') {
            Text('👥').fontSize(13)
          }
          Text(this.row.chat.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.row.chat.type === 'secret' ? '#2E9E45' : $r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.row.muted) {
            Text('🔕').fontSize(12)
          }
          if (this.row.chat.lastOutgoing && this.row.chat.lastMsgId) {
            Text(this.row.read ? '✓✓' : '✓').fontSize(12).fontColor('#4FAE4E')
          }
          Text(formatTime(this.row.chat.lastDate))
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }
        Row({ space: 4 }) {
          if (this.row.typing) {
            Text(this.row.typing).fontSize(14).fontColor('#3A8DDE').maxLines(1).layoutWeight(1)
          } else if (this.row.chat.draft) {
            Text() {
              Span('草稿: ').fontColor('#E84026')
              Span(this.row.chat.draft).fontColor($r('sys.color.ohos_id_color_text_secondary'))
            }
            .fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          } else {
            Text(this.row.chat.lastText)
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          if (this.row.chat.unreadMentions > 0) {
            Text('@').fontSize(12).fontColor(Color.White).width(20).height(20).textAlign(TextAlign.Center)
              .borderRadius(10).backgroundColor('#3A8DDE')
          }
          if (this.row.chat.unread > 0 || this.row.chat.markedUnread) {
            Text(this.row.chat.unread > 999 ? '999+' : (this.row.chat.unread > 0 ? String(this.row.chat.unread) : ''))
              .fontSize(12)
              .fontColor(Color.White)
              .constraintSize({ minWidth: 20 })
              .height(20)
              .textAlign(TextAlign.Center)
              .padding({ left: 6, right: 6 })
              .borderRadius(10)
              .backgroundColor(this.row.muted ? '#A0A8B0' : '#3A8DDE')
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
