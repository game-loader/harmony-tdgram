import { display, promptAction, router } from '@kit.ArkUI';
import { ChatRow, ChatRowData } from '../components/ChatRow';
import { ChatPane } from '../components/ChatPane';
import { Avatar } from '../components/Avatar';
import { ContactsPane } from '../panes/ContactsPane';
import { ForwardPane } from '../panes/ForwardPane';
import { PollPane } from '../panes/PollPane';
import { ProfilePane } from '../panes/ProfilePane';
import { ProxyPane } from '../panes/ProxyPane';
import { SecretKeyPane } from '../panes/SecretKeyPane';
import { SettingsPane } from '../panes/SettingsPane';
import { Account } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { FolderItem } from '../td/ChatStore';
import { AccountEvent } from '../td/Core';
import { ChatItem, MsgItem } from '../td/Models';
import { summary } from '../td/Parse';
import { isSplit, listWidth, snapListWidth } from '../common/Layout';
import { Nav, Route } from '../common/Nav';
import { formatTime } from '../common/Util';
import { pickAction } from '../common/Menu';

const MUTE_FOREVER = 0x7FFFFFFF;
const DIVIDER_W = 12; // touch width of the divider between the panes

class SearchHit {
  chatId: number = 0;
  title: string = '';
  text: string = '';
  msgId: number = 0;
  date: number = 0;
}

// The whole signed-in UI: the chat list plus a stack of detail routes
// (chats, profiles, settings...). Wide windows (an unfolded foldable, a
// tablet) show both side by side; narrow ones show the list or the top
// route. Both parts stay alive across folding, so scroll positions, drafts
// and opened pages survive it.
@Entry
@Component
struct Main {
  @State rows: ChatRowData[] = [];
  @State folders: FolderItem[] = [];
  @State folderId: number = 0; // 0 all, -1 archive, else folder id
  @State query: string = '';
  @State hits: SearchHit[] = [];
  @State myName: string = '';
  @State myPhoto: string = '';
  @State archiveCount: number = 0;
  @State winWidth: number = 0;
  @State winHeight: number = 0;
  @State stack: Route[] = [];
  @State splitMode: string = 'auto';
  @State savedListW: number = 0;
  @State dragW: number = 0; // list width while the divider is dragged, 0 otherwise
  @State connection: string = '';
  private nav: Nav = new Nav();
  private acc: Account = Accounts.get().active();
  private listener = (e: AccountEvent): void => this.onEvent(e);
  private managerListener = (): void => this.onAccountsChanged();
  private searchTimer: number = -1;
  private dragFrom: number = 0;
  private leaving: boolean = false;

  aboutToAppear(): void {
    this.nav.onChange = (): void => {
      this.stack = this.nav.stack;
    };
    this.readSettings();
    this.attach();
    Accounts.get().on(this.managerListener);
  }

  aboutToDisappear(): void {
    this.acc.off(this.listener);
    Accounts.get().off(this.managerListener);
    clearTimeout(this.searchTimer);
  }

  onPageShow(): void {
    this.refresh();
  }

  private readSettings(): void {
    const s = Accounts.get().settings;
    this.splitMode = s.splitMode;
    this.savedListW = s.listWidth;
  }

  private attach(): void {
    this.acc.on(this.listener);
    this.folders = this.acc.chats.folders.slice();
    this.refreshMe();
    this.refreshConnection();
    this.refresh();
    this.openPending();
  }

  private toLogin(): void {
    if (!this.leaving) {
      this.leaving = true;
      router.replaceUrl({ url: 'pages/Login' });
    }
  }

  private onAccountsChanged(): void {
    this.readSettings();
    const active = Accounts.get().active();
    if (active !== this.acc) {
      this.acc.off(this.listener);
      this.acc = active;
      this.folderId = 0;
      this.query = '';
      this.hits = [];
      // Routes belong to the previous account.
      this.nav.clear();
      this.attach();
    }
    if (this.acc.authStep !== 'ready' && this.acc.authStep !== 'loading') {
      this.toLogin();
    }
    this.openPending();
  }

  // Opens the chat of a tapped notification once its account is active.
  private openPending(): void {
    const mgr = Accounts.get();
    if (mgr.pendingChat && this.acc.authStep === 'ready' && this.acc.chat(mgr.pendingChat)) {
      const chatId = mgr.pendingChat;
      mgr.pendingChat = 0;
      this.nav.openRootChat(chatId);
    }
  }

