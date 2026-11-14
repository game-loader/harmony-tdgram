import { common } from '@kit.AbilityKit';

import { AppState, ViewerItem } from '../common/AppState';
import {
  boostSpeed, clock, dragBrightness, normalizeSpeed, resumeAt, SEEK_STEP, seekTarget, SPEEDS, speedLabel, tapZone
} from '../common/VideoMath';
import { Accounts } from '../td/Accounts';
import { WindowCtl } from '../services/WindowCtl';
import { toast } from '../common/Ui';

interface DurationInfo {
  duration: number;
}

interface TimeInfo {
  time: number;
}

const HIDE_AFTER = 3500; // ms of playing without a touch before the controls hide

// Full-screen video with its own controls:
//   double tap left / right third: back / ahead 10 s, middle: pause
//   hold: play faster while the finger stays down
//   drag up or down on the left half: brightness
// The screen stays on while a video plays.
@Component
export struct VideoPlayer {
  item: ViewerItem = new ViewerItem();
  // Only the page on screen plays; neighbours in the pager wait paused.
  @Prop @Watch('onActiveChanged') active: boolean = false;
  @Prop chrome: boolean = true; // the viewer's controls are shown
  toggleChrome: () => void = (): void => {};
  hideChrome: () => void = (): void => {};
  @State time: number = 0;
  @State duration: number = 0;
  @State playing: boolean = false;
  @State prepared: boolean = false;
  @State failed: boolean = false;
  @State ended: boolean = false;
  @State dragging: boolean = false;
  @State dragTime: number = 0;
  @State speed: number = 1;
  @State boosting: boolean = false;
  @State hint: string = '';
  @State hintZone: number = 0; // -1 left, 0 middle, 1 right
  @State level: string = '';   // brightness shown while it is dragged
  @State landscape: boolean = false;
  @State boxW: number = 360;
  @State boxH: number = 640;
  private controller: VideoController = new VideoController();
  private hintTimer: number = -1;
  private hideTimer: number = -1;
  private resumed: boolean = false;
  private brightStart: number = 0.5;
  private brightNow: number = 0.5;

  aboutToAppear(): void {
    this.speed = normalizeSpeed(Accounts.get().settings.videoSpeed);
  }

