import { RpcFrame } from './Protocol'

/**
 * Wire types for the dsh ACP profile (newline-delimited JSON-RPC 2.0 over the
 * same loopback bridge as the SDK profile).
 *
 * Contract notes verified against dsh 0.2.1-rc.2 on-device (AGENTS.md §4.2):
 *   · every wire method name is snake_case (`session/set_config_option`,
 *     `session/request_permission`), never the ACP-spec camelCase;
 *   · frames must carry `"jsonrpc":"2.0"` or the pre-validator answers
 *     `-32600 Invalid request` before method dispatch;
 *   · `session/cancel` is a notification (no id, no response);
 *   · the `model` config value is a JSON array *string*, not an object;
 *   · config option lists shrink after a switch — every response's
 *     `configOptions` is the new authority, never cache an older list;
 *   · `session/update` discriminates on `update.sessionUpdate`, and
 *     `usage_update` carries `{used, size}` (dsh variant, not ACP-spec tokens).
 */

export interface AcpClientCapabilities {
}

export interface AcpInitializeParams {
  protocolVersion: number
  clientCapabilities: AcpClientCapabilities
}

export interface AcpAgentInfo {
  name?: string
  version?: string
}

export interface AcpInitializeResult {
  protocolVersion?: number
  agentInfo?: AcpAgentInfo
}

export interface AcpSessionNewParams {
  cwd: string
  mcpServers: string[]
}

export interface AcpResumeParams {
  sessionId: string
  cwd: string
  mcpServers: string[]
}

export interface AcpPromptParams {
  sessionId: string
  prompt: AcpContentBlock[]
}

export interface AcpContentBlock {
  type: string
  text: string
}

export interface AcpPromptResult {
  stopReason?: string
}

export interface AcpSetConfigParams {
  sessionId: string
  configId: string
  value: string
}

export interface AcpSetConfigResult {
  configOptions?: AcpConfigOption[]
}

export interface AcpCancelParams {
  sessionId: string
}

/**
 * Tolerant view of one config option. `options` is polymorphic on the wire:
 * `model` nests one level (`{group, name, options: [...]}`) while
 * `reasoning_effort` is flat (`{value, name, description}`); one interface
 * covers both shapes for flattening.
 */
export interface AcpConfigGroup {
  group?: string
  name?: string
  description?: string
  value?: string
  options?: AcpConfigGroup[]
}

export interface AcpConfigOption {
  id?: string
  name?: string
  category?: string
  type?: string
  currentValue?: string
  options?: AcpConfigGroup[]
}

export interface AcpSessionNewResult {
  sessionId?: string
  configOptions?: AcpConfigOption[]
}

/** One flattened selectable choice of a config option. */
export interface AcpModelChoice {
  value: string
  name: string
  description: string
}

/** Tolerant view of the `update` body of a session/update notification. */
export interface AcpContentLike {
  type?: string
  text?: string
}

export interface AcpUpdateBody {
  sessionUpdate?: string
  type?: string
  messageId?: string
  content?: AcpContentLike
  toolCallId?: string
  toolKind?: string
  title?: string
  status?: string
  used?: number
  size?: number
}

export interface AcpUpdatePayload {
  sessionId?: string
  update?: AcpUpdateBody
}

export interface AcpPermissionOption {
  optionId?: string
  name?: string
  kind?: string
}

export interface AcpToolCallRef {
  toolCallId?: string
  title?: string
  toolKind?: string
}

export interface AcpPermissionPayload {
  sessionId?: string
  toolCall?: AcpToolCallRef
  options?: AcpPermissionOption[]
}

/** Server-initiated approval request waiting for the user's answer. */
export class AcpPermissionRequest {
  id: number = 0
  payload: AcpPermissionPayload | null = null
}

export interface AcpPermissionOutcome {
  outcome: string
  optionId: string
}

export interface AcpPermissionResponse {
  outcome: AcpPermissionOutcome
}

/** A notification frame: method + params, never an id and never a reply. */
export function encodeNotification(method: string, params: object): string {
  const frame: RpcFrame = { jsonrpc: '2.0', method: method, params: params }
  return JSON.stringify(frame) + '\n'
}

/** Locate one config option by id; null when the server did not send it. */
export function findConfigOption(options: AcpConfigOption[] | undefined, id: string): AcpConfigOption | null {
  if (options === undefined) {
    return null
  }
  for (const option of options) {
    if (option.id === id) {
      return option
    }
  }
  return null
}

/**
 * Flatten the polymorphic option list into plain choices. Group entries are
 * walked recursively; leaf entries keep their value/name/description. The
 * result must be rebuilt from every set_config_option response — the list
 * shrinks as selections are made (the previous value may stop being valid).
 */
export function flattenChoices(entries: AcpConfigGroup[] | undefined): AcpModelChoice[] {
  const out: AcpModelChoice[] = []
  if (entries === undefined) {
    return out
  }
  for (const entry of entries) {
    if (entry.options !== undefined && entry.options.length > 0) {
      const nested = flattenChoices(entry.options)
      for (const item of nested) {
        out.push(item)
      }
    } else if (entry.value !== undefined) {
      const value = entry.value
      const name = entry.name === undefined || entry.name.length === 0 ? value : entry.name
      const description = entry.description === undefined ? '' : entry.description
      out.push({ value: value, name: name, description: description })
    }
  }
  return out
}
