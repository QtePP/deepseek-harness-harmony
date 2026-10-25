/**
 * Wire types for the dsh SDK JSON-RPC protocol (newline-delimited, JSON-RPC 2.0).
 *
 * Mirrors `@deepseek-ai/dsh-sdk-protocol` on the host side: three client→server
 * requests (`initialize`, `session/prompt`, `shutdown`) and four server→client
 * notifications (`session.event`, `session.status`, `subagent.started`,
 * `subagent.finished`). The transport here is loopback TCP instead of stdio,
 * but the frames are byte-identical.
 */

export interface RpcError {
  code: number
  message: string
  data?: string
}

export interface RpcFrame {
  jsonrpc?: string
  id?: number
  method?: string
  params?: object
  result?: object
  error?: RpcError
}

export interface InitializeParams {
  cwd: string
  provider: string
  model: string
  reasoningEffort?: string
  maxTokens?: number
}

export interface InitializeResult {
  serverInfo?: ServerInfo
}

export interface ServerInfo {
  name: string
  version: string
}

export interface TextBlock {
  type: string
  text: string
}

export interface PromptParams {
  sessionId: string
  contentBlocks: TextBlock[]
}

export interface PromptResult {
  messageId?: string
}

/** session/resume and session/wait params: the persisted session identity. */
export interface SessionIdParams {
  sessionId: string
}

/** session/working-directory/set params: retarget a session's cwd. */
export interface WorkingDirectoryParams {
  sessionId: string
  path: string
}

/** Tolerant view of a content block: dsh adds block kinds over time. */
export interface BlockLike {
  type?: string
  text?: string
  thinking?: string
  name?: string
  input?: object
  content?: object
}

export interface MessageLike {
  role?: string
  content?: BlockLike[]
}

export interface SessionEventPayload {
  sessionId?: string
  event?: EventLike
}

/**
 * Session-log envelope. Verified against dsh 0.2.1-rc.2: every event is
 * `{type, seq, time, data}` — payload fields live under `data`, not at the top
 * level. Reading them flat yields undefined and an empty transcript.
 */
export interface EventLike {
  type?: string
  seq?: number
  time?: number
  data?: EventData
}

export interface TurnEndError {
  message?: string
  code?: string
  status?: number
}

export interface TurnEndReason {
  kind?: string
  error?: TurnEndError
}

export interface EventData {
  turn?: number
  step?: number
  message?: MessageLike
  name?: string
  arguments?: string
  callId?: string
  reason?: TurnEndReason
  title?: string
  usage?: object
}

export interface SessionStatusPayload {
  sessionId?: string
  status?: string
}

export interface SubagentPayload {
  parentSessionId?: string
  childSessionId?: string
  status?: string
  provider?: string
}

/** Connection lifecycle for the UI. */
export enum LinkState {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  READY = 'ready',
  FAILED = 'failed'
}

/** One framed JSON-RPC request, serialised with a trailing newline. */
export function encodeRequest(id: number, method: string, params: object | null): string {
  const frame: RpcFrame = { jsonrpc: '2.0', id: id, method: method }
  if (params !== null) {
    frame.params = params
  }
  return JSON.stringify(frame) + '\n'
}

/** Parse one line; returns null for diagnostics that are not protocol frames. */
export function decodeFrame(line: string): RpcFrame | null {
  const trimmed = line.trim()
  if (trimmed.length === 0 || trimmed.charAt(0) !== '{') {
    return null
  }
  try {
    return JSON.parse(trimmed) as RpcFrame
  } catch (error) {
    return null
  }
}
