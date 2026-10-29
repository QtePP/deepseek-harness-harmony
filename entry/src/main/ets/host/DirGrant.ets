import { common } from '@kit.AbilityKit'
import { fileIo as fs, picker, fileShare, fileUri } from '@kit.CoreFileKit'
import { abilityAccessCtrl } from '@kit.AbilityKit'

/** What a directory grant produced: the URI to persist plus its real path. */
export interface GrantedDir {
  uri: string
  path: string
  label: string
}

/**
 * User-directory grants for project workspaces.
 *
 * A project may bind a directory the user picks with the system folder
 * picker. The pick returns a `file://docs/...` URI with temporary rights;
 * fileShare persists that grant so it survives restarts, and activation
 * exposes the tree at its real path (`/storage/Users/currentUser/...`),
 * which the embedded Node runtime reaches with plain POSIX calls — verified
 * on device: full CRUD works on the granted path, while the parent and
 * sibling directories stay behind EPERM. Ungranted paths never open, so the
 * dsh sandbox rules keep their teeth.
 */

export class DirGrant {
  static supported(): boolean {
    return canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization') &&
      canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')
  }

  /**
   * Let the user pick a folder, persist + activate its grant, and return the
   * URI, real path and display name. `path` is verified reachable before
   * returning so callers never store a dead binding.
   */
  static async grant(context: common.UIAbilityContext): Promise<GrantedDir> {
    if (!DirGrant.supported()) {
      throw new Error('设备不支持目录授权能力')
    }
    const atManager = abilityAccessCtrl.createAtManager()
    const request = await atManager.requestPermissionsFromUser(context, ['ohos.permission.FILE_ACCESS_PERSIST'])
    if (request.authResults.length === 0 || request.authResults[0] !== 0) {
      throw new Error('未授予持久化访问权限')
    }
    const options = new picker.DocumentSelectOptions()
    options.selectMode = picker.DocumentSelectMode.FOLDER
    const documentViewPicker = new picker.DocumentViewPicker(context)
    const uris: string[] = await documentViewPicker.select(options)
    if (uris.length === 0) {
      throw new Error('未选择目录')
    }
    const uri = uris[0]
    await DirGrant.activate([uri])
    const dirPath = new fileUri.FileUri(uri).path
    if (dirPath === undefined || dirPath.length === 0 || !fs.accessSync(dirPath)) {
      throw new Error('所选目录无法访问')
    }
    const granted: GrantedDir = {
      uri: uri,
      path: dirPath,
      label: new fileUri.FileUri(uri).name
    }
    return granted
  }

  /**
   * (Re-)activate persisted grants so their real paths are reachable from
   * this process. Runs at boot (before any bound workspace is used) and once
   * right after a fresh grant; activation is idempotent.
   */
  static async activate(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return
    }
    const policies: fileShare.PolicyInfo[] = []
    for (const uri of uris) {
      policies.push({
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
      })
    }
    await fileShare.activatePermission(policies)
  }

  /** Revoke a persisted grant when its project binding is removed. */
  static async revoke(uri: string): Promise<void> {
    if (uri.length === 0) {
      return
    }
    const policy: fileShare.PolicyInfo = {
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
    }
    try {
      await fileShare.revokePermission([policy])
    } catch (error) {
      // Revocation is best-effort; the local binding is removed regardless.
    }
  }
}
