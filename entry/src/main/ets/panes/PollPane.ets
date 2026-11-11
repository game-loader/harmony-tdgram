import { promptAction } from '@kit.ArkUI';
import { PaneHeader } from '../components/PaneHeader';
import { contentWidth } from '../common/Layout';
import { Nav, Route } from '../common/Nav';
import { Accounts } from '../td/Accounts';
import { TdError } from '../td/TdClient';

// Composes a poll for the chat (or forum topic) it was opened from.
@Component
export struct PollPane {
  nav: Nav = new Nav();
  route: Route = new Route();
  @Prop showBack: boolean = true;
  @State question: string = '';
  @State options: string[] = ['', ''];
  @State anonymous: boolean = true;
  @State multiple: boolean = false;
  @State paneW: number = 360;
  @State busy: boolean = false;

  send(): void {
    const opts = this.options.map((s: string) => s.trim()).filter((s: string) => s.length > 0);
    if (!this.question.trim() || opts.length < 2) {
      promptAction.showToast({ message: '请填写问题和至少两个选项' });
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    const store = Accounts.get().active().store(this.route.chatId, this.route.topicId);
    store.sendPoll(this.question.trim(), opts, this.anonymous, this.multiple, { replyTo: 0, silent: false })
      .then(() => {
        this.nav.pop();
      }).catch((e: TdError) => {
        this.busy = false;
        promptAction.showToast({ message: `发送失败：${e.message}` });
      });
  }

  @Builder
  SendButton() {
    Button('发送', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.send())
  }

  build() {
    Column() {
      PaneHeader({ title: '新建投票', showBack: this.showBack, onBack: (): void => { this.nav.pop(); },
        trailing: (): void => this.SendButton() })
      Scroll() {
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
            Text('匿名投票').fontSize(16).layoutWeight(1).fontColor($r('app.color.text_primary'))
            Toggle({ type: ToggleType.Switch, isOn: this.anonymous }).onChange((v: boolean) => { this.anonymous = v; })
          }
          Row() {
            Text('允许多选').fontSize(16).layoutWeight(1).fontColor($r('app.color.text_primary'))
            Toggle({ type: ToggleType.Switch, isOn: this.multiple }).onChange((v: boolean) => { this.multiple = v; })
          }
        }
        .padding(16)
        .width(contentWidth(this.paneW))
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .onAreaChange((_: Area, area: Area) => { this.paneW = Number(area.width); })
  }
}
