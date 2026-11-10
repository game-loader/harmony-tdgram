import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { Accounts } from '../td/Accounts';

interface KeyParams {
  secretChatId: number;
  title: string;
}

// Visualizes the secret chat key hash the way official clients do, so both
// sides can compare it in person to rule out a man-in-the-middle.
@Entry
@Component
struct SecretKey {
  @State cells: string[] = [];
  @State hex: string = '';
  @State title: string = '';
  @State state: string = '';

  aboutToAppear(): void {
    const p = router.getParams() as KeyParams;
    this.title = p.title;
    const s = Accounts.get().active().chats.secretChats.get(p.secretChatId);
    if (!s || !s.keyHash) {
      this.state = '密钥尚未生成';
      return;
    }
    this.state = s.state === 'ready' ? '' : '私密聊天尚未建立';
    const bytes = new util.Base64Helper().decodeSync(s.keyHash);
    // Telegram's 12x12 identicon: the first 16 bytes give 2 bits per cell.
    const palette = ['#FFFFFF', '#D5E6F3', '#2D5775', '#2F99C9'];
    const cells: string[] = [];
    for (let i = 0; i < 144; i++) {
      const bit = i * 2;
      const byte = bytes[Math.floor(bit / 8) % Math.min(bytes.length, 16)] ?? 0;
      cells.push(palette[(byte >> (bit % 8)) & 3]);
    }
    this.cells = cells;
    const parts: string[] = [];
    for (let i = 0; i < Math.min(bytes.length, 32); i++) {
      parts.push((bytes[i] < 16 ? '0' : '') + bytes[i].toString(16));
    }
    this.hex = parts.join(' ');
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => router.back())
        Text('加密密钥').fontSize(18).fontWeight(FontWeight.Medium)
      }
      .width('100%')
      if (this.state) {
        Text(this.state).fontSize(15).fontColor('#888888')
      }
      if (this.cells.length > 0) {
        Grid() {
          ForEach(this.cells, (c: string, i: number) => {
            GridItem() {
              Column().width('100%').height('100%').backgroundColor(c)
            }
          }, (c: string, i: number) => `${i}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
        .rowsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
        .width(240)
        .height(240)
        Text(this.hex).fontSize(14).fontFamily('monospace').textAlign(TextAlign.Center).padding({ left: 24, right: 24 })
        Text(`如果这张图片与 ${this.title} 设备上显示的一致，你们的私密聊天就是端到端加密的，没有被第三方截获。`)
          .fontSize(14).fontColor('#555555').padding({ left: 24, right: 24 }).textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