  onEvent(e: AccountEvent): void {
    if (e === 'auth' && this.acc.authStep !== 'ready') {
      this.toLogin();
    } else if (e === 'folders') {
      this.folders = this.acc.chats.folders.slice();
    } else if (e === 'me') {
      this.refreshMe();
    } else if (e === 'connection') {
      this.refreshConnection();
    } else if (e === 'chats' || e === 'files' || e === 'typing') {
      this.refresh();
      if (e === 'chats' && Accounts.get().pendingChat) {
        this.openPending();
      }
    }
  }

  private refreshConnection(): void {
    const c = this.acc.connection;
    this.connection = c === 'ready' ? '' : (c === 'waiting' ? '等待网络…' : (c === 'proxy' ? '正在连接代理…' :
      (c === 'updating' ? '正在更新…' : '正在连接…')));
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
        chats.isMuted(c), chats.typingText(c.id), c.lastReadOutboxId >= c.lastMsgId, online, chats.isForum(c));
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
    clearTimeout(this.searchTimer);
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

  // ---- Layout ----

  private split(): boolean {
    return isSplit(this.winWidth, this.winHeight, this.splitMode);
  }

  private listW(): number {
    return this.dragW > 0 ? this.dragW : listWidth(this.winWidth, this.savedListW);
  }

  // Horizontal position and width (vp) of a vertical fold crease inside the
  // window; [0, 0] when there is none.
  private crease(): number[] {
    try {
      if (!display.isFoldable()) {
        return [0, 0];
      }
      for (const r of display.getCurrentFoldCreaseRegion().creaseRects) {
        if (r.height > r.width) {
          return [px2vp(r.left), px2vp(r.width)];
        }
      }
    } catch (e) {
      // No fold information on this device.
    }
    return [0, 0];
  }

  private saveListWidth(w: number): void {
    const mgr = Accounts.get();
    mgr.settings.listWidth = w;
    this.savedListW = w;
    mgr.saveSettings();
  }

  onBackPress(): boolean {
    // Leaves the app only when no detail route is open.
    return this.nav.back();
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
          if (this.nav.rootChatId() === c.id) {
            this.nav.clear();
          }
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
      .fontColor(this.folderId === id ? Color.White : $r('app.color.text_primary'))
      .backgroundColor(this.folderId === id ? $r('app.color.accent') : $r('app.color.chip'))
      .onClick(() => this.selectFolder(id))
  }

  // A route needs its back button unless it is the first one and the list
  // is shown beside it. Read from state here (not passed in) so that folding
  // and unfolding update panes that are already open.
  private backFor(index: number): boolean {
    return !this.split() || index > 0;
  }

  @Builder
  RoutePane(r: Route, index: number) {
    if (r.kind === 'chat') {
      ChatPane({ nav: this.nav, route: r, showBack: this.backFor(index), active: index === this.stack.length - 1,
        onBack: (): void => { this.nav.pop(); } })
    } else if (r.kind === 'profile') {
      ProfilePane({ nav: this.nav, route: r, showBack: this.backFor(index) })
    } else if (r.kind === 'settings') {
      SettingsPane({ nav: this.nav, showBack: this.backFor(index) })
    } else if (r.kind === 'contacts') {
      ContactsPane({ nav: this.nav, showBack: this.backFor(index) })
    } else if (r.kind === 'forward') {
      ForwardPane({ nav: this.nav, showBack: this.backFor(index) })
    } else if (r.kind === 'poll') {
      PollPane({ nav: this.nav, route: r, showBack: this.backFor(index) })
    } else if (r.kind === 'secretKey') {
      SecretKeyPane({ nav: this.nav, route: r, showBack: this.backFor(index) })
    } else {
      ProxyPane({ nav: this.nav, showBack: this.backFor(index) })
    }
  }

