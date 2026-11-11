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
    Row({ space: 8 }) {
      if (this.showBack) {
        Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => this.onBack())
      }
      Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        .fontColor($r('app.color.text_primary'))
      this.trailing()
    }
    .padding({ left: this.showBack ? 0 : 16, right: 4 })
    .height(48)
    .width('100%')
  }
}
