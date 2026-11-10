import { router, promptAction } from '@kit.ArkUI';
import { Avatar } from '../components/Avatar';
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
@Entry
@Component
struct Contacts {
  @State rows: ContactRow[] = [];
  @State query: string = '';
  @State secretMode: boolean = false;
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
      this.filter();
    }).catch(() => {});
  }

  filter(): void {
    const q = this.query.trim().toLowerCase();
    this.rows = q ? this.all.filter((r: ContactRow) => r.name.toLowerCase().includes(q)) : this.all;
  }

  open(userId: number): void {
    const p = this.secretMode ? this.acc.startSecretChat(userId) : this.acc.privateChatWith(userId);
    p.then((chatId: number) => router.replaceUrl({ url: 'pages/Chat', params: { chatId: chatId } }))
      .catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  findUsername(): void {
    const name = this.query.trim().replace(/^@/, '');
    if (!name) {
      return;
    }
    this.acc.send(o({ '@type': 'searchPublicChat', 'username': name })).then((c: TdObject) => {
      router.replaceUrl({ url: 'pages/Chat', params: { chatId: c['id'] as number } });
    }).catch(() => promptAction.showToast({ message: '找不到该用户名' }));
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => router.back())
        Text(this.secretMode ? '新建私密聊天' : '新建聊天').fontSize(18).fontWeight(FontWeight.Medium).layoutWeight(1)
        Button(this.secretMode ? '普通' : '🔒 私密', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .onClick(() => { this.secretMode = !this.secretMode; })
      }
      .width('100%')
      Search({ value: this.query, placeholder: '搜索联系人或输入 @用户名' })
        .margin({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.query = v;
          this.filter();
        })
        .onSubmit(() => this.findUsername())
      if (this.query.trim().startsWith('@') && !this.secretMode) {
        Text(`查找 ${this.query.trim()}`).fontSize(15).fontColor('#3A8DDE').padding(14).width('100%')
          .onClick(() => this.findUsername())
      }
      List() {
        ForEach(this.rows, (r: ContactRow) => {
          ListItem() {
            Row({ space: 12 }) {
              Avatar({ title: r.name, seed: r.id, path: r.photo, side: 44 })
              Column() {
                Text(r.name).fontSize(16)
                Text(r.status).fontSize(12).fontColor(r.status === '在线' ? '#3A8DDE' : '#888888')
              }
              .alignItems(HorizontalAlign.Start)
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
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
