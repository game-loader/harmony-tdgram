import { Account } from '../td/Account';
import { MsgItem } from '../td/Models';
import { fillSticker } from '../td/Parse';
import { o, TdObject } from '../td/TdClient';
import { StickerView } from './StickerView';

const EMOJI: string[] = ('😀 😃 😄 😁 😆 😅 😂 🤣 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🤩 🥳 ' +
  '😏 😒 😞 😔 😟 😕 🙁 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🤭 🤫 🤥 😶 😐 ' +
  '😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 🤑 🤠 😈 👿 👹 👺 🤡 💩 👻 💀 👽 🤖 🎃 ' +
  '👍 👎 👌 ✌ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝ ✋ 🤚 🖐 🖖 👋 🤝 🙏 💪 👏 🙌 👐 🤲 ❤ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ' +
  '💯 💢 💥 💫 💦 💨 🔥 ✨ 🎉 🎊 🎁 🌹 🌸 🌞 🌙 ⭐ ⚡ ☔ ❄ ☕ 🍺 🍻 🥂 🍰 🎂 🍉 🍎 🐶 🐱 🐼 🐷 🐸 🐵').split(' ');

class StickerCell {
  fileId: number = 0;
  path: string = '';
  thumb: string = '';
  format: string = 'webp';
}

class StickerSetTab {
  id: string = '';
  title: string = '';
  thumb: string = '';
}

@Component
export struct StickerPanel {
  account: Account | null = null;
  onEmoji: (e: string) => void = () => {};
  onSticker: (fileId: number) => void = () => {};
  onGif: (fileId: number) => void = () => {};
  @State tab: number = 0; // 0 emoji, 1 stickers, 2 gifs
  @State sets: StickerSetTab[] = [];
  @State setIndex: number = 0;
  @State cells: StickerCell[] = [];
  @State gifs: StickerCell[] = [];
  private filesListener = (): void => this.refreshPaths();

  aboutToAppear(): void {
    this.account?.on(this.filesListener);
    this.loadSets();
  }

  aboutToDisappear(): void {
    this.account?.off(this.filesListener);
  }

  private refreshPaths(): void {
    const files = this.account!.files;
    this.cells = this.cells.map((c: StickerCell) => {
      const n = new StickerCell();
      n.fileId = c.fileId;
      n.format = c.format;
      n.path = c.path || files.known(c.fileId);
      n.thumb = c.thumb;
      return n;
    });
    this.gifs = this.gifs.map((c: StickerCell) => {
      const n = new StickerCell();
      n.fileId = c.fileId;
      n.format = c.format;
      n.path = c.path || files.known(c.fileId);
      n.thumb = c.thumb;
      return n;
    });
  }

  private toCells(stickers: TdObject[]): StickerCell[] {
    const files = this.account!.files;
    return stickers.map((s: TdObject) => {
      const m = new MsgItem();
      fillSticker(m, s);
      const c = new StickerCell();
      c.fileId = m.fileId;
      c.format = m.stickerFormat;
      c.path = m.filePath || files.path(m.fileId, 4);
      c.thumb = m.thumbPath || files.path(m.thumbFileId, 8);
      return c;
    });
  }

  private loadSets(): void {
    const acc = this.account!;
    const recent = new StickerSetTab();
    recent.id = 'recent';
    recent.title = '🕓';
    acc.send(o({ '@type': 'getInstalledStickerSets', 'sticker_type': o({ '@type': 'stickerTypeRegular' }) }))
      .then((r: TdObject) => {
        const tabs: StickerSetTab[] = [recent];
        for (const s of (r['sets'] as TdObject[]) ?? []) {
          const t = new StickerSetTab();
          t.id = String(s['id']);
          t.title = s['title'] as string;
          tabs.push(t);
        }
        this.sets = tabs;
        this.selectSet(0);
      }).catch(() => {
        this.sets = [recent];
        this.selectSet(0);
      });
  }

  selectSet(i: number): void {
    this.setIndex = i;
    const acc = this.account!;
    const tab = this.sets[i];
    const req = tab.id === 'recent' ? o({ '@type': 'getRecentStickers', 'is_attached': false }) :
      o({ '@type': 'getStickerSet', 'set_id': tab.id });
    acc.send(req).then((r: TdObject) => {
      this.cells = this.toCells((r['stickers'] as TdObject[]) ?? []);
    }).catch(() => {
      this.cells = [];
    });
  }

  private loadGifs(): void {
    const acc = this.account!;
    acc.send(o({ '@type': 'getSavedAnimations' })).then((r: TdObject) => {
      const files = acc.files;
      this.gifs = ((r['animations'] as TdObject[]) ?? []).map((a: TdObject) => {
        const c = new StickerCell();
        const f = a['animation'] as TdObject;
        c.fileId = f['id'] as number;
        c.path = files.path(c.fileId, 4);
        const th = a['thumbnail'] as TdObject | undefined;
        c.thumb = th ? files.path((th['file'] as TdObject)['id'] as number, 8) : '';
        return c;
      });
    }).catch(() => {});
  }

  @Builder
  TabBar() {
    Row() {
      ForEach(['😀 表情', '🧩 贴纸', 'GIF'], (t: string, i: number) => {
        Text(t).fontSize(14).layoutWeight(1).textAlign(TextAlign.Center).padding(8)
          .fontColor(this.tab === i ? '#3A8DDE' : '#666666')
          .border({ width: { bottom: this.tab === i ? 2 : 0 }, color: { bottom: '#3A8DDE' } })
          .onClick(() => {
            this.tab = i;
            if (i === 2 && this.gifs.length === 0) {
              this.loadGifs();
            }
          })
      }, (t: string) => t)
    }
    .width('100%')
  }

  build() {
    Column() {
      this.TabBar()
      if (this.tab === 0) {
        Grid() {
          ForEach(EMOJI, (e: string) => {
            GridItem() {
              Text(e).fontSize(28).onClick(() => this.onEmoji(e))
            }
          }, (e: string) => e)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
        .rowsGap(6)
        .height(260)
      } else if (this.tab === 1) {
        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.sets, (s: StickerSetTab, i: number) => {
              Text(s.title).fontSize(13).maxLines(1).padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(12).backgroundColor(this.setIndex === i ? '#223A8DDE' : Color.Transparent)
                .onClick(() => this.selectSet(i))
            }, (s: StickerSetTab) => s.id)
          }
          .padding(4)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        Grid() {
          ForEach(this.cells, (c: StickerCell) => {
            GridItem() {
              StickerView({ path: c.path, format: c.format, thumbPath: c.thumb, side: 72, autoplay: false })
                .onClick(() => this.onSticker(c.fileId))
            }
          }, (c: StickerCell) => `${c.fileId}|${c.path}|${c.thumb}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .rowsGap(6)
        .height(224)
      } else {
        Grid() {
          ForEach(this.gifs, (c: StickerCell) => {
            GridItem() {
              Stack() {
                if (c.path) {
                  Video({ src: 'file://' + c.path }).autoPlay(true).loop(true).muted(true).controls(false)
                    .objectFit(ImageFit.Cover).width('100%').height(100)
                } else if (c.thumb) {
                  Image('file://' + c.thumb).objectFit(ImageFit.Cover).width('100%').height(100)
                }
              }
              .height(100)
              .borderRadius(6)
              .clip(true)
              .onClick(() => this.onGif(c.fileId))
            }
          }, (c: StickerCell) => `${c.fileId}|${c.path}|${c.thumb}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .rowsGap(4)
        .columnsGap(4)
        .height(260)
        .padding(4)
      }
    }
    .width('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}
