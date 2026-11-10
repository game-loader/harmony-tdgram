import { router, promptAction } from '@kit.ArkUI';
import { Avatar } from '../components/Avatar';
import { copyText } from '../common/AppState';
import { formatSize } from '../common/Util';
import { pickAction } from '../common/Menu';
import { Account } from '../td/Account';
import { Accounts, Settings as AppSettings } from '../td/Accounts';
import { o, TdError, TdObject } from '../td/TdClient';

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

@Entry
@Component
struct Settings {
  @State accounts: AccountRow[] = [];
  @State s: AppSettings = new AppSettings();
  @State sessions: SessionRow[] = [];
  @State storage: string = '';
  private mgr: Accounts = Accounts.get();

  aboutToAppear(): void {
    this.s = this.mgr.settings;
    this.refreshAccounts();
    this.loadStorage();
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
    const copy = new AppSettings();
    copy.ghostMode = this.mgr.settings.ghostMode;
    copy.hidePhone = this.mgr.settings.hidePhone;
    copy.markdown = this.mgr.settings.markdown;
    copy.notifications = this.mgr.settings.notifications;
    copy.notifyPreview = this.mgr.settings.notifyPreview;
    copy.translateTo = this.mgr.settings.translateTo;
    copy.autoplayGifs = this.mgr.settings.autoplayGifs;
    copy.autoDownloadMedia = this.mgr.settings.autoDownloadMedia;
    this.s = copy;
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
    }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  private terminate(row: SessionRow): void {
    promptAction.showDialog({ title: `终止“${row.title}”？`,
      buttons: [{ text: '取消', color: '#888888' }, { text: '终止', color: '#E84026' }] })
      .then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 1) {
          this.mgr.active().send(o({ '@type': 'terminateSession', 'session_id': row.id }))
            .then(() => this.loadSessions()).catch((e: TdError) => promptAction.showToast({ message: e.message }));
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
      promptAction.showToast({ message: '缓存已清理' });
      this.loadStorage();
    }).catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  private logOut(): void {
    promptAction.showDialog({ title: '退出当前账号？',
      buttons: [{ text: '取消', color: '#888888' }, { text: '退出', color: '#E84026' }] })
      .then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 1) {
          this.mgr.active().logOut().catch(() => {});
          router.back();
        }
      });
  }

  @Builder
  Section(title: string) {
    Text(title).fontSize(13).fontColor('#3A8DDE').padding({ left: 16, top: 16, bottom: 6 }).width('100%')
  }

  @Builder
  Switch(label: string, detail: string, on: boolean, fn: (v: boolean) => void) {
    Row() {
      Column({ space: 2 }) {
        Text(label).fontSize(16)
        if (detail) {
          Text(detail).fontSize(12).fontColor('#888888')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: on }).onChange(fn)
    }
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
    .width('100%')
  }

  @Builder
  Item(label: string, value: string, color: ResourceColor, fn: () => void) {
    Row() {
      Text(label).fontSize(16).fontColor(color).layoutWeight(1)
      Text(value).fontSize(14).fontColor('#888888')
    }
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .width('100%')
    .onClick(fn)
  }
  build() {
    Column() {
      Row({ space: 8 }) {
        Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => router.back())
        Text('设置').fontSize(20).fontWeight(FontWeight.Bold)
      }
      .width('100%')
      Scroll() {
        Column() {
          this.Section('账号')
          Column() {
            ForEach(this.accounts, (a: AccountRow) => {
              Row({ space: 12 }) {
                Avatar({ title: a.name, seed: a.userId, path: a.photo, side: 44 })
                Column() {
                  Text(a.name).fontSize(16)
                  Text(a.phone).fontSize(12).fontColor('#888888')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (a.active) {
                  Text('✓').fontSize(18).fontColor('#3A8DDE')
                }
              }
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .width('100%')
              .onClick(() => {
                if (!a.active) {
                  this.mgr.switchTo(a.slot);
                  router.back();
                }
              })
            }, (a: AccountRow) => `${a.slot}|${a.name}|${a.active}|${a.photo}`)
            this.Item('＋ 添加账号', '', '#3A8DDE', () => {
              this.mgr.add();
              router.replaceUrl({ url: 'pages/Login' });
            })
            this.Item('我的资料与 ID', '', $r('sys.color.ohos_id_color_text_primary'), () => {
              router.pushUrl({ url: 'pages/Profile', params: { userId: this.mgr.active().myUserId } });
            })
          }
          .backgroundColor($r('sys.color.ohos_id_color_card_bg'))

          this.Section('隐私（Nicegram 风格）')
          Column() {
            this.Switch('幽灵模式', '不发送已读回执和“正在输入”，并显示为离线', this.s.ghostMode,
              (v: boolean) => this.update((s: AppSettings) => { s.ghostMode = v; }))
            this.Switch('隐藏我的手机号', '在本应用界面中不显示自己的手机号', this.s.hidePhone,
              (v: boolean) => this.update((s: AppSettings) => { s.hidePhone = v; }))
          }
          .backgroundColor($r('sys.color.ohos_id_color_card_bg'))

          this.Section('聊天')
          Column() {
            this.Switch('Markdown 格式', '发送时把 **粗体**、__斜体__、`代码` 转成格式文字', this.s.markdown,
              (v: boolean) => this.update((s: AppSettings) => { s.markdown = v; }))
            this.Switch('自动播放 GIF 和贴纸', '', this.s.autoplayGifs,
              (v: boolean) => this.update((s: AppSettings) => { s.autoplayGifs = v; }))
            this.Switch('自动下载小于 10 MB 的 GIF', '', this.s.autoDownloadMedia,
              (v: boolean) => this.update((s: AppSettings) => { s.autoDownloadMedia = v; }))
            this.Item('翻译目标语言', LANG_NAMES[Math.max(0, LANGS.indexOf(this.s.translateTo))],
              $r('sys.color.ohos_id_color_text_primary'), () => {
                pickAction(LANG_NAMES).then((index: number) => {
                  this.update((s: AppSettings) => { s.translateTo = LANGS[index]; });
                }).catch(() => {});
              })
          }
          .backgroundColor($r('sys.color.ohos_id_color_card_bg'))

          this.Section('通知')
          Column() {
            this.Switch('消息通知', 'App 在前台或刚切到后台时有效，退到后台被系统冻结后无法收到', this.s.notifications,
              (v: boolean) => this.update((s: AppSettings) => { s.notifications = v; }))
            this.Switch('显示消息内容', '', this.s.notifyPreview,
              (v: boolean) => this.update((s: AppSettings) => { s.notifyPreview = v; }))
          }
          .backgroundColor($r('sys.color.ohos_id_color_card_bg'))

          this.Section('设备与存储')
          Column() {
            this.Item('已登录的设备', '', $r('sys.color.ohos_id_color_text_primary'), () => this.loadSessions())
            ForEach(this.sessions, (r: SessionRow) => {
              Column({ space: 2 }) {
                Text(`${r.title}${r.current ? '（当前）' : ''}`).fontSize(15)
                Text(r.detail).fontSize(12).fontColor('#888888')
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
            this.Item('清理缓存', this.storage, $r('sys.color.ohos_id_color_text_primary'), () => this.clearCache())
          }
          .backgroundColor($r('sys.color.ohos_id_color_card_bg'))

          Column() {
            this.Item('退出当前账号', '', '#E84026', () => this.logOut())
          }
          .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
          .margin({ top: 16 })

          Text('TdGram 1.0 · 基于 TDLib').fontSize(12).fontColor('#888888').margin({ top: 16, bottom: 24 })
            .onClick(() => copyText(`TdGram 1.0, account ${this.mgr.active().myUserId}`))
        }
        .width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}
