import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { notificationManager } from '@kit.NotificationKit';
import { Account } from './Account';
import { ChatItem, MsgItem } from './Models';
import { summary } from './Parse';
import { o } from './TdClient';

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
      const s = JSON.parse(saved) as Settings;
      const d = new Settings();
      this.settings.ghostMode = s.ghostMode ?? d.ghostMode;
      this.settings.hidePhone = s.hidePhone ?? d.hidePhone;
      this.settings.markdown = s.markdown ?? d.markdown;
      this.settings.notifications = s.notifications ?? d.notifications;
      this.settings.notifyPreview = s.notifyPreview ?? d.notifyPreview;
      this.settings.translateTo = s.translateTo ?? d.translateTo;
      this.settings.autoplayGifs = s.autoplayGifs ?? d.autoplayGifs;
      this.settings.autoDownloadMedia = s.autoDownloadMedia ?? d.autoDownloadMedia;
    }
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
      // A logged-out secondary account is removed entirely.
      if (acc.authStep === 'closed' && this.accounts.size > 1 && acc.myUserId) {
        this.remove(acc.slot);
      }
      this.changed();
    };
    a.messages.readReceipts = !this.settings.ghostMode;
    this.accounts.set(slot, a);
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
      a.messages.readReceipts = !this.settings.ghostMode;
      if (a.authStep === 'ready') {
        this.applyGhost(a);
      }
    }
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
    if (this.appInForeground && a.slot === this.activeSlot && a.messages.chatId === chat.id) {
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
    notificationManager.publish(request).catch(() => {});
  }
}
