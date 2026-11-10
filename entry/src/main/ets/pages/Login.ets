import { router } from '@kit.ArkUI';
import { QrView } from '../components/QrView';
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
  private store: Account = Accounts.get().active();
  private listener = (e: AccountEvent): void => this.onStore(e);

  aboutToAppear(): void {
    this.store.on(this.listener);
    this.canCancel = Accounts.get().all().some((a: Account) => a.authStep === 'ready');
    this.sync();
  }

  aboutToDisappear(): void {
    this.store.off(this.listener);
  }

  onStore(e: AccountEvent): void {
    if (e === 'auth') {
      this.sync();
    }
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

  build() {
    Column({ space: 16 }) {
      Text('TdGram').fontSize(32).fontWeight(FontWeight.Bold).margin({ top: 80 })
      Text(this.title()).fontSize(20)
      if (this.step === 'phone' || this.step === 'code' || this.step === 'password') {
        if (this.step === 'code' && this.hint) {
          Text(this.hint).fontSize(14).fontColor($r('sys.color.ohos_id_color_text_secondary'))
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
        Text('在已登录的手机上打开 Telegram：设置 > 设备 > 连接桌面设备，扫描下方二维码')
          .fontSize(14).textAlign(TextAlign.Center)
        QrView({ text: this.qrLink, side: 240 })
      } else if (this.step === 'closed') {
        Text(this.hint || '会话已关闭，请重启应用').fontSize(14).textAlign(TextAlign.Center)
      } else {
        LoadingProgress().width(48).height(48)
      }
      if (this.canCancel && this.step !== 'ready') {
        Button('返回已登录的账号', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          const ready = Accounts.get().all().find((a: Account) => a.authStep === 'ready');
          if (ready) {
            Accounts.get().switchTo(ready.slot);
            router.replaceUrl({ url: 'pages/Main' });
          }
        })
      }
      if (this.error) {
        Text(this.error).fontSize(14).fontColor(Color.Red)
      }
    }
    .padding(24)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