  // Every route of the stack stays alive; only the top one is visible. The
  // first route needs no back button while the list is shown beside it.
  @Builder
  Detail() {
    Stack() {
      if (this.stack.length === 0) {
        Column() {
          Text('选择一个聊天开始').fontSize(14).fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(14)
            .backgroundColor($r('app.color.service_bg'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.chat_bg'))
      }
      ForEach(this.stack, (r: Route, i: number) => {
        Column() {
          this.RoutePane(r, i)
        }
        .width('100%')
        .height('100%')
        .visibility(i === this.stack.length - 1 ? Visibility.Visible : Visibility.None)
      }, (r: Route) => `${r.id}`)
    }
    .layoutWeight(1)
    .height('100%')
    .visibility(this.split() || this.stack.length > 0 ? Visibility.Visible : Visibility.None)
  }

  // Drag to resize the panes (snaps to the fold's crease); double-tap for
  // the default width.
  @Builder
  Divider() {
    Column() {
      Column().width(this.dragW > 0 ? 3 : 0.5).height('100%')
        .backgroundColor(this.dragW > 0 ? $r('app.color.accent') : $r('app.color.separator'))
    }
    .width(DIVIDER_W)
    .height('100%')
    .margin({ left: -DIVIDER_W / 2, right: -DIVIDER_W / 2 })
    .zIndex(1)
    .gesture(GestureGroup(GestureMode.Exclusive,
      PanGesture({ direction: PanDirection.Horizontal, distance: 4 })
        .onActionStart(() => {
          this.dragFrom = this.listW();
          this.dragW = this.dragFrom;
        })
        .onActionUpdate((e: GestureEvent) => {
          const c = this.crease();
          this.dragW = snapListWidth(this.winWidth, this.dragFrom + e.offsetX, c[0], c[1]);
        })
        .onActionEnd(() => {
          const w = this.dragW;
          this.dragW = 0;
          if (w > 0) {
            this.saveListWidth(w);
          }
        })
        .onActionCancel(() => {
          this.dragW = 0;
        }),
      TapGesture({ count: 2 }).onAction(() => this.saveListWidth(0))
    ))
  }

  build() {
    Row() {
      this.ListPane()
      if (this.split()) {
        this.Divider()
      }
      this.Detail()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .onAreaChange((_: Area, area: Area) => {
      this.winWidth = Number(area.width);
      this.winHeight = Number(area.height);
    })
  }

  @Builder
  ListPane() {
    Column() {
      Row({ space: 10 }) {
        if (this.folderId === -1) {
          Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(26).onClick(() => this.selectFolder(0))
          Text('归档').fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1).fontColor($r('app.color.text_primary'))
        } else {
          Avatar({ title: this.myName, seed: this.acc.myUserId, path: this.myPhoto, side: 36 })
            .onClick(() => {
              this.nav.openRoot('settings');
              this.nav.commit();
            })
          Column() {
            Text('TdGram').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            if (this.connection) {
              Text(this.connection).fontSize(12).fontColor($r('app.color.accent'))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button('✎', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(20)
            .onClick(() => {
              this.nav.openRoot('contacts');
              this.nav.commit();
            })
        }
      }
      .padding({ left: 14, right: 6, top: 6, bottom: 4 })
      .constraintSize({ minHeight: 52 })
      .width('100%')

      Search({ value: this.query, placeholder: '搜索聊天和消息' })
        .margin({ left: 12, right: 12, bottom: 4 })
        .onChange((v: string) => this.onQuery(v))

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
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
                    if (h.date) {
                      Text(formatTime(h.date)).fontSize(12).fontColor($r('app.color.text_secondary'))
                    }
                  }
                  Text(h.text).fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .onClick(() => this.nav.openRootChat(h.chatId, h.msgId))
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
                  .backgroundColor($r('app.color.chip'))
                Column() {
                  Text('归档的聊天').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  Text(`${this.archiveCount} 个聊天`).fontSize(13).fontColor($r('app.color.text_secondary'))
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
                .onClick(() => this.nav.openRootChat(row.chat.id))
                .gesture(LongPressGesture().onAction(() => this.chatMenu(row)))
            }
            .backgroundColor(this.split() && this.stack.length > 0 && this.stack[0].kind === 'chat' &&
              this.stack[0].chatId === row.chat.id ? $r('app.color.accent_soft') : Color.Transparent)
          }, (row: ChatRowData) => row.key)
        }
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('app.color.separator'), startMargin: 80 })
        .onReachEnd(() => this.acc.chats.loadMore(this.folderId))
      }
    }
    .width(this.split() ? this.listW() : '100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .visibility(this.split() || this.stack.length === 0 ? Visibility.Visible : Visibility.None)
  }
}
