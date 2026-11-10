import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { Accounts } from '../td/Accounts';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Start TDLib early so stored sessions are restored while the UI loads.
    Accounts.get().init(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const ready = Accounts.get().active().authStep === 'ready';
    windowStage.loadContent(ready ? 'pages/Main' : 'pages/Login');
    notificationManager.requestEnableNotification(this.context).catch(() => {});
  }

  onForeground(): void {
    Accounts.get().setForeground(true);
  }

  onBackground(): void {
    Accounts.get().setForeground(false);
  }
}
