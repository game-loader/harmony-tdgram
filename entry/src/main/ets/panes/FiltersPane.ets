import { promptAction } from '@kit.ArkUI';
import { PaneHeader } from '../components/PaneHeader';
import { compilePattern } from '../common/Filter';
import { contentWidth } from '../common/Layout';
import { Nav } from '../common/Nav';
import { formatDay } from '../common/Util';
import { pickAction } from '../common/Menu';
import { Accounts } from '../td/Accounts';
import { DEFAULT_AI_MODEL, DEFAULT_AI_URL, FilterConfig, FilterEntry, Filters } from '../td/Filters';

interface SwitchP {
  label: string;
  detail: string;
  on: boolean;
  fn: (v: boolean) => void;
}

interface FieldP {
  label: string;
  value: string;
  secret: boolean;
  onChange: (v: string) => void;
}

interface RemovableP {
  title: string;
  detail: string;
  fn: () => void;
}

const MODES: string[] = ['collapse', 'hide'];
const MODE_NAMES: string[] = ['折叠成一行（点击可查看）', '完全隐藏'];
const THRESHOLDS: number[] = [0.5, 0.6, 0.7, 0.8, 0.9, 0.95];
const THRESHOLD_NAMES: string[] = ['50%（最严，容易误伤）', '60%', '70%', '80%（推荐）', '90%', '95%（最松，只过滤很明显的）'];

// Message filters: blocked messages, keyword rules and the AI classifier.
@Component
export struct FiltersPane {
  nav: Nav = new Nav();
  @Prop showBack: boolean = true;
  @State cfg: FilterConfig = new FilterConfig();
  @State newRule: string = '';
  @State aiUrl: string = '';
  @State aiKey: string = '';
  @State aiModel: string = '';
  @State status: string = '';
  @State testing: boolean = false;
  @State testResult: string = '';
  @State paneW: number = 360;
  private filters: Filters = Filters.get();
  private listener = (): void => this.sync();
  private commitTimer: number = -1;

  aboutToAppear(): void {
    const c = this.filters.config;
    this.aiUrl = c.aiUrl;
    this.aiKey = c.aiKey;
    this.aiModel = c.aiModel;
    this.sync();
    this.filters.on(this.listener);
  }

  aboutToDisappear(): void {
    this.filters.off(this.listener);
    clearTimeout(this.commitTimer);
    this.commitAi();
  }

  private sync(): void {
    // A fresh object so @State notices the change.
    this.cfg = FilterConfig.from(this.filters.config);
    const f = this.filters;
    const parts: string[] = [];
    if (f.aiError) {
      parts.push(`最近的错误：${f.aiError}`);
    }
    if (f.aiLeft) {
      parts.push(`剩余额度 ${f.aiLeft} tokens`);
    }
    parts.push(`已记住 ${f.verdictCount()} 条判断`);
    this.status = parts.join(' · ');
  }

  private update(fn: (c: FilterConfig) => void): void {
    this.filters.update(fn);
  }

  // Address, key and model are typed freely and applied when editing ends.
  private commitAi(): void {
    const c = this.filters.config;
    const url = this.aiUrl.trim() || DEFAULT_AI_URL;
    const model = this.aiModel.trim() || DEFAULT_AI_MODEL;
    const key = this.aiKey.trim();
    if (c.aiUrl !== url || c.aiKey !== key || c.aiModel !== model) {
      this.update((f: FilterConfig) => {
        f.aiUrl = url;
        f.aiKey = key;
        f.aiModel = model;
      });
    }
  }

  private addRule(): void {
    const v = this.newRule.trim();
    if (!v) {
      return;
    }
    if (!compilePattern(v).valid) {
      promptAction.showToast({ message: '规则无效：正则写成 /表达式/，且必须能通过编译' });
      return;
    }
    if (!this.cfg.rules.includes(v)) {
      this.update((f: FilterConfig) => { f.rules.push(v); });
    }
    this.newRule = '';
  }

  private test(): void {
    this.commitAi();
    this.testing = true;
    this.testResult = '';
    this.filters.test().then((text: string) => {
      this.testing = false;
      this.testResult = text;
      this.sync();
    });
  }

  private chatTitle(id: number): string {
    const c = Accounts.get().active().chat(id);
    return c ? c.title : `聊天 ${id}`;
  }

