import { router, promptAction } from '@kit.ArkUI';
import { ChatRow, ChatRowData } from '../components/ChatRow';
import { ChatController, ChatView } from '../components/ChatView';
import { Avatar } from '../components/Avatar';
import { Account } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { FolderItem } from '../td/ChatStore';
import { AccountEvent } from '../td/Core';
import { ChatItem, MsgItem } from '../td/Models';
import { summary } from '../td/Parse';
import { formatTime } from '../common/Util';
import { pickAction } from '../common/Menu';

const MUTE_FOREVER = 0x7FFFFFFF;
// Windows at least this wide (unfolded foldables, tablets) show the chat
// list and the open chat side by side; narrower ones show one at a time.
const SPLIT_MIN_WIDTH = 600;

class OpenChat {
  chatId: number = 0;
  messageId: number = 0;
  seq: number = 0; // recreates the chat view when the same chat is reopened at a message
}

class SearchHit {
  chatId: number = 0;
  title: string = '';
  text: string = '';
  msgId: number = 0;
  date: number = 0;
}

@Entry
@Component
struct Main {
  @State rows: ChatRowData[] = [];
  @State folders: FolderItem[] = [];
  @State folderId: number = 0; // 0 all, -1 archive, else folder id
  @State query: string = '';
  @State searching: boolean = false;
  @State hits: SearchHit[] = [];
  @State myName: string = '';
  @State myPhoto: string = '';
  @State archiveCount: number = 0;
  @State winWidth: number = 0;
  @State open: OpenChat = new OpenChat();
  private chatController: ChatController = new ChatController();
  private openSeq: number = 0;
  private acc: Account = Accounts.get().active();
  private listener = (e: AccountEvent): void => this.onEvent(e);
  private managerListener = (): void => this.onAccountsChanged();
  private searchTimer: number = -1;

  aboutToAppear(): void {
    this.attach();
    Accounts.get().on(this.managerListener);
  }

  aboutToDisappear(): void {
    this.acc.off(this.listener);
    Accounts.get().off(this.managerListener);
  }

  onPageShow(): void {
    this.refresh();
  }

  private attach(): void {
    this.acc.on(this.listener);
    this.folders = this.acc.chats.folders.slice();
    this.refreshMe();
    this.refresh();
  }

  private onAccountsChanged(): void {
    const active = Accounts.get().active();
    if (active !== this.acc) {
      this.acc.off(this.listener);
      this.acc = active;
      this.folderId = 0;
      this.open = new OpenChat();
      this.attach();
    }
    if (this.acc.authStep !== 'ready' && this.acc.authStep !== 'loading') {
      router.replaceUrl({ url: 'pages/Login' });
    }
  }

  onEvent(e: AccountEvent): void {
    if (e === 'auth' && this.acc.authStep !== 'ready') {
      router.replaceUrl({ url: 'pages/Login' });
    } else if (e === 'folders') {
      this.folders = this.acc.chats.folders.slice();
    } else if (e === 'me') {
      this.refreshMe();
    } else if (e === 'chats' || e === 'files' || e === 'typing') {
      this.refresh();
    }
  }

  private refreshMe(): void {
    const me = this.acc.me();
    this.myName = me ? me.name() : '';
    this.myPhoto = me ? this.acc.files.path(me.photoFileId) : '';
  }

  refresh(): void {
    const chats = this.acc.chats;
    this.rows = chats.sorted(this.folderId).map((c: ChatItem) => {
      const user = c.userId ? chats.users.get(c.userId) : undefined;
      const online = user !== undefined && user.status !== null && user.status['@type'] === 'userStatusOnline' &&
        !user.isBot && c.userId !== this.acc.myUserId;
      return new ChatRowData(c, c.photoPath || this.acc.files.path(c.photoFileId), chats.isPinned(c, this.folderId),
        chats.isMuted(c), chats.typingText(c.id), c.lastReadOutboxId >= c.lastMsgId, online);
    });
    if (this.folderId === 0) {
      this.archiveCount = chats.sorted(-1).length;
    }
  }

  selectFolder(id: number): void {
    this.folderId = id;
    this.acc.chats.loadMore(id);
    this.refresh();
  }

  onQuery(q: string): void {
    this.query = q;
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
    if (!q.trim()) {
      this.hits = [];
      return;
    }
    this.searchTimer = setTimeout(() => this.search(q.trim()), 300);
  }

