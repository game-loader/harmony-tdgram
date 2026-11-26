import { promptAction } from '@kit.ArkUI';
import { Avatar } from '../components/Avatar';
import { PaneHeader } from '../components/PaneHeader';
import { copyText } from '../common/AppState';
import { contentWidth } from '../common/Layout';
import { Nav } from '../common/Nav';
import { formatSize } from '../common/Util';
import { pickAction } from '../common/Menu';
import { Account } from '../td/Account';
import { Accounts, Settings as AppSettings, SplitMode, ThemeMode } from '../td/Accounts';
import { Filters } from '../td/Filters';
import { o, TdError, TdObject } from '../td/TdClient';
import { dialog, toast } from '../common/Ui';

interface ItemP {
  label: string;
  value: string;
  color: ResourceColor;
  fn: () => void;
  glyph?: Resource;
  tile?: string; // color of the rounded square behind the symbol
  arrow?: boolean; // opens another page
}

interface SwitchP {
  label: string;
  detail: string;
  on: boolean;
  fn: (v: boolean) => void;
  glyph?: Resource;
  tile?: string;
}

class AccountRow {
  slot: number = 0;
  name: string = '';
  phone: string = '';
  photo: string = '';
  userId: number = 0;
  active: boolean = false;
}

class SessionRow {
  id: string = '';
  title: string = '';
  detail: string = '';
  current: boolean = false;
}

const LANGS: string[] = ['zh', 'en', 'ja', 'ko', 'ru', 'fr', 'de', 'es'];
const LANG_NAMES: string[] = ['中文', 'English', '日本語', '한국어', 'Русский', 'Français', 'Deutsch', 'Español'];
const THEMES: ThemeMode[] = ['auto', 'light', 'dark'];
const THEME_NAMES: string[] = ['跟随系统', '浅色', '深色'];
const SPLITS: SplitMode[] = ['auto', 'on', 'off'];
const SPLIT_NAMES: string[] = ['自动（展开时分栏）', '始终分栏', '始终单栏'];

@Component
export struct SettingsPane {
  nav: Nav = new Nav();
  @Prop showBack: boolean = true;
  @State accounts: AccountRow[] = [];
  @State s: AppSettings = new AppSettings();
  @State sessions: SessionRow[] = [];
  @State storage: string = '';
  @State paneW: number = 360;
  @State filterText: string = '';
  private mgr: Accounts = Accounts.get();
  private filterListener = (): void => this.refreshFilters();

  aboutToDisappear(): void {
    Filters.get().off(this.filterListener);
  }

  private refreshFilters(): void {
    const c = Filters.get().config;
    if (!c.enabled) {
      this.filterText = '已关闭';
      return;
    }
    const parts: string[] = [];
    if (c.entries.length > 0) {
      parts.push(`屏蔽 ${c.entries.length} 条`);
    }
    const rules = c.rules.length + (c.presets ? 1 : 0);
    if (rules > 0) {
      parts.push(`规则 ${rules} 条`);
    }
    if (Filters.get().aiReady()) {
      parts.push('AI');
    }
    this.filterText = parts.length > 0 ? parts.join(' · ') : '未设置';
  }

  aboutToAppear(): void {
    this.s = AppSettings.from(this.mgr.settings);
    this.refreshAccounts();
    this.loadStorage();
    this.refreshFilters();
    Filters.get().on(this.filterListener);
  }

  private refreshAccounts(): void {
    this.accounts = this.mgr.all().filter((a: Account) => a.authStep === 'ready').map((a: Account) => {
      const r = new AccountRow();
      const me = a.me();
      r.slot = a.slot;
      r.userId = a.myUserId;
      r.name = me ? me.name() : `账号 ${a.slot + 1}`;
      r.phone = me && !this.s.hidePhone ? `+${me.phone}` : (me && me.username ? '@' + me.username : '');
      r.photo = me ? a.files.path(me.photoFileId) : '';
      r.active = a.slot === this.mgr.activeSlot;
      return r;
    });
  }

  private update(fn: (s: AppSettings) => void): void {
    fn(this.mgr.settings);
    this.mgr.saveSettings();
    // A fresh object so @State notices the change.
    this.s = AppSettings.from(this.mgr.settings);
    this.refreshAccounts();
  }

