import { avatarColor, initials } from '../common/Util';

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
          .fontSize(this.side * 0.42)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
      }
    }
    .width(this.side)
    .height(this.side)
    .borderRadius(this.side / 2)
    .backgroundColor(this.path ? Color.Transparent : avatarColor(this.seed))
  }
}
