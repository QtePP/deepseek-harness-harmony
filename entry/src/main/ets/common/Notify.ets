import { common } from '@kit.AbilityKit'
import { notificationManager } from '@kit.NotificationKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000
/** One slot for the running turn: a new result replaces the previous one. */
const NOTIFY_ID = 4517

/**
 * Local notifications for the two moments the user is not looking at the app:
 * a turn finished, or the runtime is waiting for an answer (an approval).
 *
 * The phone is the one place where "the agent kept working while you switched
 * away" is normal, and the shell already knows both events — `session/status`
 * and `session/request_permission` — so this is pure client work. Nothing is
 * posted while the app is in the foreground: the transcript already says it,
 * and a notification on top of a visible answer is noise.
 *
 * Authorization is requested lazily on the first background notification, so a
 * user who never leaves the app is never asked.
 */
export class Notify {
  private static context: common.UIAbilityContext | null = null
  private static asked: boolean = false
  /**
   * The user backgrounded the app with work in flight, but notifications are
   * still off. The authorization dialog can only be shown while the app is in
   * the foreground, so the request is deferred to the next foreground instead
   * of failing silently in the background.
   */
  private static pendingRequest: boolean = false
  /** Automatic requests are capped; the Settings button is the explicit path. */
  private static attempts: number = 0
  /** Kept by EntryAbility; a static field rather than AppStorage so the
   *  ability (which is not a UI component) can write it without importing
   *  the UI framework's storage. */
  private static fg: boolean = true

  static attach(context: common.UIAbilityContext): void {
    Notify.context = context
  }

  /** EntryAbility keeps this current; an unknown state counts as foreground. */
  static setForeground(value: boolean): void {
    Notify.fg = value
    if (value && Notify.pendingRequest) {
      void Notify.requestPermissionQuietly()
    }
  }

  /**
   * Ask for the notification switch. Returns a short status for the caller's
   * toast, because on some devices the switch is administratively off and the
   * API fails without ever showing a dialog — the user needs to hear that
   * instead of wondering why nothing happens.
   */
  static async requestPermission(): Promise<string> {
    const context = Notify.context
    if (context === null) {
      return '应用尚未就绪'
    }
    try {
      const enabled = await notificationManager.isNotificationEnabled()
      if (enabled) {
        return '通知已开启'
      }
      await notificationManager.requestEnableNotification(context)
      Notify.pendingRequest = false
      return '已请求通知权限'
    } catch (error) {
      const failure = error as BusinessError
      return `通知未开启：${failure.message}（可在系统设置 › 通知 › TA Harness 中打开）`
    }
  }

  /** Automatic path: ask at most twice, then stop nagging. */
  private static async requestPermissionQuietly(): Promise<void> {
    if (Notify.asked || Notify.attempts >= 2) {
      return
    }
    Notify.asked = true
    Notify.attempts++
    await Notify.requestPermission()
    Notify.asked = false
  }

  private static foreground(): boolean {
    return Notify.fg
  }

  /** A turn settled while the user was elsewhere. */
  static async turnFinished(text: string): Promise<void> {
    if (Notify.foreground()) {
      return
    }
    await Notify.publish('回答已完成', text.length > 0 ? text : '回到 TA Harness 查看结果')
  }

  /** The runtime is blocked on the user (approval), which is worth a tap. */
  static async needsYou(text: string): Promise<void> {
    if (Notify.foreground()) {
      return
    }
    await Notify.publish('等待你的确认', text)
  }

  /** Turn failed while the user was elsewhere. */
  static async turnFailed(text: string): Promise<void> {
    if (Notify.foreground()) {
      return
    }
    await Notify.publish('本轮出错', text)
  }

  private static async publish(title: string, text: string): Promise<void> {
    const context = Notify.context
    if (context === null) {
      return
    }
    try {
      const enabled = await notificationManager.isNotificationEnabled()
      if (!enabled) {
        // Backgrounded: the dialog cannot be shown here, so remember that the
        // user needs to be asked and drop this notification.
        Notify.pendingRequest = true
        return
      }
      const request: notificationManager.NotificationRequest = {
        id: NOTIFY_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: clip(text, 300)
          }
        }
      }
      await notificationManager.publish(request)
    } catch (error) {
      // Notifications are best-effort: a denied permission or a missing slot
      // must never disturb the turn that triggered them.
      const failure = error as BusinessError
      hilog.warn(DOMAIN, 'Notify', 'publish failed: %{public}s', failure.message)
    }
  }
}

function clip(text: string, max: number): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > max ? `${flat.substring(0, max)}…` : flat
}