  private entryDetail(e: FilterEntry): string {
    return `${e.chatId ? '仅在 ' + (e.chatTitle || this.chatTitle(e.chatId)) : '所有聊天'}${e.date ? ' · ' + formatDay(e.date) : ''}`;
  }

  @Builder
  Section(title: string) {
    Text(title).fontSize(13).fontColor($r('app.color.accent')).padding({ left: 16, top: 16, bottom: 6 }).width('100%')
  }

  @Builder
  Hint(text: string) {
    Text(text).fontSize(12).fontColor($r('app.color.text_secondary')).padding({ left: 16, right: 16, top: 6 })
      .width('100%')
  }

  @Builder
  Switch(p: SwitchP) {
    Row() {
      Column({ space: 2 }) {
        Text(p.label).fontSize(16).fontColor($r('app.color.text_primary'))
        if (p.detail) {
          Text(p.detail).fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: p.on }).onChange((v: boolean) => p.fn(v))
    }
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
    .width('100%')
  }

  @Builder
  Field(p: FieldP) {
    Column({ space: 4 }) {
      Text(p.label).fontSize(12).fontColor($r('app.color.text_secondary'))
      TextInput({ text: p.value }).type(p.secret ? InputType.Password : InputType.Normal)
        .onChange((v: string) => {
          p.onChange(v);
          // Saved shortly after typing stops, so nothing is lost if the pane
          // is left without the field losing focus.
          clearTimeout(this.commitTimer);
          this.commitTimer = setTimeout((): void => this.commitAi(), 900);
        })
        .onBlur(() => this.commitAi())
        .onSubmit(() => this.commitAi())
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .width('100%')
  }

  @Builder
  Removable(p: RemovableP) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(p.title).fontSize(15).fontColor($r('app.color.text_primary')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (p.detail) {
          Text(p.detail).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Button('移除', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(14).fontColor($r('app.color.danger'))
        .onClick(() => p.fn())
    }
    .padding({ left: 16, right: 4, top: 6, bottom: 6 })
    .width('100%')
  }

  build() {
    Column() {
      PaneHeader({ title: '消息过滤', showBack: this.showBack, onBack: (): void => { this.nav.pop(); } })
      Scroll() {
        Column() {
          Column() {
            this.Switch({ label: '启用消息过滤', detail: '过滤只在本机生效，不会删除消息，也不影响其他设备', on: this.cfg.enabled,
              fn: (v: boolean) => this.update((f: FilterConfig) => { f.enabled = v; }) })
            Row({ space: 8 }) {
              Text('被过滤的消息').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text(MODE_NAMES[Math.max(0, MODES.indexOf(this.cfg.mode))]).fontSize(14)
                .fontColor($r('app.color.text_secondary'))
            }
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .width('100%')
            .onClick(() => {
              pickAction(MODE_NAMES).then((index: number) => {
                this.update((f: FilterConfig) => { f.mode = index === 1 ? 'hide' : 'collapse'; });
              }).catch(() => {});
            })
          }
          .borderRadius(12)
          .backgroundColor($r('app.color.card'))
          .margin({ top: 12 })

          this.Section(`已屏蔽的消息（${this.cfg.entries.length}）`)
          Column() {
            if (this.cfg.entries.length === 0) {
              Text('还没有').fontSize(14).fontColor($r('app.color.text_secondary')).padding(16).width('100%')
            }
            ForEach(this.cfg.entries, (e: FilterEntry) => {
              this.Removable({ title: e.sample, detail: this.entryDetail(e), fn: () => {
                this.update((f: FilterConfig) => {
                  f.entries = f.entries.filter((x: FilterEntry) => !(x.sig === e.sig && x.chatId === e.chatId));
                });
              } })
            }, (e: FilterEntry) => `${e.sig}|${e.chatId}`)
          }
          .borderRadius(12)
          .backgroundColor($r('app.color.card'))
          this.Hint('在聊天里长按一条消息，选“屏蔽相同内容的消息”；或多选几条后点“屏蔽”。以后内容相同的消息（忽略空格、标点和表情的差别）都会被过滤，转发来的也一样。')

          this.Section('关键词规则')
          Column() {
            this.Switch({ label: '内置规则', detail: '过滤带 #广告 #推广 #赞助 #AD #sponsored 等标签，或以“广告：”“推广：”开头的消息',
              on: this.cfg.presets, fn: (v: boolean) => this.update((f: FilterConfig) => { f.presets = v; }) })
            ForEach(this.cfg.rules, (r: string) => {
              this.Removable({ title: r, detail: '', fn: () => {
                this.update((f: FilterConfig) => { f.rules = f.rules.filter((x: string) => x !== r); });
              } })
            }, (r: string) => r)
            Row({ space: 8 }) {
              TextInput({ placeholder: '关键词，或 /正则/', text: this.newRule }).layoutWeight(1)
                .onChange((v: string) => { this.newRule = v; })
                .onSubmit(() => this.addRule())
              Button('添加').onClick(() => this.addRule())
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 10 })
            .width('100%')
          }
          .borderRadius(12)
          .backgroundColor($r('app.color.card'))
          this.Hint('消息的文字、按钮文字或链接里包含关键词（不分大小写）就会被过滤。例：t.me/some_channel、/加入.{0,6}(群|频道)/')

          this.Section('AI 识别广告')
          Column() {
            this.Switch({ label: '用 AI 判断', detail: '没见过的广告也能认出来。打开聊天或弹通知时才提问，相同内容只问一次', on: this.cfg.aiEnabled,
              fn: (v: boolean) => this.update((f: FilterConfig) => { f.aiEnabled = v; }) })
            if (this.cfg.aiEnabled) {
              this.Field({ label: '接口地址', value: this.aiUrl, secret: false, onChange: (v: string) => { this.aiUrl = v; } })
              this.Field({ label: 'API Key', value: this.aiKey, secret: true, onChange: (v: string) => { this.aiKey = v; } })
              this.Field({ label: '模型', value: this.aiModel, secret: false, onChange: (v: string) => { this.aiModel = v; } })
              Row({ space: 8 }) {
                Text('判定为广告的把握').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
                Text(`≥ ${Math.round(this.cfg.aiThreshold * 100)}%`).fontSize(14).fontColor($r('app.color.text_secondary'))
              }
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .width('100%')
              .onClick(() => {
                pickAction(THRESHOLD_NAMES).then((index: number) => {
                  this.update((f: FilterConfig) => { f.aiThreshold = THRESHOLDS[index]; });
                }).catch(() => {});
              })
              this.Switch({ label: '所有频道', detail: '关闭时只判断下面列出的聊天', on: this.cfg.aiChannels,
                fn: (v: boolean) => this.update((f: FilterConfig) => { f.aiChannels = v; }) })
              ForEach(this.cfg.aiChats, (id: number) => {
                this.Removable({ title: this.chatTitle(id), detail: '', fn: () => {
                  this.update((f: FilterConfig) => { f.aiChats = f.aiChats.filter((x: number) => x !== id); });
                } })
              }, (id: number) => `${id}`)
              Row({ space: 8 }) {
                Button(this.testing ? '测试中…' : '测试连接', { buttonStyle: ButtonStyleMode.TEXTUAL }).enabled(!this.testing)
                  .onClick(() => this.test())
                Blank()
                Button('清除记住的判断', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
                  this.filters.clearVerdicts();
                  promptAction.showToast({ message: '已清除，消息会重新判断' });
                })
              }
              .padding({ left: 8, right: 8 })
              .width('100%')
              if (this.testResult) {
                Text(this.testResult).fontSize(13).fontColor($r('app.color.text_primary'))
                  .padding({ left: 16, right: 16, bottom: 6 }).width('100%')
              }
              Text(this.status).fontSize(12).fontColor($r('app.color.text_secondary'))
                .padding({ left: 16, right: 16, bottom: 12 }).width('100%')
            }
          }
          .borderRadius(12)
          .backgroundColor($r('app.color.card'))
          this.Hint('开启后，所选聊天里收到的消息的文字、按钮文字和链接会发送到上面的接口地址，由它判断是不是广告；私密聊天从不发送，图片和文件也不发送。' +
            '请求走系统网络或系统代理；应用内设置的代理只有 HTTP 类型会被用上。要单独开启某个聊天：打开它，点右上角菜单里的“用 AI 识别这个聊天里的广告”。默认地址是 Jev（jevmodel.org）的接口，Key 在它的网站上创建，只保存在本机。')
          Blank().height(24)
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
