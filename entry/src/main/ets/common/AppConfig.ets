import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'

interface SecretsFile {
  deepseekApiKey?: string
}

/**
 * Runtime configuration.
 *
 * The API key is resolved in this order: the value saved from Settings, then
 * the `rawfile/secrets.json` bundled at build time. The bundled file is
 * gitignored — never commit it, and rotate the key if the HAP is shared.
 */
export class AppConfig {
  static readonly BRIDGE_PORT: number = 4517
  static readonly PROVIDER: string = 'deepseek-official'
  static readonly MODEL: string = 'deepseek-v4-flash'
  static readonly STORE: string = 'dsh_settings'
  static readonly PROFILE_SDK: string = 'sdk'
  static readonly PROFILE_ACP: string = 'acp'
  static readonly PERMISSION_READONLY: string = 'read-only'
  static readonly PERMISSION_WORKSPACE: string = 'workspace-write'
  static readonly PERMISSION_DANGER: string = 'danger-full-access'

  /** Named presets shipped by dsh (dsh-base cordis.patch.yml): sandbox + approval bundled. */
  static normalizePermissionMode(mode: string): string {
    if (mode === AppConfig.PERMISSION_READONLY || mode === AppConfig.PERMISSION_DANGER) {
      return mode
    }
    return AppConfig.PERMISSION_WORKSPACE
  }

  static apiKey: string = ''
  static model: string = AppConfig.MODEL
  /** dsh profile for the next boot; SDK stays the default, ACP is opt-in. */
  static profile: string = AppConfig.PROFILE_SDK
  /** Approval tier surfaced to bootstrap as DSH_PERMISSION_MODE. */
  static permissionMode: string = AppConfig.PERMISSION_WORKSPACE
  private static store: preferences.Preferences | null = null

  static async load(context: common.UIAbilityContext): Promise<void> {
    AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    const saved = await AppConfig.store.get('api_key', '') as string
    const model = await AppConfig.store.get('model', AppConfig.MODEL) as string
    const profile = await AppConfig.store.get('profile', AppConfig.PROFILE_SDK) as string
    const permission = await AppConfig.store.get('permission_mode', AppConfig.PERMISSION_WORKSPACE) as string
    AppConfig.model = model.length === 0 ? AppConfig.MODEL : model
    AppConfig.profile = profile === AppConfig.PROFILE_ACP ? AppConfig.PROFILE_ACP : AppConfig.PROFILE_SDK
    AppConfig.permissionMode = AppConfig.normalizePermissionMode(permission)
    AppConfig.apiKey = saved.length > 0 ? saved : AppConfig.readBundledKey(context)
  }

  static async save(context: common.UIAbilityContext, key: string, model: string): Promise<void> {
    AppConfig.apiKey = key.trim()
    AppConfig.model = model.trim().length === 0 ? AppConfig.MODEL : model.trim()
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('api_key', AppConfig.apiKey)
    await AppConfig.store.put('model', AppConfig.model)
    await AppConfig.store.flush()
  }

  /** Both profile and approval tier are read by bootstrap at boot, not live. */
  static async saveRuntimeChoice(context: common.UIAbilityContext, profile: string, permissionMode: string): Promise<void> {
    AppConfig.profile = profile === AppConfig.PROFILE_ACP ? AppConfig.PROFILE_ACP : AppConfig.PROFILE_SDK
    AppConfig.permissionMode = AppConfig.normalizePermissionMode(permissionMode)
    if (AppConfig.store === null) {
      AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    }
    await AppConfig.store.put('profile', AppConfig.profile)
    await AppConfig.store.put('permission_mode', AppConfig.permissionMode)
    await AppConfig.store.flush()
  }

  /** Optional build-time default key; absence is normal. */
  private static readBundledKey(context: common.UIAbilityContext): string {
    try {
      const bytes = context.resourceManager.getRawFileContentSync('secrets.json')
      const text = util.TextDecoder.create('utf-8').decodeToString(bytes)
      const parsed = JSON.parse(text) as SecretsFile
      const key = parsed.deepseekApiKey
      return key === undefined ? '' : key
    } catch (error) {
      const failure = error as BusinessError
      console.info(`no bundled secrets: ${failure.message}`)
      return ''
    }
  }
}
