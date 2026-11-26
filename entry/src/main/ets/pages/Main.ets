import { display } from '@kit.ArkUI';
import { ChatRow, ChatRowActions, ChatRowData } from '../components/ChatRow';
import { ChatPane } from '../components/ChatPane';
import { Avatar } from '../components/Avatar';
import { IconButton } from '../components/IconButton';
import { ContactsPane } from '../panes/ContactsPane';
import { FiltersPane } from '../panes/FiltersPane';
import { ForwardPane } from '../panes/ForwardPane';
import { PollPane } from '../panes/PollPane';
import { ProfilePane } from '../panes/ProfilePane';
import { ProxyPane } from '../panes/ProxyPane';
import { SecretKeyPane } from '../panes/SecretKeyPane';
import { SettingsPane } from '../panes/SettingsPane';
import { Account, LinkTarget } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { FolderItem } from '../td/ChatStore';
import { AccountEvent } from '../td/Core';
import { ChatItem, MsgItem } from '../td/Models';
import { summary } from '../td/Parse';
import { isSplit, listWidth, snapListWidth } from '../common/Layout';
import { Nav, Route } from '../common/Nav';
import { formatTime } from '../common/Util';
import { pickAction } from '../common/Menu';
import { dialog, replacePage, toast } from '../common/Ui';
import { openLinkTarget } from '../common/LinkOpen';
import { confirmDelete } from '../common/ChatActions';

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
  @State folderUnread: string = ''; // "id:count,..." so tabs refresh when counts change
  private nav: Nav = new Nav();
  private acc: Account = Accounts.get().active();
  private listener = (e: AccountEvent): void => this.onEvent(e);
  private managerListener = (): void => this.onAccountsChanged();
  private searchTimer: number = -1;
  private dragFrom: number = 0;
  private listScroller: ListScroller = new ListScroller();
  private leaving: boolean = false;
  // Rows by chat id. They are kept across refreshes so a change only touches
  // the fields that differ; see ChatRowData.
  private rowCache: Map<number, ChatRowData> = new Map();
  private rowScope: string = '';

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
      replacePage('pages/Login');
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

  // Opens the chat of a tapped notification once its account is active, and
  // a link another app handed us once the account is logged in.
  private openPending(): void {
    const mgr = Accounts.get();
    if (this.acc.authStep !== 'ready') {
      return;
    }
    if (mgr.pendingChat && this.acc.chat(mgr.pendingChat)) {
      const chatId = mgr.pendingChat;
      mgr.pendingChat = 0;
      this.nav.openRootChat(chatId);
    }
    if (mgr.pendingLink) {
      const url = mgr.pendingLink;
      mgr.pendingLink = '';
      const acc = this.acc;
      acc.openLink(url).then((t: LinkTarget) => openLinkTarget(acc, this.nav, t, true))
        .catch(() => toast('无法打开链接'));
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
      if (e === 'chats' && (Accounts.get().pendingChat || Accounts.get().pendingLink)) {
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
    // Pinning and the swipe actions depend on the folder, so rows are per folder.
    const scope = `${this.acc.slot}:${this.folderId}`;
    if (scope !== this.rowScope) {
      this.rowScope = scope;
      this.rowCache.clear();
    }
    const seen = new Set<number>();
    const next = chats.sorted(this.folderId).map((c: ChatItem) => {
      const user = c.userId ? chats.users.get(c.userId) : undefined;
      const online = user !== undefined && user.status !== null && user.status['@type'] === 'userStatusOnline' &&
        !user.isBot && c.userId !== this.acc.myUserId;
      let row = this.rowCache.get(c.id);
      if (!row) {
        row = new ChatRowData(c, scope);
        this.rowCache.set(c.id, row);
      } else if (row.chat !== c) {
        row.chat = c;
      }
      seen.add(c.id);
      return row.apply(c.photoPath || this.acc.files.path(c.photoFileId), chats.isPinned(c, this.folderId),
        chats.isMuted(c), chats.typingText(c.id), c.lastReadOutboxId >= c.shownMsgId, online, chats.isForum(c));
    });
    if (seen.size !== this.rowCache.size) {
      Array.from(this.rowCache.keys()).filter((id: number) => !seen.has(id))
        .forEach((id: number) => this.rowCache.delete(id));
    }
    // The list itself is only touched when chats were added, removed or moved.
    if (next.length !== this.rows.length || next.some((r: ChatRowData, i: number) => r.key !== this.rows[i].key)) {
      this.rows = next;
    }
    if (this.folderId === 0) {
      this.archiveCount = chats.sorted(-1).length;
    }
    this.folderUnread = [0].concat(this.folders.map((f: FolderItem) => f.id))
      .map((id: number) => `${id}:${chats.unreadIn(id)}`).join(',');
  }

  private unreadOf(id: number): number {
    for (const part of this.folderUnread.split(',')) {
      const kv = part.split(':');
      if (Number(kv[0]) === id) {
        return Number(kv[1]);
      }
    }
    return 0;
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
    if (!canIUse('SystemCapability.Window.SessionManager')) {
      return [0, 0];
    }
    try {
      // @SuppressWarnings syscap
      if (!display.isFoldable()) {
        return [0, 0];
      }
      // @SuppressWarnings syscap
      for (const r of display.getCurrentFoldCreaseRegion().creaseRects) {
        if (r.height > r.width) {
          const ui = this.getUIContext();
          return [ui.px2vp(r.left), ui.px2vp(r.width)];
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

  private closeSwipe(): void {
    try {
      this.listScroller.closeAllSwipeActions();
    } catch (e) {
      // The list is not shown.
    }
  }

  private quick(p: Promise<Object>): void {
    this.closeSwipe();
    p.catch((e: Error) => toast(e.message));
  }

  // Revealed by swiping a chat row to the left.
  @Builder
  RowActions(row: ChatRowData) {
    ChatRowActions({
      row: row, archived: this.folderId === -1,
      onRead: (r: ChatRowData): void => this.quick(this.acc.markRead(r.chat, r.unread > 0 || r.markedUnread)),
      onPin: (r: ChatRowData): void => this.quick(this.acc.togglePin(r.chat, this.folderId, !r.pinned)),
      onArchive: (r: ChatRowData): void => this.quick(this.acc.archive(r.chat, this.folderId !== -1)),
      onDelete: (r: ChatRowData): void => {
        this.closeSwipe();
        confirmDelete(this.acc, this.nav, r.chat);
      }
    })
  }

  // Long-press menu of a chat row.
  chatMenu(row: ChatRowData): void {
    const c = row.chat;
    const unread = c.unread > 0 || c.markedUnread;
    const archived = this.folderId === -1;
    const labels = [row.pinned ? '取消置顶' : '置顶', row.muted ? '取消静音' : '静音',
      unread ? '标为已读' : '标为未读', archived ? '移出归档' : '归档',
      c.type === 'private' || c.type === 'secret' ? '删除聊天' : (c.type === 'channel' ? '退出频道' : '退出群组')];
    pickAction(labels, c.title).then((index: number) => {
      let p: Promise<Object>;
      switch (index) {
        case 0: p = this.acc.togglePin(c, this.folderId, !row.pinned); break;
        case 1: p = this.acc.mute(c, row.muted ? 0 : MUTE_FOREVER); break;
        case 2: p = this.acc.markRead(c, unread); break;
        case 3: p = this.acc.archive(c, !archived); break;
        default:
          confirmDelete(this.acc, this.nav, c);
          return;
      }
      p.catch((e: Error) => toast(e.message));
    }).catch(() => {});
  }

  @Builder
  Tabs() {
    Scroll() {
      Row({ space: 2 }) {
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
    .border({ width: { bottom: 0.5 }, color: $r('app.color.separator') })
  }

  // Folder tabs: the chosen one is bold and underlined in the accent color.
  @Builder
  Tab(id: number, name: string) {
    Column({ space: 6 }) {
      Row({ space: 5 }) {
        Text(name).fontSize(15)
          .fontWeight(this.folderId === id ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.folderId === id ? $r('app.color.accent') : $r('app.color.text_secondary'))
        if (this.unreadOf(id) > 0) {
          Text(this.unreadOf(id) > 99 ? '99+' : String(this.unreadOf(id))).fontSize(11).fontWeight(FontWeight.Bold)
            .padding({ left: 5, right: 5 }).height(17).constraintSize({ minWidth: 17 }).textAlign(TextAlign.Center)
            .borderRadius(8.5).fontColor(Color.White)
            .backgroundColor(this.folderId === id ? $r('app.color.accent') : $r('app.color.text_secondary'))
        }
      }
      Column().height(3).width('100%').borderRadius(1.5)
        .backgroundColor(this.folderId === id ? $r('app.color.accent') : Color.Transparent)
    }
    .padding({ left: 10, right: 10, top: 8 })
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
    } else if (r.kind === 'filters') {
      FiltersPane({ nav: this.nav, showBack: this.backFor(index) })
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
        Column({ space: 14 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.message_on_message_fill')).fontSize(44).fontColor([Color.White])
          }
          .width(96)
          .height(96)
          .borderRadius(32)
          .linearGradient({ angle: 135, colors: [[$r('app.color.accent'), 0], [$r('app.color.accent_end'), 1]] })
          .shadow({ radius: 24, color: '#332F6BFF', offsetY: 8 })
          Text('选择一个聊天').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            .margin({ top: 6 })
          Text('从左侧列表打开聊天，拖动分隔条可以调整两栏宽度').fontSize(14)
            .fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
            .constraintSize({ maxWidth: 280 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .linearGradient({ angle: 180, colors: [[$r('app.color.chat_bg'), 0], [$r('app.color.chat_bg_end'), 1]] })
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
    Stack() {
      Column().width(this.dragW > 0 ? 3 : 0.5).height('100%')
        .backgroundColor(this.dragW > 0 ? $r('app.color.accent') : $r('app.color.separator'))
      // A small grip shows that the divider can be dragged.
      Column().width(4).height(36).borderRadius(2)
        .backgroundColor(this.dragW > 0 ? $r('app.color.accent') : $r('app.color.text_secondary'))
        .opacity(this.dragW > 0 ? 1 : 0.35)
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
          IconButton({ glyph: $r('sys.symbol.chevron_left'), tint: $r('app.color.text_primary'), glyphSize: 24 })
            .margin({ left: -10 })
            .onClick(() => this.selectFolder(0))
          Text('归档').fontSize(28).fontWeight(FontWeight.Bold).layoutWeight(1).fontColor($r('app.color.text_primary'))
            .letterSpacing(-0.5)
        } else {
          Column({ space: 1 }) {
            Text('TdGram').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
              .letterSpacing(-0.6)
            if (this.connection) {
              Row({ space: 6 }) {
                LoadingProgress().width(14).height(14).color($r('app.color.accent'))
                Text(this.connection).fontSize(13).fontColor($r('app.color.accent'))
              }
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          IconButton({ glyph: $r('sys.symbol.square_and_pencil'), tint: $r('app.color.accent'), glyphSize: 22 })
            .onClick(() => {
              this.nav.openRoot('contacts');
              this.nav.commit();
            })
          Avatar({ title: this.myName, seed: this.acc.myUserId, path: this.myPhoto, side: 36 })
            .onClick(() => {
              this.nav.openRoot('settings');
              this.nav.commit();
            })
        }
      }
      .padding({ left: 18, right: 14, top: 10, bottom: 6 })
      .constraintSize({ minHeight: 60 })
      .width('100%')

      Search({ value: this.query, placeholder: '搜索聊天和消息' })
        .height(40)
        .backgroundColor($r('app.color.input_bg'))
        .placeholderColor($r('app.color.text_secondary'))
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 14, right: 14, top: 2, bottom: 6 })
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
              .padding({ left: 16, right: 16, top: 9, bottom: 9 })
              .onClick(() => this.nav.openRootChat(h.chatId, h.msgId))
            }
          }, (h: SearchHit) => `${h.chatId}|${h.msgId}`)
        }
        .layoutWeight(1)
      } else {
        if (this.folderId !== -1 && this.folders.length > 0) {
          this.Tabs()
        }
        List({ scroller: this.listScroller }) {
          if (this.folderId === 0 && this.archiveCount > 0) {
            ListItem() {
              Row({ space: 12 }) {
                Stack() {
                  SymbolGlyph($r('sys.symbol.archivebox_fill')).fontSize(24).fontColor([Color.White])
                }
                .width(54).height(54).borderRadius(27)
                .linearGradient({ angle: 135, colors: [['#A9B4C2', 0], ['#6F7C8C', 1]] })
                Column({ space: 4 }) {
                  Text('归档的聊天').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
                  Text(`${this.archiveCount} 个聊天`).fontSize(14).fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_secondary')])
              }
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .width('100%')
              .onClick(() => this.selectFolder(-1))
            }
          }
          ForEach(this.rows, (row: ChatRowData) => {
            ListItem() {
              ChatRow({ row: row })
                .onClick(() => this.nav.openRootChat(row.id))
                .gesture(LongPressGesture().onAction(() => this.chatMenu(row)))
            }
            // The open chat is marked with a rounded tint inset from the edges.
            .backgroundColor(this.split() && this.stack.length > 0 && this.stack[0].kind === 'chat' &&
              !this.stack[0].threadId && this.stack[0].chatId === row.id ? $r('app.color.accent_soft') :
              Color.Transparent)
            .borderRadius(16)
            .margin({ left: 6, right: 6 })
            .swipeAction({ end: { builder: (): void => { this.RowActions(row) } } })
          }, (row: ChatRowData) => row.key)
        }
        .layoutWeight(1)
        .padding({ top: 4 })
        .onReachEnd(() => this.acc.chats.loadMore(this.folderId))
      }
    }
    .width(this.split() ? this.listW() : '100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .visibility(this.split() || this.stack.length === 0 ? Visibility.Visible : Visibility.None)
  }
}