  aboutToDisappear(): void {
    this.remember();
    this.awake(false);
    clearTimeout(this.hintTimer);
    clearTimeout(this.hideTimer);
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private awakeKey(): string {
    return `video:${this.item.fileId}`;
  }

  private awake(on: boolean): void {
    WindowCtl.keepAwake(this.ctx(), this.awakeKey(), on);
  }

  // Where the video was left, so opening it again continues there.
  private remember(): void {
    if (this.item.fileId && this.prepared) {
      if (this.ended) {
        AppState.videoPositions.delete(this.item.fileId);
      } else {
        AppState.videoPositions.set(this.item.fileId, this.time);
      }
    }
  }

  onActiveChanged(): void {
    if (!this.prepared) {
      return;
    }
    if (this.active) {
      if (!this.ended) {
        this.controller.start();
      }
    } else {
      this.controller.pause();
      this.remember();
    }
  }

  // ---- Actions ----

  private togglePlay(): void {
    if (!this.prepared) {
      return;
    }
    if (this.playing) {
      this.controller.pause();
    } else {
      if (this.ended) {
        this.seekTo(0);
        this.ended = false;
      }
      this.controller.start();
    }
    this.touched();
  }

  private seekTo(t: number): void {
    if (!this.prepared) {
      return;
    }
    this.time = t;
    this.ended = false;
    this.controller.setCurrentTime(t, SeekMode.Accurate);
  }

  private skip(delta: number, zone: number): void {
    if (!this.prepared) {
      return;
    }
    const t = seekTarget(this.time, delta, this.duration);
    this.seekTo(t);
    this.flash(delta > 0 ? `+${delta} 秒` : `${delta} 秒`, zone);
    this.touched();
  }

  private setSpeed(s: number): void {
    this.speed = s;
    const settings = Accounts.get().settings;
    if (settings.videoSpeed !== s) {
      settings.videoSpeed = s;
      Accounts.get().saveSettings();
    }
    this.flash(`${speedLabel(s)} 倍速`, 0);
    this.touched();
  }

  private startBoost(): void {
    if (!this.prepared || this.ended) {
      return;
    }
    if (!this.playing) {
      this.controller.start();
    }
    this.boosting = true;
  }

  private endBoost(): void {
    this.boosting = false;
  }

  private toggleLandscape(): void {
    this.landscape = !this.landscape;
    WindowCtl.setLandscape(this.ctx(), this.landscape);
    this.touched();
  }

  // A short message in the middle (or on the side that was tapped).
  private flash(text: string, zone: number): void {
    this.hint = text;
    this.hintZone = zone;
    clearTimeout(this.hintTimer);
    this.hintTimer = setTimeout(() => {
      this.hint = '';
    }, 700);
  }

  // Controls hide again a while after the last touch, while playing.
  private touched(): void {
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      if (this.playing && this.chrome && !this.dragging) {
        this.hideChrome();
      }
    }, HIDE_AFTER);
  }

  private onTap(x: number): void {
    this.toggleChrome();
    this.touched();
  }

  private onDoubleTap(x: number): void {
    const zone = tapZone(x, this.boxW);
    if (zone === 0) {
      this.togglePlay();
      this.flash(this.playing ? '暂停' : '播放', 0);
    } else {
      this.skip(zone * SEEK_STEP, zone);
    }
  }

  private speedMenu(): MenuElement[] {
    return SPEEDS.map((s: number): MenuElement => {
      const e: MenuElement = { value: `${s === this.speed ? '✓ ' : ''}${speedLabel(s)}`, action: (): void => this.setSpeed(s) };
      return e;
    });
  }

  // ---- Layout ----

  @Builder
  Icon(name: Resource, size: number) {
    SymbolGlyph(name).fontSize(size).fontColor([Color.White])
  }

  @Builder
  RoundButton(name: Resource, size: number, fn: () => void) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      this.Icon(name, size)
    }
    .width(size + 22)
    .height(size + 22)
    .backgroundColor(Color.Transparent)
    .onClick(() => fn())
  }

  @Builder
  Controls() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(clock(this.dragging ? this.dragTime : this.time)).fontSize(12).fontColor(Color.White)
          .constraintSize({ minWidth: 40 })
        Slider({ value: this.dragging ? this.dragTime : this.time, min: 0, max: Math.max(this.duration, 0.1), step: 0.1 })
          .layoutWeight(1)
          .trackColor('#55FFFFFF')
          .selectedColor($r('app.color.accent'))
          .blockColor(Color.White)
          .enabled(this.prepared)
          .onChange((v: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.dragging = true;
              this.dragTime = v;
            } else {
              this.dragging = false;
              this.seekTo(v);
            }
            this.touched();
          })
        Text(clock(this.duration)).fontSize(12).fontColor(Color.White).constraintSize({ minWidth: 40 })
          .textAlign(TextAlign.End)
      }
      .width('100%')
      Row({ space: 4 }) {
        this.RoundButton($r('sys.symbol.gobackward_10'), 22, () => this.skip(-SEEK_STEP, -1))
        this.RoundButton(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'), 28,
          () => this.togglePlay())
        this.RoundButton($r('sys.symbol.goforward_10'), 22, () => this.skip(SEEK_STEP, 1))
        Blank()
        Button(speedLabel(this.speed), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontColor(Color.White).fontSize(15)
          .bindMenu(this.speedMenu())
        this.RoundButton($r('sys.symbol.screen_rotation'), 20, () => this.toggleLandscape())
      }
      .width('100%')
    }
    .padding({ left: 12, right: 12, top: 24, bottom: 16 })
    .width('100%')
    .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#B0000000', 1]] })
  }

  build() {
    Stack() {
      Video({
        src: this.item.streamUrl || ('file://' + this.item.path),
        currentProgressRate: this.boosting ? boostSpeed(this.speed) : this.speed,
        controller: this.controller
      })
        .width('100%')
        .height('100%')
        .autoPlay(this.active)
        .controls(false)
        .objectFit(ImageFit.Contain)
        .onPrepared((e: DurationInfo) => {
          this.duration = e.duration ?? 0;
          this.prepared = true;
          this.failed = false;
          if (!this.resumed) {
            this.resumed = true;
            const at = resumeAt(AppState.videoPositions.get(this.item.fileId) ?? 0, this.duration);
            if (at > 0) {
              this.seekTo(at);
              toast(`从 ${clock(at)} 继续播放`);
            }
          }
          if (!this.active) {
            this.controller.pause();
          }
        })
        .onUpdate((e: TimeInfo) => {
          this.time = e.time ?? this.time;
        })
        .onSeeked((e: TimeInfo) => {
          this.time = e.time ?? this.time;
        })
        .onStart(() => {
          this.playing = true;
          this.ended = false;
          this.awake(true);
          this.touched();
        })
        .onPause(() => {
          this.playing = false;
          this.boosting = false;
          this.awake(false);
          this.remember();
        })
        .onFinish(() => {
          this.playing = false;
          this.boosting = false;
          this.ended = true;
          this.time = this.duration;
          this.awake(false);
          this.remember();
        })
        .onError(() => {
          this.failed = true;
          this.playing = false;
          this.awake(false);
        })

      // Touch layer over the picture. Horizontal drags are left to the pager.
      Column()
        .width('100%')
        .height('100%')
        .gesture(GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction((e: GestureEvent) => {
            this.onDoubleTap(e.fingerList.length > 0 ? e.fingerList[0].localX : this.boxW / 2);
          }),
          TapGesture({ count: 1 }).onAction((e: GestureEvent) => {
            this.onTap(e.fingerList.length > 0 ? e.fingerList[0].localX : 0);
          }),
          LongPressGesture({ duration: 400 })
            .onAction(() => this.startBoost())
            .onActionEnd(() => this.endBoost())
            .onActionCancel(() => this.endBoost()),
          PanGesture({ direction: PanDirection.Vertical, distance: 12 })
            .onActionStart((e: GestureEvent) => {
              const x = e.fingerList.length > 0 ? e.fingerList[0].localX : this.boxW;
              this.brightStart = -2; // not on the left half: ignored
              if (x < this.boxW / 2) {
                this.brightStart = this.brightNow;
                WindowCtl.brightness(this.ctx()).then((b: number) => {
                  if (b >= 0 && this.brightStart >= 0) {
                    this.brightStart = b;
                  }
                });
              }
            })
            .onActionUpdate((e: GestureEvent) => {
              if (this.brightStart < 0) {
                return;
              }
              this.brightNow = dragBrightness(this.brightStart, e.offsetY, this.boxH * 0.8);
              WindowCtl.setBrightness(this.ctx(), this.brightNow);
              this.level = `亮度 ${Math.round(this.brightNow * 100)}%`;
            })
            .onActionEnd(() => { this.level = ''; })
            .onActionCancel(() => { this.level = ''; })
        ))

      if (!this.prepared && !this.failed) {
        LoadingProgress().width(48).height(48).color(Color.White).hitTestBehavior(HitTestMode.None)
      }
      if (this.failed) {
        Text('无法播放这个视频').fontColor(Color.White).fontSize(15).hitTestBehavior(HitTestMode.None)
      }
      // Paused or finished: a large play button in the middle.
      if (this.prepared && !this.playing && !this.failed && this.hint === '') {
        Button({ type: ButtonType.Circle }) {
          this.Icon(this.ended ? $r('sys.symbol.arrow_counterclockwise') : $r('sys.symbol.play_fill'), 34)
        }
        .width(72)
        .height(72)
        .backgroundColor('#66000000')
        .onClick(() => this.togglePlay())
      }
      if (this.boosting) {
        Row({ space: 6 }) {
          this.Icon($r('sys.symbol.forward_end_fill'), 16)
          Text(`${speedLabel(boostSpeed(this.speed))} 快进中`).fontColor(Color.White).fontSize(14)
        }
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(18)
        .backgroundColor('#88000000')
        .position({ x: '50%', y: 72 })
        .translate({ x: '-50%' })
        .hitTestBehavior(HitTestMode.None)
      }
      if (this.hint || this.level) {
        Text(this.level || this.hint).fontColor(Color.White).fontSize(16)
          .padding({ left: 16, right: 16, top: 9, bottom: 9 })
          .borderRadius(20)
          .backgroundColor('#88000000')
          .position({ x: this.level ? '50%' : (this.hintZone < 0 ? '20%' : (this.hintZone > 0 ? '80%' : '50%')), y: '50%' })
          .translate({ x: '-50%', y: '-50%' })
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.chrome && this.prepared) {
        Column() {
          Blank()
          this.Controls()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_: Area, a: Area) => {
      this.boxW = Number(a.width);
      this.boxH = Number(a.height);
    })
  }
}
