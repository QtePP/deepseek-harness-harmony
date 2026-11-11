import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ShareInbox } from '../model/ShareInbox';
import { Notify } from '../common/Notify';
import { AppConfig } from '../common/AppConfig';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Appearance must be decided before the page exists: switching it later
    // rebuilds the window and blanks the ArkUI tree on this device.
    try {
      AppConfig.applyAppearanceAtBoot(this.context);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    this.captureShortcut(want);
    // Share targets arrive through the want; plain launches reject inside.
    void ShareInbox.handleWant(want, this.context);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.captureShortcut(want);
    void ShareInbox.handleWant(want, this.context);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
  }

  /**
   * A launcher shortcut carries its id in the want. Publishing it through
   * AppStorage lets the page react even when the ability was already running
   * (onNewWant), instead of only on a cold start.
   */
  private captureShortcut(want: Want): void {
    const params = want.parameters;
    if (params === undefined) {
      return;
    }
    const id = params['shortcutId'];
    if (typeof id === 'string' && id.length > 0) {
      AppStorage.setOrCreate('pendingShortcut', id);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    Notify.setForeground(true);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background: this is exactly when a finished turn is
    // worth a notification, so the flag is written before anything else.
    Notify.setForeground(false);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}