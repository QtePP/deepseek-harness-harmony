import { http } from '@kit.NetworkKit'
import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'

/**
 * Find and adopt a model server running on this device.
 *
 * A phone that "has a 30B model deployed" usually means some app is serving it
 * over an OpenAI-compatible HTTP endpoint on loopback — llama.cpp, vLLM, LM
 * Studio, Ollama's `/v1` shim, MNN's server mode. The user does not know the
 * port, and asking them to find it is asking them to run netstat on a phone
 * they cannot shell into.
 *
 * So we ask the ports instead: probe the handful that these servers actually
 * use and keep the ones that answer `/v1/models` with a model list. Anything
 * that does not answer is not a model server and is not worth reporting.
 */

/** One reachable OpenAI-compatible endpoint and the models it advertises. */
export interface LocalModel {
  /** e.g. `http://127.0.0.1:8080/v1` — no trailing slash. */
  baseUrl: string
  /** First model id the server advertises; the one we register. */
  modelId: string
  /** Context window we assume when the server does not say. */
  contextWindow: number
  /** Every model id the server listed, for the settings row. */
  allIds: string[]
}

/**
 * Ports worth asking. These are the defaults and near-defaults of the servers
 * people actually run on a phone; a scan of the whole range would take minutes
 * and look like an attack.
 */
export const LOCAL_MODEL_PORTS: number[] = [
  8080, 8000, 11434, 1234, 5000, 7860, 8001, 9000, 18080, 3000, 4000, 8888
]

/** Default context window when the endpoint does not advertise one. */
const DEFAULT_CONTEXT: number = 32768

/** One GET with a short budget; a local server answers in milliseconds or never. */
async function getJson(url: string): Promise<string> {
  const request = http.createHttp()
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 900,
      readTimeout: 1200,
      header: { 'Content-Type': 'application/json' }
    })
    if (response.responseCode !== 200) {
      return ''
    }
    return typeof response.result === 'string' ? response.result as string : ''
  } catch (error) {
    return ''
  } finally {
    request.destroy()
  }
}

/** Model ids from an OpenAI `/v1/models` body, or [] when it is not one. */
export function modelIdsFrom(body: string): string[] {
  if (body.length === 0) {
    return []
  }
  try {
    const parsed = JSON.parse(body) as Record<string, Object>
    const data = parsed['data']
    if (!Array.isArray(data)) {
      return []
    }
    const out: string[] = []
    for (const entry of data as Record<string, Object>[]) {
      const id = entry['id']
      if (typeof id === 'string' && id.length > 0) {
        out.push(id)
      }
    }
    return out
  } catch (error) {
    return []
  }
}

/** Ask one port whether it speaks the OpenAI model-list protocol. */
export async function probePort(port: number): Promise<LocalModel | null> {
  const baseUrl = `http://127.0.0.1:${port}/v1`
  const ids = modelIdsFrom(await getJson(`${baseUrl}/models`))
  if (ids.length === 0) {
    return null
  }
  return { baseUrl: baseUrl, modelId: ids[0], contextWindow: DEFAULT_CONTEXT, allIds: ids }
}

/** Probe every candidate port; returns whatever answered, in port order. */
export async function scanLocalModels(): Promise<LocalModel[]> {
  const found: LocalModel[] = []
  for (const port of LOCAL_MODEL_PORTS) {
    const hit = await probePort(port)
    if (hit !== null) {
      found.push(hit)
    }
  }
  return found
}

/**
 * The chosen local model, persisted so the patch survives a restart.
 *
 * Deliberately separate from `PluginConfig`: that one owns capability switches,
 * this one owns a provider route, and mixing them would make the patch writer
 * try to reason about both.
 */
export class LocalModelStore {
  static readonly STORE: string = 'dsh_local_model'
  static readonly KEY: string = 'current'

  static async load(context: common.UIAbilityContext): Promise<LocalModel | null> {
    try {
      const store = await preferences.getPreferences(context, LocalModelStore.STORE)
      const raw = await store.get(LocalModelStore.KEY, '') as string
      if (raw.length === 0) {
        return null
      }
      const parsed = JSON.parse(raw) as LocalModel
      if (typeof parsed.baseUrl !== 'string' || typeof parsed.modelId !== 'string') {
        return null
      }
      return {
        baseUrl: parsed.baseUrl,
        modelId: parsed.modelId,
        contextWindow: parsed.contextWindow > 0 ? parsed.contextWindow : DEFAULT_CONTEXT,
        allIds: Array.isArray(parsed.allIds) ? parsed.allIds : [parsed.modelId]
      }
    } catch (error) {
      return null
    }
  }

  static async save(context: common.UIAbilityContext, model: LocalModel | null): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, LocalModelStore.STORE)
      await store.put(LocalModelStore.KEY, model === null ? '' : JSON.stringify(model))
      await store.flush()
    } catch (error) {
      // A failed save only costs the user one re-scan.
    }
  }
}