  private search(q: string): void {
    Promise.all([this.acc.searchChats(q), this.acc.searchAllMessages(q)]).then((r: [number[], MsgItem[]]) => {
      if (q !== this.query.trim()) {
        return;
      }
      const hits: SearchHit[] = [];
      for (const id of r[0]) {
        const c = this.acc.chat(id);
        if (c) {
          const h = new SearchHit();
          h.chatId = id;
          h.title = c.title;
          h.text = c.type === 'channel' ? '频道' : (c.type === 'private' || c.type === 'secret' ? '联系人' : '群组');
          hits.push(h);
        }
      }
      for (const m of r[1]) {
        const h = new SearchHit();
        h.chatId = m.chatId;
        h.title = this.acc.chat(m.chatId)?.title ?? '';
        h.text = summary(m);
        h.msgId = m.id;
        h.date = m.date;
        hits.push(h);
      }
      this.hits = hits;
    }).catch(() => {});
  }

  private wide(): boolean {
    return this.winWidth >= SPLIT_MIN_WIDTH;
  }

  openChat(chatId: number, msgId: number = 0): void {
    if (chatId === this.open.chatId && !msgId) {
      return;
    }
    const o = new OpenChat();
    o.chatId = chatId;
    o.messageId = msgId;
    o.seq = ++this.openSeq;
    this.open = o;
  }

  closeChat(): void {
    this.open = new OpenChat();
    this.refresh();
  }

  onBackPress(): boolean {
    if (!this.open.chatId) {
      return false;
    }
    if (this.chatController.back()) {
      return true;
    }
    // On a wide window the list stays visible, so back leaves the app as usual.
    if (this.wide()) {
      return false;
    }
    this.closeChat();
    return true;
  }
  // Long-press menu of a chat row.
  chatMenu(row: ChatRowData): void {
    const c = row.chat;
    const unread = c.unread > 0 || c.markedUnread;
    const archived = this.folderId === -1;
    const labels = [row.pinned ? '取消置顶' : '置顶', row.muted ? '取消静音' : '静音',
      unread ? '标为已读' : '标为未读', archived ? '移出归档' : '归档',
      c.type === 'private' || c.type === 'secret' ? '删除聊天' : '退出并删除'];
    pickAction(labels, c.title).then((index: number) => {
      let p: Promise<Object>;
      switch (index) {
        case 0: p = this.acc.togglePin(c, this.folderId, !row.pinned); break;
        case 1: p = this.acc.mute(c, row.muted ? 0 : MUTE_FOREVER); break;
        case 2: p = this.acc.markRead(c, unread); break;
        case 3: p = this.acc.archive(c, !archived); break;
        default:
          this.confirmDelete(c);
          return;
      }
      p.catch((e: Error) => promptAction.showToast({ message: e.message }));
    }).catch(() => {});
  }

