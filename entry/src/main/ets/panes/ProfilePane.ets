import { router, promptAction } from '@kit.ArkUI';
import { Avatar } from '../components/Avatar';
import { PaneHeader } from '../components/PaneHeader';
import { AppState, copyText, ViewerItem } from '../common/AppState';
import { columnsFor, contentWidth } from '../common/Layout';
import { Nav, Route } from '../common/Nav';
import { formatSize, formatTime, lastSeen, minithumbUri } from '../common/Util';
import { Accounts } from '../td/Accounts';
import { AccountEvent } from '../td/Core';
import { ChatItem, MsgItem } from '../td/Models';
import { formatDuration, summary } from '../td/Parse';
import { SearchPage } from '../td/MessageStore';
import { o, TdError, TdObject } from '../td/TdClient';

interface FieldP {
  label: string;
  value: string;
}

interface ActionP {
  label: string;
  color: ResourceColor;
  fn: () => void;
}

class MemberRow {
  userId: number = 0;
  name: string = '';
  status: string = '';
  role: string = '';
  photo: string = '';
}

// A square of the shared-media grid.
class MediaCell {
  id: number = 0;
  thumb: string = '';
  mini: string = '';
  video: boolean = false;
  duration: number = 0;
}

class SharedTab {
  name: string = '';
  filter: string = ''; // searchMessagesFilter* type, '' for the member list

  constructor(name: string, filter: string) {
    this.name = name;
    this.filter = filter;
  }
}

const MUTE_FOREVER = 0x7FFFFFFF;

function chunk<T>(list: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < list.length; i += size) {
    out.push(list.slice(i, i + size));
  }
  return out;
}

// User or group/channel profile: IDs, username, actions, members, and the
// media, files, links and voice messages shared in the chat.
@Component
export struct ProfilePane {
  nav: Nav = new Nav();
  route: Route = new Route();
  @Prop showBack: boolean = true;
  @State title: string = '';
  @State subtitle: string = '';
  @State photo: string = '';
  @State username: string = '';
  @State phone: string = '';
  @State bio: string = '';
  @State idText: string = '';
  @State isUser: boolean = false;
  @State blocked: boolean = false;
  @State muted: boolean = false;
  @State tabs: SharedTab[] = [];
  @State tab: number = 0;
  @State members: MemberRow[] = [];
  @State cells: MediaCell[] = [];
  @State rows: MsgItem[] = [];
  @State loading: boolean = false;
  @State paneW: number = 360;
  private userId: number = 0;
  private chatId: number = 0; // chat whose shared content is listed, 0 while unknown
  private items: MsgItem[] = [];
  private next: string = '';
  private loadSeq: number = 0;
  private acc = Accounts.get().active();
  private listener = (e: AccountEvent): void => {
    if (e === 'files') {
      this.refreshFiles();
    } else if (e === 'chats') {
      this.refreshMuted();
    }
  };

  aboutToAppear(): void {
    this.userId = this.route.userId;
    this.chatId = this.route.chatId;
    const chat = this.chatId ? this.acc.chat(this.chatId) : undefined;
    if (chat && chat.userId) {
      this.userId = chat.userId;
    }
    this.isUser = this.userId !== 0;
    this.acc.on(this.listener);
    const shared = [new SharedTab('媒体', 'searchMessagesFilterPhotoAndVideo'),
      new SharedTab('文件', 'searchMessagesFilterDocument'), new SharedTab('链接', 'searchMessagesFilterUrl'),
      new SharedTab('语音', 'searchMessagesFilterVoiceNote')];
    if (this.isUser) {
      this.tabs = shared;
      this.loadUser();
      if (this.chatId) {
        this.selectTab(0);
      } else {
        // Shared content lives in the private chat with this user.
        this.acc.privateChatWith(this.userId).then((id: number) => {
          this.chatId = id;
          this.selectTab(0);
        }).catch(() => {});
      }
    } else if (chat) {
      this.tabs = [new SharedTab('成员', '')].concat(shared);
      this.loadChat(chat);
      this.selectTab(0);
    }
    this.refreshMuted();
  }

  aboutToDisappear(): void {
    this.acc.off(this.listener);
  }

