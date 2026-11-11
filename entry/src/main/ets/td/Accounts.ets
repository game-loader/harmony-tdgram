import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { Account } from './Account';
import { ChatItem, MsgItem } from './Models';
import { summary } from './Parse';
import { ProxyConfig } from './Proxy';
import { o, TdObject } from './TdClient';

export type ThemeMode = 'auto' | 'light' | 'dark';
export type SplitMode = 'auto' | 'on' | 'off';

// App-wide settings, several of them Nicegram-style privacy options.
export class Settings {
  ghostMode: boolean = false;    // no read receipts, no typing, appear offline
  hidePhone: boolean = false;    // hide own phone number in the UI
  markdown: boolean = true;      // parse **bold** etc. when sending
  notifications: boolean = true;
  notifyPreview: boolean = true;
  translateTo: string = 'zh';
  autoplayGifs: boolean = true;
  autoDownloadMedia: boolean = true;
  theme: ThemeMode = 'auto';
  splitMode: SplitMode = 'auto'; // chat list beside the open chat
  listWidth: number = 0;         // vp, width of the list in split view; 0 = default
  proxies: ProxyConfig[] = [];
  proxyIndex: number = -1;       // enabled proxy, -1 = direct connection

  // A copy with the saved values of `s` where present.
  static from(s: Settings): Settings {
    const d = new Settings();
    d.ghostMode = s.ghostMode ?? d.ghostMode;
    d.hidePhone = s.hidePhone ?? d.hidePhone;
    d.markdown = s.markdown ?? d.markdown;
    d.notifications = s.notifications ?? d.notifications;
    d.notifyPreview = s.notifyPreview ?? d.notifyPreview;
    d.translateTo = s.translateTo ?? d.translateTo;
    d.autoplayGifs = s.autoplayGifs ?? d.autoplayGifs;
    d.autoDownloadMedia = s.autoDownloadMedia ?? d.autoDownloadMedia;
    d.theme = s.theme ?? d.theme;
    d.splitMode = s.splitMode ?? d.splitMode;
    d.listWidth = s.listWidth ?? d.listWidth;
    d.proxies = (s.proxies ?? []).map((p: ProxyConfig) => ProxyConfig.from(p));
    d.proxyIndex = s.proxyIndex ?? d.proxyIndex;
    if (d.proxyIndex >= d.proxies.length) {
      d.proxyIndex = -1;
    }
    return d;
  }
}

type ManagerListener = () => void;

// Owns every account, the active one, and the app settings.
export class Accounts {
  private static instance: Accounts | null = null;
  private context: common.UIAbilityContext | null = null;
  private store: preferences.Preferences | null = null;
  private accounts: Map<number, Account> = new Map();
  private listeners: ManagerListener[] = [];
  activeSlot: number = 0;
  settings: Settings = new Settings();
  appInForeground: boolean = true;
  // Chat a tapped notification asks for; the main page opens and clears it.
  pendingChat: number = 0;
  onThemeChanged: () => void = (): void => {};

  static get(): Accounts {
    if (!Accounts.instance) {
      Accounts.instance = new Accounts();
    }
    return Accounts.instance;
  }

  init(context: common.UIAbilityContext): void {
    if (this.context) {
      return;
    }
    this.context = context;
    this.store = preferences.getPreferencesSync(context, { name: 'tdgram' });
    const slots = JSON.parse(this.store.getSync('slots', '[0]') as string) as number[];
    this.activeSlot = this.store.getSync('active', slots[0]) as number;
    const saved = this.store.getSync('settings', '') as string;
    if (saved) {
      try {
        this.settings = Settings.from(JSON.parse(saved) as Settings);
      } catch (e) {
        this.settings = new Settings();
      }
    }
    this.applyTheme();
    for (const slot of slots) {
      this.create(slot);
    }
    if (!this.accounts.has(this.activeSlot)) {
      this.activeSlot = slots[0];
    }
  }

  private create(slot: number): Account {
    const a = new Account(slot, this.context!);
    a.chats.onIncoming = (chat: ChatItem, msg: MsgItem) => this.notify(a, chat, msg);
    a.onAuthChanged = (acc: Account) => {
      if (acc.authStep === 'ready') {
        this.applyGhost(acc);
      }
      if (acc.authStep === 'closed' && acc.myUserId) {
        if (this.accounts.size > 1) {
          // A logged-out secondary account is removed entirely.
          this.remove(acc.slot);
        } else {
          // The only account: a closed TDLib client cannot be reused, so a
          // fresh one takes its slot and the login screen works right away.
          acc.td.dispose();
          this.create(acc.slot);
        }
      }
      this.changed();
    };
    a.readReceipts = !this.settings.ghostMode;
    this.accounts.set(slot, a);
    // TDLib queues these until its parameters are set, so the proxy is in
    // place before the first connection of a fresh login.
    this.applyProxy(a);
    return a;
  }

  on(l: ManagerListener): void {
    this.listeners.push(l);
  }

  off(l: ManagerListener): void {
    this.listeners = this.listeners.filter((x: ManagerListener) => x !== l);
  }

