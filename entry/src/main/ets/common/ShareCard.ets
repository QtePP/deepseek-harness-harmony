import { common } from '@kit.AbilityKit'
import { componentSnapshot } from '@kit.ArkUI'
import { image } from '@kit.ImageKit'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { systemShare } from '@kit.ShareKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Share one message as a picture.
 *
 * dsh-go turns a reply into a share card; the phone has no screenshot tool for
 * the user, so the app renders the bubble it already drew. `componentSnapshot`
 * captures the message component as a PixelMap, the image packer encodes it to
 * PNG, and the file goes to the system share panel through ShareKit — which
 * exists in this SDK's HMS set (the app already uses it to receive shares).
 *
 * Returns a message for the caller's toast: success, cancellation and failure
 * all need to say something, because the panel is the only visible feedback.
 */
export async function shareMessageCard(context: common.UIAbilityContext, componentId: string,
  title: string, fallbackText: string): Promise<string> {
  let path = ''
  try {
    const pixelMap = await componentSnapshot.get(componentId)
    const packer = image.createImagePacker()
    const buffer = await packer.packing(pixelMap, { format: 'image/png', quality: 100 })
    path = `${context.cacheDir}/share-${util.generateRandomUUID(true)}.png`
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(file.fd, buffer)
    } finally {
      fs.closeSync(file)
    }
  } catch (error) {
    const failure = error as BusinessError
    return `生成分享图片失败：${failure.message}`
  }

  // The share service wants a URI from its own helper, not a hand-built
  // `file://` string; a hand-built one is accepted by the constructor and then
  // rejected by show() with "IPC data is oversized" on this device.
  let uri = ''
  try {
    uri = fileUri.getUriFromPath(path)
  } catch (error) {
    uri = `file://${path}`
  }

  const modes: systemShare.SharePreviewMode[] = [
    systemShare.SharePreviewMode.DETAIL,
    systemShare.SharePreviewMode.DEFAULT
  ]
  let lastError = ''
  for (const mode of modes) {
    try {
      const record: systemShare.SharedRecord = {
        utd: 'general.png',
        uri: uri,
        title: title
      }
      const data = new systemShare.SharedData(record)
      const controller = new systemShare.ShareController(data)
      await controller.show(context, {
        previewMode: mode,
        selectionMode: systemShare.SelectionMode.SINGLE
      })
      return '已打开分享面板'
    } catch (error) {
      lastError = (error as BusinessError).message
    }
  }

  // Image sharing refused: fall back to the text itself, which always fits.
  try {
    const record: systemShare.SharedRecord = {
      utd: 'general.plain-text',
      content: fallbackText.length > 0 ? fallbackText : title,
      title: title
    }
    const data = new systemShare.SharedData(record)
    const controller = new systemShare.ShareController(data)
    await controller.show(context, {
      previewMode: systemShare.SharePreviewMode.DEFAULT,
      selectionMode: systemShare.SelectionMode.SINGLE
    })
    return '图片分享不可用，已改为分享文字'
  } catch (error) {
    return `分享失败：${lastError}`
  }
}
