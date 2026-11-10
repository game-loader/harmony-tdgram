import { router, promptAction } from '@kit.ArkUI';
import { Avatar } from '../components/Avatar';
import { copyText } from '../common/AppState';
import { lastSeen } from '../common/Util';
import { Accounts } from '../td/Accounts';
import { ChatItem } from '../td/Models';
import { o, TdError, TdObject } from '../td/TdClient';

interface ProfileParams {
  userId?: number;
  chatId?: number;
}

// User or group/channel profile with the actions Nicegram exposes: IDs,
// copy username, message, secret chat, block, shared media counts.
@Entry
@Component
struct Profile {
  @State title: string = '';
  @State subtitle: string = '';
  @State photo: string = '';
  @State username: string = '';
  @State phone: string = '';
  @State bio: string = '';
  @State idText: string = '';
  @State members: number = 0;
  @State isUser: boolean = false;
  @State blocked: boolean = false;
  private userId: number = 0;
  private chatId: number = 0;
  private acc = Accounts.get().active();

  aboutToAppear(): void {
    const p = router.getParams() as ProfileParams;
    this.userId = p.userId ?? 0;
    this.chatId = p.chatId ?? 0;
    const chat = this.chatId ? this.acc.chat(this.chatId) : undefined;
    if (chat && chat.userId) {
      this.userId = chat.userId;
    }
    this.isUser = this.userId !== 0;
    if (this.isUser) {
      this.loadUser();
    } else if (chat) {
      this.loadChat(chat);
    }
  }

  private loadUser(): void {
    const u = this.acc.user(this.userId);
    if (u) {
      this.title = u.name();
      this.username = u.username;
      this.phone = this.userId === this.acc.myUserId && Accounts.get().settings.hidePhone ? '' : u.phone;
      this.subtitle = u.isBot ? '机器人' : lastSeen(u.status);
      this.photo = this.acc.files.path(u.photoFileId);
    }
    this.idText = String(this.userId);
    this.acc.send(o({ '@type': 'getUserFullInfo', 'user_id': this.userId })).then((f: TdObject) => {
      const bio = f['bio'] as TdObject | undefined;
      this.bio = bio ? (bio['text'] as string) : '';
      const bl = f['block_list'] as TdObject | undefined;
      this.blocked = bl !== undefined && bl !== null;
    }).catch(() => {});
  }

  private loadChat(c: ChatItem): void {
    this.title = c.title;
    this.photo = c.photoPath || this.acc.files.path(c.photoFileId);
    this.idText = String(c.id);
    this.subtitle = c.type === 'channel' ? '频道' : '群组';
    const req = c.type === 'group' ? o({ '@type': 'getBasicGroupFullInfo', 'basic_group_id': c.groupId }) :
      o({ '@type': 'getSupergroupFullInfo', 'supergroup_id': c.groupId });
    this.acc.send(req).then((f: TdObject) => {
      this.bio = (f['description'] as string) ?? '';
      const members = f['member_count'] as number | undefined;
      const list = f['members'] as TdObject[] | undefined;
      this.members = members ?? (list ? list.length : 0);
      this.subtitle = `${this.subtitle} · ${this.members} 位成员`;
    }).catch(() => {});
    if (c.type === 'supergroup' || c.type === 'channel') {
      this.acc.send(o({ '@type': 'getSupergroup', 'supergroup_id': c.groupId })).then((s: TdObject) => {
        const names = s['usernames'] as TdObject | undefined;
        const active = names ? ((names['active_usernames'] as string[]) ?? []) : [];
        this.username = active.length > 0 ? active[0] : '';
      }).catch(() => {});
    }
  }

  message(): void {
    this.acc.privateChatWith(this.userId).then((id: number) => {
      router.pushUrl({ url: 'pages/Chat', params: { chatId: id } });
    }).catch(() => {});
  }

  secretChat(): void {
    this.acc.startSecretChat(this.userId).then((id: number) => {
      router.pushUrl({ url: 'pages/Chat', params: { chatId: id } });
    }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  toggleBlock(): void {
    const list = this.blocked ? null : o({ '@type': 'blockListMain' });
    const req: TdObject = { '@type': 'setMessageSenderBlockList',
      'sender_id': o({ '@type': 'messageSenderUser', 'user_id': this.userId }) };
    if (list) {
      req['block_list'] = list;
    }
    this.acc.send(req).then(() => {
      this.blocked = !this.blocked;
      promptAction.showToast({ message: this.blocked ? '已屏蔽' : '已取消屏蔽' });
    }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  @Builder
  Field(label: string, value: string) {
    if (value) {
      Column({ space: 2 }) {
        Text(value).fontSize(16).copyOption(CopyOptions.LocalDevice)
        Text(label).fontSize(12).fontColor('#888888')
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .width('100%')
      .onClick(() => copyText(value))
    }
  }

  @Builder
  Action(label: string, color: ResourceColor, fn: () => void) {
    Text(label).fontSize(16).fontColor(color).padding({ left: 16, right: 16, top: 14, bottom: 14 }).width('100%')
      .onClick(fn)
  }

  build() {
    Column() {
      Row() {
        Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => router.back())
      }
      .width('100%')
      Scroll() {
        Column() {
          Avatar({ title: this.title, seed: this.userId || this.chatId, path: this.photo, side: 96 })
          Text(this.title).fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 10 })
          Text(this.subtitle).fontSize(14).fontColor('#888888').margin({ top: 2, bottom: 12 })
          Column() {
            this.Field('用户名', this.username ? '@' + this.username : '')
            this.Field('手机号', this.phone ? '+' + this.phone : '')
            this.Field(this.isUser ? '简介' : '描述', this.bio)
            this.Field('ID（点击复制）', this.idText)
          }
          .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
          .borderRadius(12)
          .margin({ left: 12, right: 12 })
          if (this.isUser && this.userId !== this.acc.myUserId) {
            Column() {
              this.Action('发消息', '#3A8DDE', () => this.message())
              this.Action('开始私密聊天 🔒', '#2E9E45', () => this.secretChat())
              this.Action(this.blocked ? '取消屏蔽' : '屏蔽', '#E84026', () => this.toggleBlock())
            }
            .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
            .borderRadius(12)
            .margin({ left: 12, right: 12, top: 12 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}
