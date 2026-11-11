import { promptAction } from '@kit.ArkUI';
import { PaneHeader } from '../components/PaneHeader';
import { contentWidth } from '../common/Layout';
import { Nav } from '../common/Nav';
import { Accounts } from '../td/Accounts';
import { ProxyConfig, ProxyKind } from '../td/Proxy';
import { o, TdError, TdObject } from '../td/TdClient';

interface FieldP {
  label: string;
  value: string;
  type: InputType;
  onChange: (v: string) => void;
}

const KINDS: ProxyKind[] = ['socks5', 'http', 'mtproto'];
const KIND_NAMES: string[] = ['SOCKS5', 'HTTP', 'MTProto'];

// Proxy servers for reaching Telegram. Usable before login as well, since
// the first connection may already need one.
@Component
export struct ProxyPane {
  nav: Nav = new Nav();
  @Prop showBack: boolean = true;
  @State list: ProxyConfig[] = [];
  @State activeIndex: number = -1;
  @State pings: string[] = [];
  @State editing: number = -2; // -2 closed, -1 new, otherwise the index edited
  @State kind: number = 0;
  @State server: string = '';
  @State port: string = '1080';
  @State user: string = '';
  @State pass: string = '';
  @State secret: string = '';
  @State paneW: number = 360;
  private mgr: Accounts = Accounts.get();

  aboutToAppear(): void {
    this.sync();
  }

  private sync(): void {
    this.list = this.mgr.settings.proxies.slice();
    this.activeIndex = this.mgr.settings.proxyIndex;
    this.pings = this.list.map((): string => '');
  }

  private save(): void {
    this.mgr.saveSettings();
    this.mgr.applyProxies();
    this.sync();
  }

  private enable(index: number): void {
    this.mgr.settings.proxyIndex = index;
    this.save();
  }

  private edit(index: number): void {
    const p = index >= 0 ? this.list[index] : new ProxyConfig();
    this.kind = Math.max(0, KINDS.indexOf(p.kind));
    this.server = p.server;
    this.port = String(p.port);
    this.user = p.user;
    this.pass = p.pass;
    this.secret = p.secret;
    this.editing = index;
  }

  private commit(): void {
    const port = Number(this.port.trim());
    if (!this.server.trim() || !(port > 0 && port < 65536)) {
      promptAction.showToast({ message: '请填写服务器地址和正确的端口' });
      return;
    }
    if (KINDS[this.kind] === 'mtproto' && !this.secret.trim()) {
      promptAction.showToast({ message: 'MTProto 代理需要填写密钥' });
      return;
    }
    const p = new ProxyConfig();
    p.kind = KINDS[this.kind];
    p.server = this.server.trim();
    p.port = port;
    p.user = this.user.trim();
    p.pass = this.pass;
    p.secret = this.secret.trim();
    const s = this.mgr.settings;
    if (this.editing >= 0) {
      s.proxies[this.editing] = p;
    } else {
      s.proxies.push(p);
      // The first proxy added is switched on right away.
      if (s.proxies.length === 1) {
        s.proxyIndex = 0;
      }
    }
    this.editing = -2;
    this.save();
  }

  private remove(index: number): void {
    const s = this.mgr.settings;
    s.proxies.splice(index, 1);
    if (s.proxyIndex === index) {
      s.proxyIndex = -1;
    } else if (s.proxyIndex > index) {
      s.proxyIndex--;
    }
    this.editing = -2;
    this.save();
  }

  // Round trip to a Telegram server through the proxy (or directly).
  private ping(index: number): void {
    const req: TdObject = { '@type': 'pingProxy' };
    if (index >= 0) {
      req['proxy'] = this.list[index].toTd();
    }
    const set = (text: string): void => {
      if (index < 0) {
        promptAction.showToast({ message: `直接连接：${text}` });
        return;
      }
      const next = this.pings.slice();
      next[index] = text;
      this.pings = next;
    };
    set('测试中…');
    this.mgr.active().send(req).then((r: TdObject) => {
      set(`${Math.round((r['seconds'] as number) * 1000)} ms`);
    }).catch((e: TdError) => set(`不可用（${e.message}）`));
  }