  private refreshMuted(): void {
    const c = this.chatId ? this.acc.chat(this.chatId) : undefined;
    this.muted = c ? this.acc.chats.isMuted(c) : false;
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
    const kind = c.type === 'channel' ? '频道' : '群组';
    this.subtitle = kind;
    const req = c.type === 'group' ? o({ '@type': 'getBasicGroupFullInfo', 'basic_group_id': c.groupId }) :
      o({ '@type': 'getSupergroupFullInfo', 'supergroup_id': c.groupId });
    this.acc.send(req).then((f: TdObject) => {
      this.bio = (f['description'] as string) ?? '';
      const list = f['members'] as TdObject[] | undefined;
      const count = (f['member_count'] as number | undefined) ?? (list ? list.length : 0);
      this.subtitle = count ? `${kind} · ${count} 位${c.type === 'channel' ? '订阅者' : '成员'}` : kind;
      if (list) {
        this.members = list.map((m: TdObject) => this.member(m)).filter((m: MemberRow) => m.userId !== 0);
      }
    }).catch(() => {});
    if (c.type === 'supergroup' || c.type === 'channel') {
      this.acc.send(o({ '@type': 'getSupergroup', 'supergroup_id': c.groupId })).then((s: TdObject) => {
        const names = s['usernames'] as TdObject | undefined;
        const active = names ? ((names['active_usernames'] as string[]) ?? []) : [];
        this.username = active.length > 0 ? active[0] : '';
      }).catch(() => {});
      // Fails for channels and groups that hide their members; the tab then stays empty.
      this.acc.send(o({ '@type': 'getSupergroupMembers', 'supergroup_id': c.groupId,
        'filter': o({ '@type': 'supergroupMembersFilterRecent' }), 'offset': 0, 'limit': 200 }))
        .then((r: TdObject) => {
          this.members = ((r['members'] as TdObject[]) ?? []).map((m: TdObject) => this.member(m))
            .filter((m: MemberRow) => m.userId !== 0);
        }).catch(() => {});
    }
  }

  private member(m: TdObject): MemberRow {
    const row = new MemberRow();
    const sender = m['member_id'] as TdObject;
    if (sender['@type'] !== 'messageSenderUser') {
      return row;
    }
    row.userId = sender['user_id'] as number;
    const u = this.acc.user(row.userId);
    row.name = u ? u.name() : String(row.userId);
    row.status = u ? (u.isBot ? '机器人' : lastSeen(u.status)) : '';
    row.photo = u ? this.acc.files.path(u.photoFileId) : '';
    const st = (m['status'] as TdObject)['@type'] as string;
    row.role = st === 'chatMemberStatusCreator' ? '群主' : (st === 'chatMemberStatusAdministrator' ? '管理员' : '');
    return row;
  }

  // ---- Shared content ----

  selectTab(i: number): void {
    this.tab = i;
    this.items = [];
    this.rows = [];
    this.cells = [];
    this.next = '';
    this.loadSeq++;
    this.loading = false;
    this.loadShared(true);
  }

  private loadShared(first: boolean): void {
    const filter = this.tabs[this.tab] ? this.tabs[this.tab].filter : '';
    if (!filter || !this.chatId || this.loading || (!first && !this.next)) {
      return;
    }
    const seq = this.loadSeq;
    this.loading = true;
    this.acc.store(this.chatId).search('', filter, this.next).then((p: SearchPage) => {
      if (seq !== this.loadSeq) {
        return;
      }
      this.loading = false;
      this.next = p.next;
      const known = new Set<number>(this.items.map((m: MsgItem) => m.id));
      this.items = this.items.concat(p.items.filter((m: MsgItem) => !known.has(m.id)));
      this.refreshFiles();
    }).catch(() => {
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    });
  }

  private isMediaTab(): boolean {
    return this.tabs[this.tab] !== undefined && this.tabs[this.tab].filter === 'searchMessagesFilterPhotoAndVideo';
  }

  private refreshFiles(): void {
    if (!this.isMediaTab()) {
      this.rows = this.items.slice();
      return;
    }
    const files = this.acc.files;
    this.cells = this.items.map((m: MsgItem) => {
      const c = new MediaCell();
      c.id = m.id;
      c.video = m.kind === 'video';
      c.duration = m.duration;
      c.mini = m.minithumb;
      c.thumb = m.thumbIsVideo ? '' : (m.thumbPath || files.path(m.thumbFileId, 4));
      if (!c.thumb && m.kind === 'photo' && !m.thumbFileId) {
        c.thumb = m.filePath || files.path(m.fileId, 4);
      }
      return c;
    });
  }

  private openMedia(id: number): void {
    const visual = this.items.filter((m: MsgItem) => m.kind === 'photo' || m.kind === 'video');
    AppState.viewer = visual.map((m: MsgItem) => {
      const v = new ViewerItem();
      v.kind = m.kind;
      v.path = this.acc.files.known(m.fileId, m.filePath);
      v.caption = m.text;
      v.fileId = m.fileId;
      v.size = m.fileSize;
      v.mime = m.mime;
      v.name = m.fileName || `${m.id}.${m.kind === 'photo' ? 'jpg' : 'mp4'}`;
      return v;
    });
    AppState.viewerIndex = Math.max(0, visual.findIndex((m: MsgItem) => m.id === id));
    router.pushUrl({ url: 'pages/MediaViewer' });
  }

