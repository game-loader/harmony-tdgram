import { promptAction } from '@kit.ArkUI';
import { ChatRow, ChatRowData } from '../components/ChatRow';
import { PaneHeader } from '../components/PaneHeader';
import { AppState } from '../common/AppState';
import { Nav } from '../common/Nav';
import { Accounts } from '../td/Accounts';
import { ChatItem } from '../td/Models';
import { TdError } from '../td/TdClient';

// Picks the destination chat for AppState.forward, then opens that chat.
@Component
export struct ForwardPane {
  nav: Nav = new Nav();
  @Prop showBack: boolean = true;
  @State rows: ChatRowData[] = [];
  @State query: string = '';
  private acc = Accounts.get().active();
  private busy: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  refresh(): void {
    const q = this.query.trim().toLowerCase();
    this.rows = this.acc.chats.sorted(0)
      .filter((c: ChatItem) => c.canSend && (!q || c.title.toLowerCase().includes(q)))
      .map((c: ChatItem) => new ChatRowData(c, 'forward').apply(c.photoPath || this.acc.files.known(c.photoFileId),
        false, this.acc.chats.isMuted(c), '', true, false, this.acc.chats.isForum(c)));
  }

  send(chatId: number): void {
    const req = AppState.forward;
    if (!req) {
      this.nav.pop();
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.acc.actions.forward(chatId, req.fromChatId, req.ids, req.asCopy).then(() => {
      AppState.forward = null;
      promptAction.showToast({ message: '已转发' });
      this.nav.replaceWithChat(chatId);
    }).catch((e: TdError) => {
      this.busy = false;
      promptAction.showToast({ message: `转发失败：${e.message}` });
    });
  }

  build() {
    Column() {
      PaneHeader({ title: '转发到…', showBack: this.showBack, onBack: (): void => { this.nav.pop(); } })
      Search({ value: this.query, placeholder: '搜索' })
        .margin({ left: 12, right: 12, bottom: 4 })
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
      .divider({ strokeWidth: 0.5, color: $r('app.color.separator'), startMargin: 80 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
