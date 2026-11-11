import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { Accounts } from '../td/Accounts';

export default class EntryAbility extends UIAbility {
  private stage: window.WindowStage | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Start TDLib early so stored sessions are restored while the UI loads.
    Accounts.get().init(this.context);
    Accounts.get().onThemeChanged = (): void => this.applyWindowColors();
    this.openFrom(want);
  }

  // Launched again, e.g. by tapping a notification while running.
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.openFrom(want);
  }

  private openFrom(want: Want): void {
    const p = want.parameters;
    if (p && p['tdgramChat'] !== undefined) {
      Accounts.get().openFromNotification(Number(p['tdgramSlot'] ?? 0), Number(p['tdgramChat']));
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.applyWindowColors(newConfig);
  }

  // The area behind the status bar and the bar's icons follow the theme.
  private applyWindowColors(cfg?: Configuration): void {
    if (!this.stage) {
      return;
    }
    const theme = Accounts.get().settings.theme;
    // 'auto' follows the system, whose current mode the configuration carries.
    const mode = cfg && cfg.colorMode !== undefined ? cfg.colorMode : this.context.config.colorMode;
    const dark = theme === 'auto' ? mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK : theme === 'dark';
    try {
      const win = this.stage.getMainWindowSync();
      win.setWindowBackgroundColor(dark ? '#17212B' : '#FFFFFF');
      win.setWindowSystemBarProperties({
        statusBarContentColor: dark ? '#FFFFFF' : '#000000',
        navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
      }).catch(() => {});
    } catch (e) {
      // Keep the system defaults.
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stage = windowStage;
    const ready = Accounts.get().active().authStep === 'ready';
    windowStage.loadContent(ready ? 'pages/Main' : 'pages/Login').then(() => {
      // The keyboard shrinks the page instead of pushing it up, so the chat
      // header stays visible on short windows (unfolded, held sideways).
      try {
        windowStage.getMainWindowSync().getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      } catch (e) {
        // Keep the default behaviour.
      }
      this.applyWindowColors();
    }).catch(() => {});
    notificationManager.requestEnableNotification(this.context).catch(() => {});
  }

  onWindowStageDestroy(): void {
    this.stage = null;
  }

  onForeground(): void {
    Accounts.get().setForeground(true);
  }

  onBackground(): void {
    Accounts.get().setForeground(false);
  }
}
