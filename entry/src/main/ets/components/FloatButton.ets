// Round floating button over the message list: "jump to latest" (a drawn
// chevron) or, with a label, "next mention". An optional count sits on its
// top edge.
@Component
export struct FloatButton {
  @Prop count: number = 0;
  @Prop label: string = ''; // shown instead of the chevron

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Stack() {
        if (this.label) {
          Text(this.label).fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
        } else {
          // Drawn rather than a text glyph, so the stroke is even and round-capped.
          Polyline()
            .width(18)
            .height(11)
            .points([[2, 2], [9, 9], [16, 2]])
            .stroke($r('app.color.text_secondary'))
            .strokeWidth(2.2)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
            .fillOpacity(0)
            .margin({ top: 2 })
        }
      }
      .width(42)
      .height(42)
      .borderRadius(21)
      .backgroundColor($r('app.color.card'))
      .border({ width: 0.5, color: $r('app.color.separator') })
      .shadow({ radius: 12, color: '#24000000', offsetY: 3 })
      .margin({ top: 9 })

      if (this.count > 0) {
        Text(this.count > 999 ? '999+' : String(this.count))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .height(19)
          .constraintSize({ minWidth: 19 })
          .padding({ left: 5, right: 5 })
          .borderRadius(9.5)
          .backgroundColor($r('app.color.accent'))
          .border({ width: 1.5, color: $r('app.color.card') })
      }
    }
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })).animation({ duration: 160 }))
  }
}
