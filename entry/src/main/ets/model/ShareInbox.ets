import { common, Want } from '@kit.AbilityKit'
import { systemShare } from '@kit.ShareKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

export type ShareListener = (text: string, imagePath: string, imageName: string) => void

/**
 * Share-target inbox.
 *
 * EntryAbility hands every launch want here — cold starts through onCreate,
 * warm starts through onNewWant; `getSharedData` rejects plain launches so
 * the pass is harmless. Text records land as composer prefill, image records
 * are copied out of the shared URI into the app sandbox before the share
 * grant can expire, then one registered listener (the app shell) receives
 * both. A share that arrives before the shell mounts stays pending and is
 * delivered when the listener registers.
 */
export class ShareInbox {
  private static pendingText: string = ''
  private static pendingImagePath: string = ''
  private static pendingImageName: string = ''
  private static listener: ShareListener | null = null

  static setListener(listener: ShareListener): void {
    ShareInbox.listener = listener
    ShareInbox.deliver()
  }

  static clearListener(): void {
    ShareInbox.listener = null
  }

  /** Parse one launch want; resolves with nothing for plain launches. */
  static async handleWant(want: Want, context: common.UIAbilityContext): Promise<void> {
    let text = ''
    let imagePath = ''
    let imageName = ''
    try {
      const data = await systemShare.getSharedData(want)
      const records = data.getRecords()
      for (const record of records) {
        const utd = record.utd
        const content = record.content
        if (typeof content !== 'string' || content.length === 0) {
          continue
        }
        if (ShareInbox.isImageUtd(utd)) {
          if (imagePath.length === 0) {
            const copied = ShareInbox.copyImage(content, utd, context)
            if (copied !== null) {
              imagePath = copied
              imageName = copied.substring(copied.lastIndexOf('/') + 1)
            }
          }
        } else if (text.length === 0) {
          text = content
        }
      }
    } catch (error) {
      const err = error as BusinessError
      hilog.warn(0x0000, 'ShareInbox', 'getSharedData miss: %{public}d %{public}s',
        err.code === undefined ? 0 : err.code, err.message === undefined ? '' : err.message)
      return
    }
    if (text.length === 0 && imagePath.length === 0) {
      return
    }
    ShareInbox.pendingText = text
    ShareInbox.pendingImagePath = imagePath
    ShareInbox.pendingImageName = imageName
    ShareInbox.deliver()
  }

  private static deliver(): void {
    if (ShareInbox.pendingText.length === 0 && ShareInbox.pendingImagePath.length === 0) {
      return
    }
    const listener = ShareInbox.listener
    if (listener === null) {
      return
    }
    const text = ShareInbox.pendingText
    const imagePath = ShareInbox.pendingImagePath
    const imageName = ShareInbox.pendingImageName
    ShareInbox.pendingText = ''
    ShareInbox.pendingImagePath = ''
    ShareInbox.pendingImageName = ''
    listener(text, imagePath, imageName)
  }

  /**
   * UTD ids are not prefix-hierarchical on the wire (`general.jpeg` does not
   * contain `general.image`), so the raster family is listed explicitly.
   */
  private static isImageUtd(utd: string): boolean {
    return utd === 'general.image' || utd === 'general.png' || utd === 'general.jpeg' ||
      utd === 'general.jpg' || utd === 'general.webp' || utd === 'general.gif' ||
      utd === 'general.bmp' || utd === 'general.heic'
  }

  /** Copy one shared image out of its URI before the grant lapses; null on failure. */
  private static copyImage(uri: string, utd: string, context: common.UIAbilityContext): string | null {
    try {
      const dir = `${context.filesDir}/shared`
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir)
      }
      const ext = ShareInbox.extOf(utd, uri)
      const destPath = `${dir}/${util.generateRandomUUID(true)}.${ext}`
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const dest = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.copyFileSync(src.fd, dest.fd)
      fs.closeSync(src)
      fs.closeSync(dest)
      return destPath
    } catch (error) {
      hilog.warn(0x0000, 'ShareInbox', 'copyImage failed: %{public}s', `${error}`)
      return null
    }
  }

  private static extOf(utd: string, uri: string): string {
    if (utd.endsWith('.png')) {
      return 'png'
    }
    if (utd.endsWith('.jpeg') || utd.endsWith('.jpg')) {
      return 'jpg'
    }
    if (utd.endsWith('.webp')) {
      return 'webp'
    }
    if (utd.endsWith('.gif')) {
      return 'gif'
    }
    if (utd.endsWith('.bmp')) {
      return 'bmp'
    }
    if (utd.endsWith('.heic')) {
      return 'heic'
    }
    const lower = uri.toLowerCase()
    if (lower.endsWith('.png')) {
      return 'png'
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'jpg'
    }
    if (lower.endsWith('.webp')) {
      return 'webp'
    }
    if (lower.endsWith('.gif')) {
      return 'gif'
    }
    return 'png'
  }
}
