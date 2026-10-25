import { fileIo as fs } from '@kit.CoreFileKit'
import { zlib } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { resourceManager } from '@kit.LocalizationKit'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Materialises the bundled dsh payload into the app sandbox.
 *
 * The archive ships in `rawfile/`, which is read-only and not addressable as a
 * filesystem path, so Node cannot require() from it. We stream it out in 1 MiB
 * chunks (the archive is far larger than any safe in-memory buffer) and let
 * zlib unpack it. The archive length acts as the extraction stamp, making the
 * step idempotent across launches.
 */
export class Payload {
  private static readonly ARCHIVE = 'dsh-payload.zip'
  private static readonly CHUNK = 1024 * 1024

  /** Returns the absolute payload root, extracting only when the archive changes. */
  static async ensure(context: common.UIAbilityContext): Promise<string> {
    const root = `${context.filesDir}/payload`
    const marker = `${context.filesDir}/payload.stamp`
    const entry = `${root}/bootstrap.cjs`

    const descriptor = await context.resourceManager.getRawFd(Payload.ARCHIVE)
    const stamp = `${descriptor.length}`
    try {
      if (fs.accessSync(marker) && fs.accessSync(entry) && fs.readTextSync(marker) === stamp) {
        return root
      }

      const archive = `${context.filesDir}/payload.zip`
      Payload.copyDescriptor(descriptor, archive)

      if (fs.accessSync(root)) {
        fs.rmdirSync(root)
      }
      fs.mkdirSync(root)
      await zlib.decompressFile(archive, root)

      const handle = fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      fs.writeSync(handle.fd, stamp)
      fs.closeSync(handle)
      return root
    } finally {
      context.resourceManager.closeRawFd(Payload.ARCHIVE)
    }
  }

  /** Stream an open rawfile descriptor to a sandbox path, one chunk at a time. */
  private static copyDescriptor(descriptor: resourceManager.RawFileDescriptor, destination: string): void {
    const out = fs.openSync(destination, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
    const buffer = new ArrayBuffer(Payload.CHUNK)
    let position = 0
    try {
      while (position < descriptor.length) {
        const want = Math.min(Payload.CHUNK, descriptor.length - position)
        const read = fs.readSync(descriptor.fd, buffer, { offset: descriptor.offset + position, length: want })
        if (read <= 0) {
          break
        }
        fs.writeSync(out.fd, buffer, { length: read })
        position += read
      }
    } finally {
      fs.closeSync(out)
    }
    if (position !== descriptor.length) {
      throw new Error(`payload copy incomplete: ${position}/${descriptor.length}`)
    }
  }

  /** Drop a previous extraction so the next launch unpacks again. */
  static reset(context: common.UIAbilityContext): void {
    const marker = `${context.filesDir}/payload.stamp`
    const root = `${context.filesDir}/payload`
    try {
      if (fs.accessSync(marker)) {
        fs.unlinkSync(marker)
      }
      if (fs.accessSync(root)) {
        fs.rmdirSync(root)
      }
    } catch (error) {
      const failure = error as BusinessError
      console.error(`payload reset failed: ${failure.message}`)
    }
  }
}
