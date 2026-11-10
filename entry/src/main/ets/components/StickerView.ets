import lottie, { AnimationItem } from '@ohos/lottie';
import tdbridge from 'libtdbridge.so';

let nextName: number = 1;

// Renders a sticker in any of Telegram's formats: WEBP as an image, TGS
// (gzipped Lottie) on a Canvas, WEBM as a muted looping video. Until the
// file is downloaded the static thumbnail is shown.
@Component
export struct StickerView {
  @Prop @Watch('reload') path: string = '';
  @Prop format: string = 'webp';
  @Prop thumbPath: string = '';
  @Prop side: number = 180;
  @Prop autoplay: boolean = true;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private anim: AnimationItem | null = null;
  private name: string = `sticker_${nextName++}`;
  private canvasReady: boolean = false;
  @State lottieReady: boolean = false;

  aboutToDisappear(): void {
    this.destroy();
  }

  private destroy(): void {
    if (this.anim) {
      lottie.destroy(this.name);
      this.anim = null;
    }
  }

  reload(): void {
    if (this.format === 'tgs' && this.canvasReady) {
      this.loadLottie();
    }
  }

  private loadLottie(): void {
    if (!this.path || this.anim) {
      return;
    }
    const path = this.path;
    tdbridge.gunzipToString(path).then((json: string) => {
      if (path !== this.path || this.anim) {
        return;
      }
      this.anim = lottie.loadAnimation({
        container: this.ctx,
        renderer: 'canvas',
        loop: true,
        autoplay: this.autoplay,
        name: this.name,
        contentMode: 'Contain',
        frameRate: 30,
        animationData: JSON.parse(json)
      });
      this.lottieReady = true;
    }).catch(() => {
      this.lottieReady = false;
    });
  }

  build() {
    Stack() {
      if (this.format === 'tgs') {
        if (!this.lottieReady && this.thumbPath) {
          Image('file://' + this.thumbPath).width(this.side).height(this.side).objectFit(ImageFit.Contain)
        }
        Canvas(this.ctx)
          .width(this.side)
          .height(this.side)
          .onReady(() => {
            this.canvasReady = true;
            this.ctx.imageSmoothingEnabled = true;
            this.loadLottie();
          })
      } else if (this.format === 'webm' && this.path) {
        Video({ src: 'file://' + this.path })
          .width(this.side)
          .height(this.side)
          .autoPlay(this.autoplay)
          .loop(true)
          .muted(true)
          .controls(false)
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.Transparent)
      } else if (this.path && this.format === 'webp') {
        Image('file://' + this.path).width(this.side).height(this.side).objectFit(ImageFit.Contain)
      } else if (this.thumbPath) {
        Image('file://' + this.thumbPath).width(this.side).height(this.side).objectFit(ImageFit.Contain)
      } else {
        LoadingProgress().width(32).height(32)
      }
    }
    .width(this.side)
    .height(this.side)
  }
}
