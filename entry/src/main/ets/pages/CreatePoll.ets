import { router, promptAction } from '@kit.ArkUI';
import { Accounts } from '../td/Accounts';
import { TdError } from '../td/TdClient';

interface PollParams {
  chatId: number;
}

@Entry
@Component
struct CreatePoll {
  @State question: string = '';
  @State options: string[] = ['', ''];
  @State anonymous: boolean = true;
  @State multiple: boolean = false;
  private chatId: number = 0;

  aboutToAppear(): void {
    this.chatId = (router.getParams() as PollParams).chatId;
  }

  send(): void {
    const opts = this.options.map((s: string) => s.trim()).filter((s: string) => s.length > 0);
    if (!this.question.trim() || opts.length < 2) {
      promptAction.showToast({ message: '请填写问题和至少两个选项' });
      return;
    }
    const acc = Accounts.get().active();
    // The chat page left this chat open in the message store.
    if (acc.messages.chatId !== this.chatId) {
      router.back();
      return;
    }
    acc.messages.sendPoll(this.question.trim(), opts, this.anonymous, this.multiple, { replyTo: 0, silent: false })
      .then(() => router.back())
      .catch((e: TdError) => promptAction.showToast({ message: e.message }));
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => router.back())
        Text('新建投票').fontSize(18).fontWeight(FontWeight.Medium).layoutWeight(1)
        Button('发送', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.send())
      }
      .width('100%')
      Column({ space: 8 }) {
        TextInput({ placeholder: '问题', text: this.question }).onChange((v: string) => { this.question = v; })
        ForEach(this.options, (op: string, i: number) => {
          TextInput({ placeholder: `选项 ${i + 1}`, text: op }).onChange((v: string) => {
            const next = this.options.slice();
            next[i] = v;
            if (i === next.length - 1 && v && next.length < 10) {
              next.push('');
            }
            this.options = next;
          })
        }, (op: string, i: number) => `${i}`)
        Row() {
          Text('匿名投票').fontSize(16).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.anonymous }).onChange((v: boolean) => { this.anonymous = v; })
        }
        Row() {
          Text('允许多选').fontSize(16).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.multiple }).onChange((v: boolean) => { this.multiple = v; })
        }
      }
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
