import { router, promptAction } from '@kit.ArkUI';
import { Avatar } from '../components/Avatar';
import { formatTime } from '../common/Util';
import { ChatItem } from '../td/Models';
import { Store, StoreEvent } from '../td/Store';

// Row snapshot: ForEach needs a key that changes whenever the row changes.
class ChatRow {
  chat: ChatItem;
  key: string;
  photo: string;

  constructor(chat: ChatItem, photo: string) {
    this.chat = chat;
    this.photo = photo;
    this.key = `${chat.id}|${chat.title}|${chat.lastDate}|${chat.lastText}|${chat.unread}|${chat.isPinned}|${photo}`;
  }
}

@Entry
@Component
struct ChatList {
  @State rows: ChatRow[] = [];
  private store: Store = Store.get();
  private listener = (e: StoreEvent): void => this.onStore(e);
  private refreshScheduled: boolean = false;

  aboutToAppear(): void {
    this.store.on(this.listener);
    this.refresh();
  }

  aboutToDisappear(): void {
    this.store.off(this.listener);
  }

  onPageShow(): void {
    this.refresh();
  }

  onStore(e: StoreEvent): void {
    if (e === 'auth' && this.store.authStep !== 'ready') {
      router.replaceUrl({ url: 'pages/Login' });
      return;
    }
    if (e === 'chats' || e === 'files') {
      // Startup delivers hundreds of chat updates; rebuild once per frame.
      if (!this.refreshScheduled) {
        this.refreshScheduled = true;
        setTimeout(() => {
          this.refreshScheduled = false;
          this.refresh();
        }, 16);
      }
    }
  }

  refresh(): void {
    this.rows = this.store.sortedChats().map((c: ChatItem) =>
      new ChatRow(c, c.photoPath || this.store.filePath(c.photoFileId)));
  }

  @Builder
  Row(row: ChatRow) {
    Row({ space: 12 }) {
      Avatar({ title: row.chat.title, seed: row.chat.id, path: row.photo })
      Column({ space: 4 }) {
        Row() {
          Text(row.chat.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(formatTime(row.chat.lastDate))
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }
        Row() {
          Text(row.chat.lastText)
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (row.chat.unread > 0) {
            Text(row.chat.unread > 999 ? '999+' : String(row.chat.unread))
              .fontSize(12)
              .fontColor(Color.White)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(10)
              .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          } else if (row.chat.isPinned) {
            Text('📌').fontSize(12)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .width('100%')
    .onClick(() => {
      router.pushUrl({ url: 'pages/Chat', params: { chatId: row.chat.id } });
    })
  }

  build() {
    Column() {
      Row() {
        Text('TdGram').fontSize(24).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('退出', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .onClick(() => {
            promptAction.showDialog({
              title: '退出登录？',
              buttons: [{ text: '取消', color: '#888888' }, { text: '退出', color: '#E84026' }]
            }).then((r: promptAction.ShowDialogSuccessResponse) => {
              if (r.index === 1) {
                this.store.logOut();
              }
            });
          })
      }
      .padding({ left: 16, right: 8, top: 12, bottom: 8 })
      .width('100%')

      List() {
        ForEach(this.rows, (row: ChatRow) => {
          ListItem() {
            this.Row(row)
          }
        }, (row: ChatRow) => row.key)
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: $r('sys.color.ohos_id_color_list_separator'), startMargin: 80 })
      .onReachEnd(() => this.store.loadMoreChats())
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
