import { router, promptAction } from '@kit.ArkUI';
import { ChatRow, ChatRowData } from '../components/ChatRow';
import { AppState } from '../common/AppState';
import { Accounts } from '../td/Accounts';
import { ChatItem } from '../td/Models';
import { TdError } from '../td/TdClient';

// Picks the destination chat for AppState.forward.
@Entry
@Component
struct Forward {
  @State rows: ChatRowData[] = [];
  @State query: string = '';
  private acc = Accounts.get().active();

  aboutToAppear(): void {
    this.refresh();
  }

  refresh(): void {
    const q = this.query.trim().toLowerCase();
    this.rows = this.acc.chats.sorted(0)
      .filter((c: ChatItem) => c.canSend && (!q || c.title.toLowerCase().includes(q)))
      .map((c: ChatItem) => new ChatRowData(c, c.photoPath || this.acc.files.known(c.photoFileId), false,
        this.acc.chats.isMuted(c), '', true, false));
  }

  send(chatId: number): void {
    const req = AppState.forward;
    if (!req) {
      router.back();
      return;
    }
    AppState.forward = null;
    this.acc.messages.forward(chatId, req.fromChatId, req.ids, req.asCopy).then(() => {
      promptAction.showToast({ message: '已转发' });
      router.back();
    }).catch((e: TdError) => {
      promptAction.showToast({ message: `转发失败：${e.message}` });
      router.back();
    });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => router.back())
        Text('转发到…').fontSize(18).fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      Search({ value: this.query, placeholder: '搜索' })
        .margin({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.query = v;
          this.refresh();
        })
      List() {
        ForEach(this.rows, (r: ChatRowData) => {
          ListItem() {
            ChatRow({ row: r }).onClick(() => this.send(r.chat.id))
          }
        }, (r: ChatRowData) => r.key)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
