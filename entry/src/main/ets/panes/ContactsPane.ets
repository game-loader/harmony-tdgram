import { promptAction } from '@kit.ArkUI';
import { Avatar } from '../components/Avatar';
import { PaneHeader } from '../components/PaneHeader';
import { Nav } from '../common/Nav';
import { lastSeen } from '../common/Util';
import { Accounts } from '../td/Accounts';
import { UserItem } from '../td/Models';
import { o, TdError, TdObject } from '../td/TdClient';

class ContactRow {
  id: number = 0;
  name: string = '';
  status: string = '';
  photo: string = '';
}

// Contact list: start a normal or secret chat, or find a public @username.
@Component
export struct ContactsPane {
  nav: Nav = new Nav();
  @Prop showBack: boolean = true;
  @State rows: ContactRow[] = [];
  @State query: string = '';
  @State secretMode: boolean = false;
  @State loaded: boolean = false;
  private all: ContactRow[] = [];
  private acc = Accounts.get().active();

  aboutToAppear(): void {
    this.acc.send(o({ '@type': 'getContacts' })).then((r: TdObject) => {
      const ids = (r['user_ids'] as number[]) ?? [];
      this.all = ids.map((id: number) => {
        const u: UserItem | undefined = this.acc.user(id);
        const row = new ContactRow();
        row.id = id;
        row.name = u ? u.name() : String(id);
        row.status = u ? lastSeen(u.status) : '';
        row.photo = u ? this.acc.files.path(u.photoFileId) : '';
        return row;
      }).sort((a: ContactRow, b: ContactRow) => a.name.localeCompare(b.name));
      this.loaded = true;
      this.filter();
    }).catch(() => {
      this.loaded = true;
    });
  }

  filter(): void {
    const q = this.query.trim().toLowerCase();
    this.rows = q ? this.all.filter((r: ContactRow) => r.name.toLowerCase().includes(q)) : this.all;
  }

  open(userId: number): void {
    const p = this.secretMode ? this.acc.startSecretChat(userId) : this.acc.privateChatWith(userId);
    p.then((chatId: number) => this.nav.replaceWithChat(chatId))
      .catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  findUsername(): void {
    const name = this.query.trim().replace(/^@/, '');
    if (!name) {
      return;
    }
    this.acc.send(o({ '@type': 'searchPublicChat', 'username': name })).then((c: TdObject) => {
      this.nav.replaceWithChat(c['id'] as number);
    }).catch(() => promptAction.showToast({ message: '找不到该用户名' }));
  }

  build() {
    Column() {
      PaneHeader({ title: this.secretMode ? '新建私密聊天' : '新建聊天', showBack: this.showBack,
        onBack: (): void => { this.nav.pop(); } })
      Row() {
        Text('🔒 私密聊天（端到端加密）').fontSize(15).layoutWeight(1).fontColor($r('app.color.text_primary'))
        Toggle({ type: ToggleType.Switch, isOn: this.secretMode }).onChange((v: boolean) => { this.secretMode = v; })
      }
      .padding({ left: 16, right: 12, bottom: 6 })
      .width('100%')
      Search({ value: this.query, placeholder: '搜索联系人或输入 @用户名' })
        .margin({ left: 12, right: 12, bottom: 4 })
        .onChange((v: string) => {
          this.query = v;
          this.filter();
        })
        .onSubmit(() => this.findUsername())
      if (this.query.trim().startsWith('@') && !this.secretMode) {
        Text(`查找 ${this.query.trim()}`).fontSize(15).fontColor($r('app.color.accent')).padding(14).width('100%')
          .onClick(() => this.findUsername())
      }
      if (this.loaded && this.all.length === 0) {
        Text('还没有联系人。输入 @用户名 可以查找用户、群组或频道。').fontSize(14)
          .fontColor($r('app.color.text_secondary')).padding(24).textAlign(TextAlign.Center)
      }
      List() {
        ForEach(this.rows, (r: ContactRow) => {
          ListItem() {
            Row({ space: 12 }) {
              Avatar({ title: r.name, seed: r.id, path: r.photo, side: 44 })
              Column() {
                Text(r.name).fontSize(16).fontColor($r('app.color.text_primary')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(r.status).fontSize(12)
                  .fontColor(r.status === '在线' ? $r('app.color.accent') : $r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .width('100%')
            .onClick(() => this.open(r.id))
          }
        }, (r: ContactRow) => `${r.id}`)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