  private confirmDelete(c: ChatItem): void {
    const isPrivate = c.type === 'private';
    const buttons: promptAction.Button[] = [{ text: '取消', color: '#888888' }, { text: '删除', color: '#E84026' }];
    if (isPrivate) {
      buttons.push({ text: '同时为对方删除', color: '#E84026' });
    }
    promptAction.showDialog({ title: `删除与“${c.title}”的聊天？`, buttons: buttons })
      .then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index >= 1) {
          this.acc.deleteChat(c, r.index === 2).catch((e: Error) => promptAction.showToast({ message: e.message }));
        }
      });
  }

  @Builder
  Tabs() {
    Scroll() {
      Row({ space: 4 }) {
        this.Tab(0, '全部')
        ForEach(this.folders, (f: FolderItem) => {
          this.Tab(f.id, f.name)
        }, (f: FolderItem) => `${f.id}|${f.name}`)
      }
      .padding({ left: 10, right: 10 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .height(40)
    .width('100%')
  }

  @Builder
  Tab(id: number, name: string) {
    Text(name)
      .fontSize(14)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(16)
      .fontColor(this.folderId === id ? Color.White : $r('sys.color.ohos_id_color_text_primary'))
      .backgroundColor(this.folderId === id ? '#3A8DDE' : '#14000000')
      .onClick(() => this.selectFolder(id))
  }

  build() {
    Row() {
      if (this.wide() || !this.open.chatId) {
        this.ListPane()
      }
      if (this.open.chatId) {
        Column() {
          ForEach([this.open], (oc: OpenChat) => {
            ChatView({
              chatId: oc.chatId,
              messageId: oc.messageId,
              showBack: !this.wide(),
              controller: this.chatController,
              onBack: (): void => this.closeChat(),
              onOpenChat: (id: number): void => this.openChat(id)
            })
          }, (oc: OpenChat) => `${oc.chatId}|${oc.seq}`)
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { left: this.wide() ? 0.5 : 0 }, color: $r('sys.color.ohos_id_color_list_separator') })
      } else if (this.wide()) {
        Column() {
          Text('选择一个聊天开始').fontSize(14).fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(14).backgroundColor('#66556677')
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_: Area, area: Area) => {
      this.winWidth = Number(area.width);
    })
  }

  // Width of the list when shown next to a chat.
  private listWidth(): Length {
    return this.wide() ? Math.min(400, Math.max(300, this.winWidth * 0.36)) : '100%';
  }

  @Builder
  ListPane() {
    Column() {
      Row({ space: 10 }) {
        if (this.folderId === -1) {
          Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(26).onClick(() => this.selectFolder(0))
          Text('归档').fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1)
        } else {
          Avatar({ title: this.myName, seed: this.acc.myUserId, path: this.myPhoto, side: 36 })
            .onClick(() => router.pushUrl({ url: 'pages/Settings' }))
          Text('TdGram').fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('✎', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(20)
            .onClick(() => router.pushUrl({ url: 'pages/Contacts' }))
        }
      }
      .padding({ left: 14, right: 6, top: 10, bottom: 4 })
      .width('100%')

      Search({ value: this.query, placeholder: '搜索聊天和消息' })
        .margin({ left: 12, right: 12, bottom: 4 })
        .onChange((v: string) => this.onQuery(v))
        .onEditChange((editing: boolean) => { this.searching = editing || this.query.length > 0; })

      if (this.query.trim()) {
        List() {
          ForEach(this.hits, (h: SearchHit) => {
            ListItem() {
              Row({ space: 12 }) {
                Avatar({ title: h.title, seed: h.chatId, path: this.acc.files.known(this.acc.chat(h.chatId)?.photoFileId ?? 0),
                  side: 44 })
                Column({ space: 2 }) {
                  Row() {
                    Text(h.title).fontSize(15).fontWeight(FontWeight.Medium).maxLines(1).layoutWeight(1)
                    if (h.date) {
                      Text(formatTime(h.date)).fontSize(12).fontColor('#888888')
                    }
                  }
                  Text(h.text).fontSize(13).fontColor('#777777').maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .onClick(() => this.openChat(h.chatId, h.msgId))
            }
          }, (h: SearchHit) => `${h.chatId}|${h.msgId}`)
        }
        .layoutWeight(1)
      } else {
        if (this.folderId !== -1 && this.folders.length > 0) {
          this.Tabs()
        }
        List() {
          if (this.folderId === 0 && this.archiveCount > 0) {
            ListItem() {
              Row({ space: 12 }) {
                Text('🗄').fontSize(24).width(54).height(54).textAlign(TextAlign.Center).borderRadius(27)
                  .backgroundColor('#E0E4EA')
                Column() {
                  Text('归档的聊天').fontSize(16).fontWeight(FontWeight.Medium)
                  Text(`${this.archiveCount} 个聊天`).fontSize(13).fontColor('#888888')
                }
                .alignItems(HorizontalAlign.Start)
              }
              .padding({ left: 14, right: 14, top: 9, bottom: 9 })
              .width('100%')
              .onClick(() => this.selectFolder(-1))
            }
          }
          ForEach(this.rows, (row: ChatRowData) => {
            ListItem() {
              ChatRow({ row: row })
                .onClick(() => this.openChat(row.chat.id))
                .gesture(LongPressGesture().onAction(() => this.chatMenu(row)))
            }
            .backgroundColor(this.wide() && row.chat.id === this.open.chatId ? '#1F3A8DDE' : Color.Transparent)
          }, (row: ChatRowData) => row.key)
        }
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('sys.color.ohos_id_color_list_separator'), startMargin: 80 })
        .onReachEnd(() => this.acc.chats.loadMore(this.folderId))
      }
    }
    .width(this.listWidth())
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
