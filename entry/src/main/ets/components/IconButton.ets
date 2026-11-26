// A round, borderless button showing one system symbol. `filled` paints the
// circle with the accent gradient and the symbol white (send, record).
@Component
export struct IconButton {
  @Prop glyph: Resource = $r('sys.symbol.xmark');
  @Prop tint: ResourceColor = $r('app.color.text_secondary');
  @Prop side: number = 40;
  @Prop glyphSize: number = 22;
  @Prop filled: boolean = false;

  build() {
    Stack() {
      SymbolGlyph(this.glyph)
        .fontSize(this.glyphSize)
        .fontColor([this.filled ? Color.White : this.tint])
    }
    .width(this.side)
    .height(this.side)
    .borderRadius(this.side / 2)
    .linearGradient({
      angle: 135,
      colors: this.filled ? [[$r('app.color.accent'), 0], [$r('app.color.accent_end'), 1]] :
        [[Color.Transparent, 0], [Color.Transparent, 1]]
    })
    .clickEffect({ level: ClickEffectLevel.LIGHT })
  }
}
