import { router } from '@kit.ArkUI';
import { QrView } from '../components/QrView';
import { ProxyPane } from '../panes/ProxyPane';
import { Nav } from '../common/Nav';
import { Account } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { AccountEvent } from '../td/Core';
import { TdError } from '../td/TdClient';

@Entry
@Component
struct Login {
  @State step: string = 'loading';
  @State hint: string = '';
  @State input: string = '';
  @State error: string = '';
  @State busy: boolean = false;
  @State qrLink: string = '';
  @State canCancel: boolean = false;
  @State showProxy: boolean = false;
  @State proxyText: string = '';
  @State connection: string = '';
  @State winW: number = 360;
  @State winH: number = 700;
  private store: Account = Accounts.get().active();
  private listener = (e: AccountEvent): void => this.onStore(e);
  private proxyNav: Nav = new Nav();
  private managerListener = (): void => {
    const active = Accounts.get().active();
    if (active !== this.store) {
      this.store.off(this.listener);
      this.store = active;
      this.store.on(this.listener);
      this.sync();
      this.refreshProxy();
    }
  };

  aboutToAppear(): void {
    this.proxyNav.onEmptyPop = (): void => this.closeProxy();
    this.store.on(this.listener);
    Accounts.get().on(this.managerListener);
    this.canCancel = Accounts.get().all().some((a: Account) => a.authStep === 'ready');
    this.sync();
    this.refreshProxy();
  }

  aboutToDisappear(): void {
    this.store.off(this.listener);
    Accounts.get().off(this.managerListener);
  }

  onBackPress(): boolean {
    if (this.showProxy) {
      this.closeProxy();
      return true;
    }
    return false;
  }

  onStore(e: AccountEvent): void {
    if (e === 'auth') {
      this.sync();
    } else if (e === 'connection') {
      this.refreshProxy();
    }
  }

  private refreshProxy(): void {
    const s = Accounts.get().settings;
    const p = s.proxyIndex >= 0 ? s.proxies[s.proxyIndex] : undefined;
    this.proxyText = p ? `代理：${p.server}:${p.port}` : '设置代理';
    const c = this.store.connection;
    this.connection = c === 'ready' || c === 'updating' ? '' : (c === 'waiting' ? '等待网络…' :
      (c === 'proxy' ? '正在连接代理…' : '正在连接 Telegram…'));
  }

  private closeProxy(): void {
    this.showProxy = false;
    this.refreshProxy();
  }

  sync(): void {
    if (this.step !== this.store.authStep) {
      this.input = '';
      this.error = '';
    }
    this.step = this.store.authStep;
    this.hint = this.store.authHint;
    if (this.step === 'ready') {
      router.replaceUrl({ url: 'pages/Main' });
    } else if (this.step === 'qr') {
      this.qrLink = this.store.qrLink;
    }
  }

  submit(): void {
    const v = this.input.trim();
    if (!v || this.busy) {
      return;
    }
    this.busy = true;
    this.error = '';
    let p: Promise<Object>;
    if (this.step === 'phone') {
      p = this.store.submitPhone(v.replace(/[\s-]/g, ''));
    } else if (this.step === 'code') {
      p = this.store.submitCode(v);
    } else {
      p = this.store.submitPassword(v);
    }
    p.catch((e: TdError) => {
      this.error = e.message;
    }).finally(() => {
      this.busy = false;
    });
  }

  title(): string {
    switch (this.step) {
      case 'phone': return '手机号登录';
      case 'code': return '输入验证码';
      case 'password': return '两步验证密码';
      case 'qr': return '扫码登录';
      case 'email': return '需要邮箱验证';
      case 'closed': return '无法继续';
      default: return '正在连接…';
    }
  }

  placeholder(): string {
    switch (this.step) {
      case 'phone': return '国际格式，例如 +8613800138000';
      case 'code': return '验证码';
      default: return this.hint ? `密码提示：${this.hint}` : '密码';
    }
  }

  // QR side that fits beside or above the instructions.
  private qrSide(): number {
    return Math.round(Math.min(240, Math.max(140, Math.min(this.winW, this.winH) - 220)));
  }

  @Builder
  Form() {
    Column({ space: 14 }) {
      Text(this.title()).fontSize(20).fontColor($r('app.color.text_primary'))
      if (this.step === 'phone' || this.step === 'code' || this.step === 'password') {
        if (this.step === 'code' && this.hint) {
          Text(this.hint).fontSize(14).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
        }
        TextInput({ placeholder: this.placeholder(), text: this.input })
          .type(this.step === 'password' ? InputType.Password :
            (this.step === 'code' ? InputType.Number : InputType.PhoneNumber))
          .onChange((v: string) => { this.input = v; })
          .onSubmit(() => this.submit())
        Button(this.busy ? '请稍候…' : '下一步').width('100%').enabled(!this.busy).onClick(() => this.submit())
        if (this.step === 'phone') {
          Button('改用二维码登录', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .onClick(() => {
              this.store.requestQrLogin().catch((e: TdError) => { this.error = e.message; });
            })
        }
      } else if (this.step === 'qr') {
        Text('在已登录的手机上打开 Telegram：设置 > 设备 > 连接桌面设备，扫描二维码')
          .fontSize(14).textAlign(TextAlign.Center).fontColor($r('app.color.text_secondary'))
        QrView({ text: this.qrLink, side: this.qrSide() })
      } else if (this.step === 'email' || this.step === 'closed') {
        Text(this.hint || '会话已关闭，请重启应用').fontSize(14).textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_secondary'))
      } else {
        LoadingProgress().width(44).height(44).color($r('app.color.accent'))
      }
      if (this.connection) {
        Text(this.connection).fontSize(13).fontColor($r('app.color.accent'))
      }
      if (this.error) {
        Text(this.error).fontSize(14).fontColor($r('app.color.danger')).textAlign(TextAlign.Center)
      }
      Button(this.proxyText, { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.showProxy = true; })
      if (this.canCancel && this.step !== 'ready') {
        Button('返回已登录的账号', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          const ready = Accounts.get().all().find((a: Account) => a.authStep === 'ready');
          if (ready) {
            Accounts.get().switchTo(ready.slot);
            router.replaceUrl({ url: 'pages/Main' });
          }
        })
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 400 })
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 16 }) {
          Text('TdGram').fontSize(32).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            .margin({ top: Math.max(16, Math.min(80, this.winH * 0.1)) })
          this.Form()
        }
        .padding(24)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      if (this.showProxy) {
        Column() {
          ProxyPane({ nav: this.proxyNav, showBack: true })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .onAreaChange((_: Area, area: Area) => {
      this.winW = Number(area.width);
      this.winH = Number(area.height);
    })
  }
}
