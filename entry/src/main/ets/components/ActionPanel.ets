export class PanelItem {
  label: string = '';
  danger: boolean = false;
  action: () => void = (): void => {};

  constructor(label: string, action: () => void, danger: boolean = false) {
    this.label = label;
    this.action = action;
    this.danger = danger;
  }
}

// Bottom sheet drawn inside its pane (not over the whole window, so in split
// view the chat list stays usable): an optional row of reactions and a
// scrolling list of actions.
@Component
export struct ActionPanel {
  title: string = '';
  emojis: string[] = [];
  chosen: string[] = [];
  items: PanelItem[] = [];
  @Prop maxH: number = 360;
  onEmoji: (emoji: string) => void = (): void => {};
  onClose: () => void = (): void => {};

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor($r('app.color.scrim')).onClick(() => this.onClose())
      Column() {
        // Grab handle: the sheet closes with a tap outside it.
        Column().width(36).height(4).borderRadius(2).backgroundColor($r('app.color.separator'))
          .margin({ top: 8, bottom: 2 })
        if (this.title) {
          Text(this.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 18, right: 18, top: 12, bottom: 4 })
            .width('100%')
        }
        if (this.emojis.length > 0) {
          Scroll() {
            Row({ space: 4 }) {
              ForEach(this.emojis, (e: string) => {
                Text(e).fontSize(26).width(48).height(48).textAlign(TextAlign.Center).borderRadius(24)
                  .backgroundColor(this.chosen.includes(e) ? $r('app.color.accent_soft') : $r('app.color.input_bg'))
                  .onClick(() => {
                    this.onClose();
                    this.onEmoji(e);
                  })
              }, (e: string) => e)
            }
            .padding({ left: 10, right: 10 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ top: 8, bottom: 6 })
          Divider().strokeWidth(0.5).color($r('app.color.separator'))
        }
        Scroll() {
          Column() {
            ForEach(this.items, (it: PanelItem, i: number) => {
              Text(it.label).fontSize(16).width('100%').padding({ left: 18, right: 18, top: 13, bottom: 13 })
                .fontColor(it.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
                .onClick(() => {
                  this.onClose();
                  it.action();
                })
            }, (it: PanelItem, i: number) => `${i}|${it.label}`)
          }
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: Math.max(120, this.maxH - 80) })
      }
      .width('100%')
      .constraintSize({ maxWidth: 440 })
      .padding({ bottom: 12 })
      .borderRadius({ topLeft: 26, topRight: 26 })
      .backgroundColor($r('app.color.card'))
      .shadow({ radius: 28, color: '#33000000' })
      .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 180 }))
    }
    .width('100%')
    .height('100%')
  }
}