  private changed(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  active(): Account {
    return this.accounts.get(this.activeSlot)!;
  }

  all(): Account[] {
    return Array.from(this.accounts.values()).sort((a: Account, b: Account) => a.slot - b.slot);
  }

  private persist(): void {
    this.store?.putSync('slots', JSON.stringify(Array.from(this.accounts.keys())));
    this.store?.putSync('active', this.activeSlot);
    this.store?.flush();
  }

  switchTo(slot: number): void {
    if (this.accounts.has(slot)) {
      this.activeSlot = slot;
      this.persist();
      this.changed();
    }
  }

  // Adds a new account slot and makes it active; the UI then shows login.
  add(): Account {
    let slot = 0;
    while (this.accounts.has(slot)) {
      slot++;
    }
    const a = this.create(slot);
    this.activeSlot = slot;
    this.persist();
    this.changed();
    return a;
  }

  private remove(slot: number): void {
    const a = this.accounts.get(slot);
    if (!a) {
      return;
    }
    a.td.dispose();
    this.accounts.delete(slot);
    if (this.activeSlot === slot) {
      this.activeSlot = this.all()[0].slot;
    }
    this.persist();
  }

  saveSettings(): void {
    this.store?.putSync('settings', JSON.stringify(this.settings));
    this.store?.flush();
    for (const a of this.all()) {
      a.readReceipts = !this.settings.ghostMode;
      if (a.authStep === 'ready') {
        this.applyGhost(a);
      }
    }
    this.changed();
  }

  // Light, dark, or whatever the system uses. System colors and the app's
  // own color resources both follow this.
  applyTheme(): void {
    const mode = this.settings.theme === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      (this.settings.theme === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    try {
      this.context?.getApplicationContext().setColorMode(mode);
    } catch (e) {
      // Keep the system's mode.
    }
    this.onThemeChanged();
  }

  // A notification was tapped: switch to its account and open the chat.
  openFromNotification(slot: number, chatId: number): void {
    if (!this.accounts.has(slot) || !chatId) {
      return;
    }
    this.pendingChat = chatId;
    if (slot !== this.activeSlot) {
      this.activeSlot = slot;
      this.persist();
    }
    this.changed();
  }

  clearNotifications(a: Account, chatId: number): void {
    notificationManager.cancelGroup(`chat_${a.slot}_${chatId}`).catch(() => {});
  }

  // Makes every account use the enabled proxy, or a direct connection.
  applyProxies(): void {
    for (const a of this.all()) {
      this.applyProxy(a);
    }
  }

  // Changes run one after another per account, so the last one applied wins.
  private proxyJobs: Map<number, Promise<void>> = new Map();

  private applyProxy(a: Account): void {
    const prev = this.proxyJobs.get(a.slot) ?? Promise.resolve();
    this.proxyJobs.set(a.slot, prev.then(() => this.setProxy(a)));
  }

  private setProxy(a: Account): Promise<void> {
    const s = this.settings;
    const wanted = s.proxyIndex >= 0 && s.proxyIndex < s.proxies.length ? s.proxies[s.proxyIndex] : null;
    // TDLib persists its own list; clear it so only the wanted proxy remains.
    return a.send(o({ '@type': 'getProxies' })).then((r: TdObject) => {
      const old = ((r['proxies'] as TdObject[]) ?? []).map((p: TdObject) => p['id'] as number);
      const removals = old.map((id: number) => a.send(o({ '@type': 'removeProxy', 'proxy_id': id })).catch(() => o({})));
      return Promise.all(removals);
    }).then(() => {
      if (wanted) {
        return a.send(o({ '@type': 'addProxy', 'proxy': wanted.toTd(), 'enable': true, 'comment': '' }));
      }
      return a.send(o({ '@type': 'disableProxy' }));
    }).then(() => {}).catch(() => {});
  }

  private applyGhost(a: Account): void {
    a.send(o({ '@type': 'setOption', 'name': 'online',
      'value': o({ '@type': 'optionValueBoolean', 'value': !this.settings.ghostMode && this.appInForeground }) }))
      .catch(() => {});
  }

  setForeground(fg: boolean): void {
    this.appInForeground = fg;
    for (const a of this.all()) {
      if (a.authStep === 'ready') {
        this.applyGhost(a);
      }
    }
  }

  private notifyId: number = 1;

  private notify(a: Account, chat: ChatItem, msg: MsgItem): void {
    if (!this.settings.notifications || a.chats.isMuted(chat)) {
      return;
    }
    // Skip the chat the user is looking at.
    if (this.appInForeground && a.slot === this.activeSlot && a.isViewing(chat.id)) {
      return;
    }
    let text = this.settings.notifyPreview ? summary(msg) : '新消息';
    if (chat.type === 'secret') {
      text = '新的私密消息';
    } else if (this.settings.notifyPreview && (chat.type === 'group' || chat.type === 'supergroup')) {
      text = `${a.chats.nameOf(msg.senderId, msg.senderIsChat)}: ${text}`;
    }
    const request: notificationManager.NotificationRequest = {
      id: this.notifyId++,
      groupName: `chat_${a.slot}_${chat.id}`,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: chat.title, text: text }
      }
    };
    // Tapping the notification opens that chat.
    const ctx = this.context!;
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: ctx.abilityInfo.bundleName, abilityName: ctx.abilityInfo.name,
        parameters: { 'tdgramSlot': String(a.slot), 'tdgramChat': String(chat.id) }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(info).then((agent: WantAgent) => {
      request.wantAgent = agent;
      return notificationManager.publish(request);
    }).catch(() => {
      notificationManager.publish(request).catch(() => {});
    });
  }
}