  private loadSessions(): void {
    this.mgr.active().send(o({ '@type': 'getActiveSessions' })).then((r: TdObject) => {
      this.sessions = ((r['sessions'] as TdObject[]) ?? []).map((x: TdObject) => {
        const row = new SessionRow();
        row.id = String(x['id']);
        row.current = x['is_current'] as boolean;
        row.title = `${x['application_name'] as string} ${x['application_version'] as string}`;
        row.detail = `${x['device_model'] as string} · ${x['platform'] as string} · ${x['country'] as string}`;
        return row;
      });
    }).catch((e: TdError) => toast(e.message));
  }

  private terminate(row: SessionRow): void {
    dialog({ title: `终止“${row.title}”？`,
      buttons: [{ text: '取消', color: '#888888' }, { text: '终止', color: '#E84026' }] })
      .then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 1) {
          this.mgr.active().send(o({ '@type': 'terminateSession', 'session_id': row.id }))
            .then(() => this.loadSessions()).catch((e: TdError) => toast(e.message));
        }
      });
  }

  private loadStorage(): void {
    this.mgr.active().send(o({ '@type': 'getStorageStatisticsFast' })).then((r: TdObject) => {
      this.storage = `文件 ${formatSize(r['files_size'] as number)} · 数据库 ${formatSize(r['database_size'] as number)}`;
    }).catch(() => {});
  }

  private clearCache(): void {
    this.mgr.active().send(o({ '@type': 'optimizeStorage', 'size': 0, 'ttl': 0, 'count': 0, 'immunity_delay': 0,
      'file_types': [], 'chat_ids': [], 'exclude_chat_ids': [], 'return_deleted_file_statistics': false,
      'chat_limit': 0 })).then(() => {
      toast('缓存已清理');
      this.loadStorage();
    }).catch((e: TdError) => toast(e.message));
  }

  private logOut(): void {
    dialog({ title: '退出当前账号？',
      buttons: [{ text: '取消', color: '#888888' }, { text: '退出', color: '#E84026' }] })
      .then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 1) {
          this.mgr.active().logOut().catch(() => {});
          this.nav.clear();
        }
      });
  }

  private proxyText(): string {
    const p = this.s.proxyIndex >= 0 ? this.s.proxies[this.s.proxyIndex] : undefined;
    return p ? `${p.server}:${p.port}` : (this.s.proxies.length > 0 ? '未启用' : '未设置');
  }

  @Builder
  Section(title: string) {
    Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
      .padding({ left: 18, top: 22, bottom: 8 }).width('100%')
  }

  @Builder
  Tile(glyph: Resource, tile: string) {
    Stack() {
      SymbolGlyph(glyph).fontSize(17).fontColor([Color.White])
    }
    .width(30).height(30).borderRadius(9).backgroundColor(tile)
  }

  @Builder
  Switch(p: SwitchP) {
    Row({ space: 14 }) {
      if (p.glyph) {
        this.Tile(p.glyph, p.tile ?? '#7D8A99')
      }
      Column({ space: 3 }) {
        Text(p.label).fontSize(16).fontColor($r('app.color.text_primary'))
        if (p.detail) {
          Text(p.detail).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: p.on }).selectedColor($r('app.color.accent'))
        .onChange((v: boolean) => p.fn(v))
    }
    .padding({ left: 16, right: 12, top: 11, bottom: 11 })
    .width('100%')
  }

  @Builder
  Item(p: ItemP) {
    Row({ space: 14 }) {
      if (p.glyph) {
        this.Tile(p.glyph, p.tile ?? '#7D8A99')
      }
      Text(p.label).fontSize(16).fontColor(p.color).layoutWeight(1)
      Text(p.value).fontSize(14).fontColor($r('app.color.text_secondary')).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '55%' })
      if (p.arrow) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
          .margin({ left: -6 })
      }
    }
    .padding({ left: 16, right: 14, top: p.glyph ? 11 : 14, bottom: p.glyph ? 11 : 14 })
    .width('100%')
    .onClick(() => p.fn())
  }

  // The active account, large, at the top of the page.
  @Builder
  Profile() {
    ForEach(this.accounts.filter((a: AccountRow) => a.active), (a: AccountRow) => {
      Column({ space: 6 }) {
        Avatar({ title: a.name, seed: a.userId, path: a.photo, side: 88 })
        Text(a.name).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .letterSpacing(-0.4).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 8 })
        if (a.phone) {
          Text(a.phone).fontSize(15).fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .padding({ top: 12, bottom: 4 })
      .onClick(() => {
        this.nav.push('profile').userId = this.mgr.active().myUserId;
        this.nav.commit();
      })
    }, (a: AccountRow) => `${a.slot}|${a.name}|${a.phone}|${a.photo}`)
  }

  build() {
    Column() {
      PaneHeader({ title: '设置', showBack: this.showBack, onBack: (): void => { this.nav.pop(); } })
      Scroll() {
        Column() {
          this.Profile()
          this.Section('账号')
          Column() {
            ForEach(this.accounts, (a: AccountRow) => {
              Row({ space: 12 }) {
                Avatar({ title: a.name, seed: a.userId, path: a.photo, side: 44 })
                Column() {
                  Text(a.name).fontSize(16).fontColor($r('app.color.text_primary'))
                  Text(a.phone).fontSize(12).fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (a.active) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('app.color.accent')])
                }
              }
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .width('100%')
              .onClick(() => {
                if (!a.active) {
                  this.mgr.switchTo(a.slot);
                }
              })
            }, (a: AccountRow) => `${a.slot}|${a.name}|${a.active}|${a.photo}`)
            // The main page moves to the login screen for the new account.
            this.Item({ label: '添加账号', glyph: $r('sys.symbol.person_badge_plus'), tile: '#2F6BFF', value: '', color: $r('app.color.accent'), fn: () => {
              this.mgr.add();
            } })
            this.Item({ label: '我的资料与 ID', glyph: $r('sys.symbol.person_crop_circle_fill'), tile: '#12A5BA', arrow: true, value: '', color: $r('app.color.text_primary'), fn: () => {
              this.nav.push('profile').userId = this.mgr.active().myUserId;
              this.nav.commit();
            } })
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))

          this.Section('外观与布局')
          Column() {
            this.Item({ label: '主题', glyph: $r('sys.symbol.moon_fill'), tile: '#6E5BD9', value: THEME_NAMES[Math.max(0, THEMES.indexOf(this.s.theme))], color: $r('app.color.text_primary'), fn: () => {
              pickAction(THEME_NAMES).then((index: number) => {
                this.update((s: AppSettings) => { s.theme = THEMES[index]; });
                this.mgr.applyTheme();
              }).catch(() => {});
            } })
            this.Item({ label: '折叠屏分栏', glyph: $r('sys.symbol.rectangle_split_2x1'), tile: '#2F6BFF', value: SPLIT_NAMES[Math.max(0, SPLITS.indexOf(this.s.splitMode))], color: $r('app.color.text_primary'), fn: () => {
                pickAction(SPLIT_NAMES).then((index: number) => {
                  this.update((s: AppSettings) => { s.splitMode = SPLITS[index]; });
                }).catch(() => {});
              } })
            if (this.s.listWidth > 0) {
              this.Item({ label: '恢复默认分栏宽度', glyph: $r('sys.symbol.arrow_counterclockwise'), tile: '#7D8A99', value: '也可以双击分隔条', color: $r('app.color.text_primary'), fn: () => {
                this.update((s: AppSettings) => { s.listWidth = 0; });
              } })
            }
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))

          this.Section('网络')
          Column() {
            this.Item({ label: '代理', glyph: $r('sys.symbol.wifi'), tile: '#2FAE5A', arrow: true, value: this.proxyText(), color: $r('app.color.text_primary'), fn: () => {
              this.nav.push('proxy');
              this.nav.commit();
            } })
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))

          this.Section('隐私（Nicegram 风格）')
          Column() {
            this.Switch({ label: '幽灵模式', glyph: $r('sys.symbol.eye_slash'), tile: '#4B5563', detail: '不发送已读回执和“正在输入”，并显示为离线', on: this.s.ghostMode, fn: (v: boolean) => this.update((s: AppSettings) => { s.ghostMode = v; }) })
            this.Switch({ label: '隐藏我的手机号', glyph: $r('sys.symbol.phone_fill'), tile: '#2FAE5A', detail: '在本应用界面中不显示自己的手机号', on: this.s.hidePhone, fn: (v: boolean) => this.update((s: AppSettings) => { s.hidePhone = v; }) })
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))

          this.Section('聊天')
          Column() {
            this.Switch({ label: 'Markdown 格式', glyph: $r('sys.symbol.doc_text_fill'), tile: '#12A5BA', detail: '发送时把 **粗体**、__斜体__、`代码` 转成格式文字', on: this.s.markdown, fn: (v: boolean) => this.update((s: AppSettings) => { s.markdown = v; }) })
            this.Switch({ label: '自动播放 GIF 和贴纸', glyph: $r('sys.symbol.play_fill'), tile: '#E5487A', detail: '', on: this.s.autoplayGifs, fn: (v: boolean) => this.update((s: AppSettings) => { s.autoplayGifs = v; }) })
            this.Switch({ label: '自动下载小于 10 MB 的 GIF', glyph: $r('sys.symbol.arrow_down_circle'), tile: '#F09A2E', detail: '', on: this.s.autoDownloadMedia, fn: (v: boolean) => this.update((s: AppSettings) => { s.autoDownloadMedia = v; }) })
            this.Item({ label: '消息过滤（屏蔽广告）', glyph: $r('sys.symbol.nosign'), tile: '#E5484D', arrow: true, value: this.filterText, color: $r('app.color.text_primary'), fn: () => {
              this.nav.push('filters');
              this.nav.commit();
            } })
            this.Item({ label: '翻译目标语言', glyph: $r('sys.symbol.translate'), tile: '#2F6BFF', value: LANG_NAMES[Math.max(0, LANGS.indexOf(this.s.translateTo))], color: $r('app.color.text_primary'), fn: () => {
                pickAction(LANG_NAMES).then((index: number) => {
                  this.update((s: AppSettings) => { s.translateTo = LANGS[index]; });
                }).catch(() => {});
              } })
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))

          this.Section('通知')
          Column() {
            this.Switch({ label: '消息通知', glyph: $r('sys.symbol.bell_fill'), tile: '#E5484D', detail: 'App 在前台或刚切到后台时有效，退到后台被系统冻结后无法收到', on: this.s.notifications, fn: (v: boolean) => this.update((s: AppSettings) => { s.notifications = v; }) })
            this.Switch({ label: '显示消息内容', glyph: $r('sys.symbol.message_fill'), tile: '#F09A2E', detail: '', on: this.s.notifyPreview, fn: (v: boolean) => this.update((s: AppSettings) => { s.notifyPreview = v; }) })
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))

          this.Section('设备与存储')
          Column() {
            this.Item({ label: '已登录的设备', glyph: $r('sys.symbol.rectangle_portrait'), tile: '#6E5BD9', value: this.sessions.length > 0 ? '点击其他设备可终止' : '', color: $r('app.color.text_primary'), fn: () => this.loadSessions() })
            ForEach(this.sessions, (r: SessionRow) => {
              Column({ space: 2 }) {
                Text(`${r.title}${r.current ? '（当前）' : ''}`).fontSize(15).fontColor($r('app.color.text_primary'))
                Text(r.detail).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 28, right: 16, top: 6, bottom: 6 })
              .width('100%')
              .onClick(() => {
                if (!r.current) {
                  this.terminate(r);
                }
              })
            }, (r: SessionRow) => r.id)
            this.Item({ label: '清理缓存', glyph: $r('sys.symbol.externaldrive_fill'), tile: '#12A5BA', value: this.storage, color: $r('app.color.text_primary'), fn: () => this.clearCache() })
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))

          Column() {
            this.Item({ label: '退出当前账号', value: '', color: $r('app.color.danger'), fn: () => this.logOut() })
          }
          .borderRadius(16)
          .backgroundColor($r('app.color.card'))
          .margin({ top: 16 })

          Text('TdGram 0.5 · 基于 TDLib').fontSize(12).fontColor($r('app.color.text_secondary'))
            .margin({ top: 16, bottom: 24 })
            .onClick(() => copyText(`TdGram 0.5, account ${this.mgr.active().myUserId}`))
        }
        .padding({ left: 12, right: 12 })
        .width(contentWidth(this.paneW))
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_alt'))
    .onAreaChange((_: Area, area: Area) => { this.paneW = Number(area.width); })
  }
}
