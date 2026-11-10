import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { AppState, ViewerItem } from '../common/AppState';
import { Accounts } from '../td/Accounts';
import { AccountEvent } from '../td/Core';

// Full-screen pager for photos, videos and GIFs: swipe between items,
// pinch to zoom photos, system video controls, save to gallery.
@Entry
@Component
struct MediaViewer {
  @State items: ViewerItem[] = [];
  @State index: number = 0;
  @State scaleV: number = 1;
  @State offX: number = 0;
  @State offY: number = 0;
  @State chrome: boolean = true;
  private baseScale: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;
  private acc = Accounts.get().active();
  private listener = (e: AccountEvent): void => this.onEvent(e);

  aboutToAppear(): void {
    this.items = AppState.viewer.slice();
    this.index = AppState.viewerIndex;
    this.acc.on(this.listener);
    this.ensure(this.index);
  }

  aboutToDisappear(): void {
    this.acc.off(this.listener);
  }

  onEvent(e: AccountEvent): void {
    if (e !== 'files') {
      return;
    }
    let changed = false;
    const next = this.items.map((it: ViewerItem) => {
      if (!it.path) {
        const p = this.acc.files.known(it.fileId);
        if (p) {
          const n = new ViewerItem();
          n.kind = it.kind;
          n.caption = it.caption;
          n.fileId = it.fileId;
          n.name = it.name;
          n.path = p;
          changed = true;
          return n;
        }
      }
      return it;
    });
    if (changed) {
      this.items = next;
    }
  }

  private ensure(i: number): void {
    const it = this.items[i];
    if (it && !it.path) {
      this.acc.files.download(it.fileId, 32);
    }
  }

  private resetZoom(): void {
    this.scaleV = 1;
    this.offX = 0;
    this.offY = 0;
  }

  save(): void {
    const it = this.items[this.index];
    if (!it || !it.path) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
    const config: photoAccessHelper.PhotoCreationConfig = {
      fileNameExtension: it.kind === 'photo' ? 'jpg' : 'mp4',
      photoType: it.kind === 'photo' ? photoAccessHelper.PhotoType.IMAGE : photoAccessHelper.PhotoType.VIDEO
    };
    // The system confirmation dialog grants a one-time write URI, so no
    // restricted gallery permission is needed.
    const src = fileUri.getUriFromPath(it.path);
    helper.showAssetsCreationDialog([src], [config]).then((uris: string[]) => {
      if (uris.length === 0) {
        return;
      }
      const dst = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY);
      try {
        fs.copyFileSync(it.path, dst.fd);
      } finally {
        fs.closeSync(dst);
      }
      promptAction.showToast({ message: '已保存到图库' });
    }).catch((e: Error) => promptAction.showToast({ message: `保存失败：${e.message}` }));
  }

  @Builder
  Page(it: ViewerItem) {
    Stack() {
      if (!it.path) {
        LoadingProgress().width(48).height(48).color(Color.White)
      } else if (it.kind === 'photo') {
        Image('file://' + it.path)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .scale({ x: this.scaleV, y: this.scaleV })
          .translate({ x: this.offX, y: this.offY })
          .gesture(GestureGroup(GestureMode.Exclusive,
            PinchGesture()
              .onActionStart(() => { this.baseScale = this.scaleV; })
              .onActionUpdate((e: GestureEvent) => {
                this.scaleV = Math.min(Math.max(this.baseScale * e.scale, 1), 5);
              }),
            PanGesture({ distance: this.scaleV > 1 ? 1 : 1000 })
              .onActionStart(() => { this.baseX = this.offX; this.baseY = this.offY; })
              .onActionUpdate((e: GestureEvent) => {
                this.offX = this.baseX + e.offsetX;
                this.offY = this.baseY + e.offsetY;
              }),
            TapGesture({ count: 2 }).onAction(() => {
              if (this.scaleV > 1) {
                this.resetZoom();
              } else {
                this.scaleV = 2.5;
              }
            }),
            TapGesture().onAction(() => { this.chrome = !this.chrome; })
          ))
      } else {
        Video({ src: 'file://' + it.path })
          .width('100%')
          .height('100%')
          .autoPlay(true)
          .loop(it.kind === 'animation')
          .muted(it.kind === 'animation')
          .controls(it.kind === 'video')
          .objectFit(ImageFit.Contain)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      Swiper() {
        ForEach(this.items, (it: ViewerItem) => {
          this.Page(it)
        }, (it: ViewerItem) => `${it.fileId}|${it.path}`)
      }
      .index(this.index)
      .loop(false)
      .indicator(false)
      .disableSwipe(this.scaleV > 1)
      .onChange((i: number) => {
        this.index = i;
        this.resetZoom();
        this.ensure(i);
      })

      if (this.chrome) {
        Column() {
          Row({ space: 8 }) {
            Button('✕', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor(Color.White).fontSize(20)
              .onClick(() => router.back())
            Text(`${this.index + 1} / ${this.items.length}`).fontColor(Color.White).layoutWeight(1)
            Button('保存', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor(Color.White).onClick(() => this.save())
          }
          .padding({ left: 4, right: 4, top: 8 })
          .width('100%')
          .backgroundColor('#66000000')
          Blank()
          if (this.items[this.index] && this.items[this.index].caption) {
            Text(this.items[this.index].caption).fontColor(Color.White).fontSize(15).padding(12).width('100%')
              .backgroundColor('#66000000')
          }
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
