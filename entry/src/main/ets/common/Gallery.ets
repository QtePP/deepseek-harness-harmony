import { common } from '@kit.AbilityKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Save one sandbox image into the system gallery.
 *
 * The shell declares no media permissions on purpose, so the write is only
 * allowed in the short window a security component opens: the SaveButton the
 * viewer draws grants temporary `WRITE_IMAGEVIDEO` when the user taps it, and
 * `createAsset` inside that window works without an ACL. Called from anywhere
 * else it fails closed, which is the correct behaviour — saving must be the
 * user's tap, not a side effect.
 */
export async function saveToGallery(context: common.UIAbilityContext, path: string): Promise<string> {
  const ext = extensionOf(path)
  if (ext.length === 0) {
    return '只支持保存 png / jpg / webp / gif 图片'
  }
  try {
    const helper = photoAccessHelper.getPhotoAccessHelper(context)
    const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, ext)
    copyInto(uri, path)
    return '已保存到相册'
  } catch (error) {
    const failure = error as BusinessError
    return `保存失败：${failure.message}`
  }
}

/** Copy the source bytes into the asset the media library just created. */
function copyInto(targetUri: string, sourcePath: string): void {
  const source = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY)
  try {
    const target = fs.openSync(targetUri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    try {
      const buffer = new ArrayBuffer(64 * 1024)
      let read = fs.readSync(source.fd, buffer)
      while (read > 0) {
        // A short write is possible on some media providers; advance by what
        // was actually written rather than assuming the whole chunk landed.
        let written = 0
        while (written < read) {
          written += fs.writeSync(target.fd, buffer, { offset: written, length: read - written })
        }
        read = fs.readSync(source.fd, buffer)
      }
    } finally {
      fs.closeSync(target)
    }
  } finally {
    fs.closeSync(source)
  }
}

function extensionOf(path: string): string {
  const dot = path.lastIndexOf('.')
  if (dot < 0 || dot === path.length - 1) {
    return ''
  }
  const ext = path.substring(dot + 1).toLowerCase()
  if (ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'webp' || ext === 'gif') {
    return ext
  }
  return ''
}
