import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

// Window settings a video player changes for a while: keeping the screen on,
// brightness and orientation. Every change is undone by restore().
export class WindowCtl {
  private static win: Promise<window.Window | null> | null = null;
  private static awake: Set<string> = new Set();
  private static screenOn: boolean = false;
  private static brightnessChanged: boolean = false;
  private static rotated: boolean = false;

  private static get(ctx: common.Context): Promise<window.Window | null> {
    if (!WindowCtl.win) {
      WindowCtl.win = window.getLastWindow(ctx).catch((): window.Window | null => {
        WindowCtl.win = null;
        return null;
      });
    }
    return WindowCtl.win;
  }

  // Players ask for the screen to stay on while they play. It stays on as
  // long as one of them (by key) still asks.
  static keepAwake(ctx: common.Context, key: string, on: boolean): void {
    if (on) {
      WindowCtl.awake.add(key);
    } else {
      WindowCtl.awake.delete(key);
    }
    const want = WindowCtl.awake.size > 0;
    if (want === WindowCtl.screenOn) {
      return;
    }
    WindowCtl.screenOn = want;
    WindowCtl.get(ctx).then((w: window.Window | null) => {
      // Another change may have come in while the window was looked up.
      if (w && WindowCtl.screenOn === want) {
        w.setWindowKeepScreenOn(want).catch((e: BusinessError) => {
          console.warn(`TdGram: keep screen on failed: ${e.code}`);
        });
      }
    });
  }

  // Current brightness 0..1, or -1 when the window follows the system.
  static brightness(ctx: common.Context): Promise<number> {
    return WindowCtl.get(ctx).then((w: window.Window | null) => {
      if (!w) {
        return -1;
      }
      try {
        const b = w.getWindowProperties().brightness;
        return typeof b === 'number' && b >= 0 && b <= 1 ? b : -1;
      } catch (e) {
        return -1;
      }
    });
  }

  static setBrightness(ctx: common.Context, value: number): void {
    WindowCtl.brightnessChanged = true;
    WindowCtl.get(ctx).then((w: window.Window | null) => {
      w?.setWindowBrightness(value).catch(() => {});
    });
  }

  static setLandscape(ctx: common.Context, landscape: boolean): void {
    WindowCtl.rotated = true;
    WindowCtl.get(ctx).then((w: window.Window | null) => {
      w?.setPreferredOrientation(landscape ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT)
        .catch(() => {});
    });
  }

  // Back to what the app normally uses (see module.json5).
  static restore(ctx: common.Context): void {
    const brightness = WindowCtl.brightnessChanged;
    const rotated = WindowCtl.rotated;
    WindowCtl.brightnessChanged = false;
    WindowCtl.rotated = false;
    if (!brightness && !rotated) {
      return;
    }
    WindowCtl.get(ctx).then((w: window.Window | null) => {
      if (!w) {
        return;
      }
      if (brightness) {
        // -1 hands brightness back to the system.
        w.setWindowBrightness(-1).catch(() => {});
      }
      if (rotated) {
        w.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED).catch(() => {});
      }
    });
  }
}
