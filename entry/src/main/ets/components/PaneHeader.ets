import { IconButton } from './IconButton';

// Title bar of a detail pane. The back button disappears when the pane sits
// beside the chat list (unfolded) and returns when it fills the window.
@Component
export struct PaneHeader {
  @Prop title: string = '';
  @Prop showBack: boolean = true;
  onBack: () => void = (): void => {};
  @BuilderParam trailing: () => void = this.None;

  @Builder
  None() {
  }

  build() {
    Row({ space: 4 }) {
      if (this.showBack) {
        IconButton({ glyph: $r('sys.symbol.chevron_left'), tint: $r('app.color.text_primary'), glyphSize: 24 })
          .onClick(() => this.onBack())
      }
      Text(this.title).fontSize(19).fontWeight(FontWeight.Bold).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        .fontColor($r('app.color.text_primary'))
      this.trailing()
    }
    .padding({ left: this.showBack ? 4 : 18, right: 6 })
    .height(56)
    .width('100%')
  }
}
