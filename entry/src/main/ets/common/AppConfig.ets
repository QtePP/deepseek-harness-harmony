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

  static apiKey: string = ''
  static model: string = AppConfig.MODEL
  private static store: preferences.Preferences | null = null

  static async load(context: common.UIAbilityContext): Promise<void> {
    AppConfig.store = await preferences.getPreferences(context, AppConfig.STORE)
    const saved = await AppConfig.store.get('api_key', '') as string
    const model = await AppConfig.store.get('model', AppConfig.MODEL) as string
    AppConfig.model = model.length === 0 ? AppConfig.MODEL : model
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