  @Builder
  AddButton() {
    Button('添加', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => this.edit(-1))
  }

  @Builder
  Field(p: FieldP) {
    TextInput({ placeholder: p.label, text: p.value }).type(p.type).onChange((v: string) => p.onChange(v))
  }

  @Builder
  Editor() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        ForEach(KIND_NAMES, (name: string, i: number) => {
          Text(name).fontSize(14).padding({ left: 14, right: 14, top: 6, bottom: 6 }).borderRadius(16)
            .fontColor(this.kind === i ? Color.White : $r('app.color.text_primary'))
            .backgroundColor(this.kind === i ? $r('app.color.accent') : $r('app.color.chip'))
            .onClick(() => { this.kind = i; })
        }, (name: string) => name)
      }
      this.Field({ label: '服务器地址', value: this.server, type: InputType.Normal, onChange: (v: string) => { this.server = v; } })
      this.Field({ label: '端口', value: this.port, type: InputType.Number, onChange: (v: string) => { this.port = v; } })
      if (KINDS[this.kind] === 'mtproto') {
        this.Field({ label: '密钥（十六进制）', value: this.secret, type: InputType.Normal, onChange: (v: string) => { this.secret = v; } })
      } else {
        this.Field({ label: '用户名（可选）', value: this.user, type: InputType.Normal, onChange: (v: string) => { this.user = v; } })
        this.Field({ label: '密码（可选）', value: this.pass, type: InputType.Password, onChange: (v: string) => { this.pass = v; } })
      }
      Row({ space: 8 }) {
        if (this.editing >= 0) {
          Button('删除', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.danger'))
            .onClick(() => this.remove(this.editing))
        }
        Blank()
        Button('取消', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.editing = -2; })
        Button('保存').onClick(() => this.commit())
      }
      .width('100%')
    }
    .padding(14)
    .borderRadius(12)
    .backgroundColor($r('app.color.card'))
  }

  @Builder
  Entry(title: string, detail: string, index: number) {
    Row({ space: 10 }) {
      Radio({ value: `${index}`, group: 'proxy' }).checked(this.activeIndex === index).onChange((on: boolean) => {
        if (on && this.activeIndex !== index) {
          this.enable(index);
        }
      })
      Column({ space: 2 }) {
        Text(title).fontSize(16).fontColor($r('app.color.text_primary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (detail) {
          Text(detail).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        if (index >= 0) {
          this.edit(index);
        }
      })
      Button('测速', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(14).onClick(() => this.ping(index))
    }
    .padding({ left: 8, right: 4, top: 6, bottom: 6 })
    .width('100%')
  }

  build() {
    Column() {
      PaneHeader({ title: '代理', showBack: this.showBack, onBack: (): void => { this.nav.pop(); },
        trailing: (): void => this.AddButton() })
      Scroll() {
        Column({ space: 12 }) {
          Column() {
            this.Entry('不使用代理', '', -1)
            ForEach(this.list, (p: ProxyConfig, i: number) => {
              this.Entry(`${p.server}:${p.port}`,
                `${KIND_NAMES[Math.max(0, KINDS.indexOf(p.kind))]}${this.pings[i] ? ' · ' + this.pings[i] : ''}`, i)
            }, (p: ProxyConfig, i: number) => `${i}|${p.kind}|${p.server}|${p.port}|${this.pings[i]}|${this.activeIndex === i}`)
          }
          .borderRadius(12)
          .backgroundColor($r('app.color.card'))

          if (this.editing > -2) {
            this.Editor()
          }
          Text('代理对所有账号生效。点击条目可以编辑；在聊天里点 t.me/proxy 或 t.me/socks 链接也会把代理保存到这里。')
            .fontSize(12).fontColor($r('app.color.text_secondary'))
        }
        .padding(12)
        .width(contentWidth(this.paneW))
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_alt'))
    .onAreaChange((_: Area, area: Area) => { this.paneW = Number(area.width); })
  }
}
