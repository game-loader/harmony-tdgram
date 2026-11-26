import { avatarGradient, initials } from '../common/Util';

@Component
export struct Avatar {
  @Prop title: string = '';
  @Prop seed: number = 0;
  @Prop path: string = '';
  @Prop side: number = 52;

  build() {
    Stack() {
      if (this.path) {
        Image('file://' + this.path)
          .width(this.side)
          .height(this.side)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.side / 2)
      } else {
        Text(initials(this.title))
          .fontSize(Math.round(this.side * 0.4))
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
      }
    }
    .width(this.side)
    .height(this.side)
    .borderRadius(this.side / 2)
    .linearGradient({
      angle: 135,
      colors: this.path ? [[Color.Transparent, 0], [Color.Transparent, 1]] :
        [[avatarGradient(this.seed)[0], 0], [avatarGradient(this.seed)[1], 1]]
    })
  }
}