  private rowTitle(m: MsgItem): string {
    if (m.kind === 'document' || m.kind === 'audio') {
      return m.fileName || m.title || '文件';
    }
    if (m.kind === 'voice') {
      return `${m.outgoing ? '我' : this.acc.chats.nameOf(m.senderId, m.senderIsChat)} · ${formatDuration(m.duration)}`;
    }
    return m.linkTitle || m.linkSite || summary(m);
  }

  private rowDetail(m: MsgItem): string {
    if (m.kind === 'document' || m.kind === 'audio') {
      return formatSize(m.fileSize);
    }
    if (m.kind === 'voice') {
      return m.recognized;
    }
    return m.linkUrl || m.text;
  }

  // ---- Actions ----

  message(): void {
    this.acc.privateChatWith(this.userId).then((id: number) => {
      this.nav.openChat(id);
    }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  secretChat(): void {
    this.acc.startSecretChat(this.userId).then((id: number) => {
      this.nav.openChat(id);
    }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  toggleMute(): void {
    const c = this.chatId ? this.acc.chat(this.chatId) : undefined;
    if (c) {
      this.acc.mute(c, this.muted ? 0 : MUTE_FOREVER).catch((e: TdError) => promptAction.showToast({ message: e.message }));
    }
  }

  toggleBlock(): void {
    const req: TdObject = { '@type': 'setMessageSenderBlockList',
      'sender_id': o({ '@type': 'messageSenderUser', 'user_id': this.userId }) };
    if (!this.blocked) {
      req['block_list'] = o({ '@type': 'blockListMain' });
    }
    this.acc.send(req).then(() => {
      this.blocked = !this.blocked;
      promptAction.showToast({ message: this.blocked ? '已屏蔽' : '已取消屏蔽' });
    }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  @Builder
  Field(p: FieldP) {
    if (p.value) {
      Column({ space: 2 }) {
        Text(p.value).fontSize(16).fontColor($r('app.color.text_primary'))
        Text(p.label).fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .width('100%')
      .onClick(() => copyText(p.value))
    }
  }

  @Builder
  Action(p: ActionP) {
    Text(p.label).fontSize(16).fontColor(p.color).padding({ left: 16, right: 16, top: 14, bottom: 14 }).width('100%')
      .onClick(() => p.fn())
  }

  @Builder
  Head() {
    Column() {
      Avatar({ title: this.title, seed: this.userId || this.chatId, path: this.photo, side: 96 })
      Text(this.title).fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 10 }).textAlign(TextAlign.Center)
        .fontColor($r('app.color.text_primary'))
      Text(this.subtitle).fontSize(14).fontColor($r('app.color.text_secondary')).margin({ top: 2, bottom: 12 })
      Column() {
        this.Field({ label: '用户名', value: this.username ? '@' + this.username : '' })
        this.Field({ label: '手机号', value: this.phone ? '+' + this.phone : '' })
        this.Field({ label: this.isUser ? '简介' : '描述', value: this.bio })
        this.Field({ label: 'ID（点击复制）', value: this.idText })
      }
      .borderRadius(12)
      .backgroundColor($r('app.color.card'))
      Column() {
        if (this.isUser && this.userId !== this.acc.myUserId) {
          this.Action({ label: '发消息', color: $r('app.color.accent'), fn: () => this.message() })
          this.Action({ label: '开始私密聊天 🔒', color: $r('app.color.secret'), fn: () => this.secretChat() })
        } else if (!this.isUser) {
          this.Action({ label: '查看消息', color: $r('app.color.accent'), fn: () => this.nav.openChat(this.chatId) })
        }
        if (this.chatId && this.userId !== this.acc.myUserId) {
          this.Action({ label: this.muted ? '取消静音' : '静音', color: $r('app.color.text_primary'), fn: () => this.toggleMute() })
        }
        if (this.isUser && this.userId !== this.acc.myUserId) {
          this.Action({ label: this.blocked ? '取消屏蔽' : '屏蔽', color: $r('app.color.danger'), fn: () => this.toggleBlock() })
        }
      }
      .borderRadius(12)
      .backgroundColor($r('app.color.card'))
      .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 12, right: 12, top: 4 })
  }

  @Builder
  TabBar() {
    Row() {
      ForEach(this.tabs, (t: SharedTab, i: number) => {
        Text(t.name).fontSize(14).layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 10, bottom: 10 })
          .fontColor(this.tab === i ? $r('app.color.accent') : $r('app.color.text_secondary'))
          .border({ width: { bottom: this.tab === i ? 2 : 0 }, color: { bottom: $r('app.color.accent') } })
          .onClick(() => this.selectTab(i))
      }, (t: SharedTab) => t.name)
    }
    .width('100%')
    .margin({ top: 12 })
    .backgroundColor($r('app.color.card'))
  }

  private cols(): number {
    return columnsFor(contentWidth(this.paneW), 110, 3, 6);
  }

  private cellSide(): number {
    return Math.floor((contentWidth(this.paneW) - 2 * (this.cols() - 1)) / this.cols());
  }

  build() {
    Column() {
      PaneHeader({ title: this.isUser ? '用户资料' : '详情', showBack: this.showBack,
        onBack: (): void => { this.nav.pop(); } })
      List() {
        ListItem() {
          this.Head()
        }
        if (this.tabs.length > 0) {
          ListItem() {
            this.TabBar()
          }
        }
        if (this.tabs[this.tab] && !this.tabs[this.tab].filter) {
          ForEach(this.members, (m: MemberRow) => {
            ListItem() {
              Row({ space: 12 }) {
                Avatar({ title: m.name, seed: m.userId, path: m.photo, side: 42 })
                Column({ space: 2 }) {
                  Text(m.name).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.text_primary'))
                  Text(m.status).fontSize(12)
                    .fontColor(m.status === '在线' ? $r('app.color.accent') : $r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (m.role) {
                  Text(m.role).fontSize(12).fontColor($r('app.color.accent'))
                }
              }
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .width('100%')
              .backgroundColor($r('app.color.card'))
              .onClick(() => {
                this.nav.push('profile').userId = m.userId;
                this.nav.commit();
              })
            }
          }, (m: MemberRow) => `${m.userId}|${m.photo}|${m.status}`)
          if (this.members.length === 0) {
            ListItem() {
              Text('无法查看成员列表').fontSize(13).fontColor($r('app.color.text_secondary')).padding(24).width('100%')
                .textAlign(TextAlign.Center)
            }
          }
        } else if (this.isMediaTab()) {
          ForEach(chunk<MediaCell>(this.cells, this.cols()), (row: MediaCell[]) => {
            ListItem() {
              Row({ space: 2 }) {
                ForEach(row, (c: MediaCell) => {
                  Stack({ alignContent: Alignment.BottomStart }) {
                    if (c.thumb) {
                      Image('file://' + c.thumb).width('100%').height('100%').objectFit(ImageFit.Cover)
                    } else if (c.mini) {
                      Image(minithumbUri(c.mini)).width('100%').height('100%').objectFit(ImageFit.Cover).blur(10)
                    }
                    if (c.video) {
                      Text(`▶ ${formatDuration(c.duration)}`).fontSize(11).fontColor(Color.White).margin(4)
                        .padding({ left: 5, right: 5, top: 1, bottom: 1 }).borderRadius(6).backgroundColor('#66000000')
                    }
                  }
                  .width(this.cellSide())
                  .height(this.cellSide())
                  .backgroundColor($r('app.color.inset'))
                  .clip(true)
                  .onClick(() => this.openMedia(c.id))
                }, (c: MediaCell) => `${c.id}|${c.thumb}`)
              }
              .width('100%')
              .margin({ top: 2 })
            }
          }, (row: MediaCell[]) => row.map((c: MediaCell) => `${c.id}.${c.thumb}`).join('|') + `/${this.cols()}`)
        } else {
          ForEach(this.rows, (m: MsgItem) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(this.rowTitle(m)).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.text_primary'))
                  if (this.rowDetail(m)) {
                    Text(this.rowDetail(m)).fontSize(12).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor($r('app.color.text_secondary'))
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(formatTime(m.date)).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              .padding({ left: 14, right: 14, top: 9, bottom: 9 })
              .width('100%')
              .backgroundColor($r('app.color.card'))
              // Opens the chat at this message.
              .onClick(() => this.nav.openChat(this.chatId, m.id))
            }
          }, (m: MsgItem) => `${m.id}`)
        }
        if (this.tabs[this.tab] && this.tabs[this.tab].filter && !this.loading && this.items.length === 0) {
          ListItem() {
            Text('暂无内容').fontSize(13).fontColor($r('app.color.text_secondary')).padding(24).width('100%')
              .textAlign(TextAlign.Center)
          }
        }
        if (this.loading) {
          ListItem() {
            Row() {
              LoadingProgress().width(28).height(28).color($r('app.color.accent'))
            }
            .width('100%').justifyContent(FlexAlign.Center).padding(12)
          }
        }
      }
      .layoutWeight(1)
      .width(contentWidth(this.paneW))
      .scrollBar(BarState.Off)
      .onReachEnd(() => this.loadShared(false))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_alt'))
    .onAreaChange((_: Area, area: Area) => { this.paneW = Number(area.width); })
  }
}
