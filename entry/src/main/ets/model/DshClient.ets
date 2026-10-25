import { socket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'
import {
  decodeFrame, encodeRequest, BlockLike, EventLike, InitializeParams, InitializeResult, LinkState,
  PromptParams, RpcFrame, SessionEventPayload, SessionIdParams, SessionStatusPayload, SubagentPayload,
  WorkingDirectoryParams
} from './Protocol'

/** Placeholder result for methods whose reply carries no payload (`shutdown`). */
class EmptyResult {}

/** A request waiting for its response frame. */
class Pending {
  id: number = 0
  method: string = ''
  resolve: ((value: object) => void) | null = null
  reject: ((error: Error) => void) | null = null
  timer: number = -1
}

/**
 * Client for the in-process dsh runtime.
 *
 * Transport: loopback TCP carrying newline-delimited JSON-RPC. The Node side
 * (host/bootstrap.cjs) hands the socket to the dsh SDK profile as its stdio,
 * so no HTTP surface, no auth token, and no WebView are involved.
 */
export class DshClient {
  private tcp: socket.TCPSocket | null = null
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  private carry: string = ''
  private nextId: number = 1
  private pending: Map<number, Pending> = new Map<number, Pending>()
  private state: LinkState = LinkState.IDLE
  private serverInfo: string = ''

  onState: ((state: LinkState, detail: string) => void) | null = null
  onEvent: ((payload: SessionEventPayload) => void) | null = null
  onStatus: ((payload: SessionStatusPayload) => void) | null = null
  onSubagent: ((payload: SubagentPayload) => void) | null = null

  getState(): LinkState {
    return this.state
  }

  getServerInfo(): string {
    return this.serverInfo
  }

  private setState(state: LinkState, detail: string): void {
    this.state = state
    if (this.onState !== null) {
      this.onState(state, detail)
    }
  }

  /** Connect to the bridge; resolves once the TCP session is established. */
  async connect(port: number): Promise<void> {
    // A stale socket from a previous attempt must be released first:
    // connecting twice on the same instance surfaces EINPROGRESS.
    if (this.tcp !== null) {
      this.close()
    }
    this.setState(LinkState.CONNECTING, `127.0.0.1:${port}`)
    const tcp = socket.constructTCPSocketInstance()
    this.tcp = tcp

    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onBytes(info.message)
    })
    tcp.on('close', () => {
      this.failAll(new Error('bridge closed'))
      this.setState(LinkState.FAILED, 'bridge closed')
    })
    tcp.on('error', (error: BusinessError) => {
      this.failAll(new Error(`bridge error ${error.code}`))
      this.setState(LinkState.FAILED, `socket ${error.code}`)
    })

    await tcp.bind({ address: '127.0.0.1', port: 0, family: 1 })
    await tcp.connect({
      address: { address: '127.0.0.1', port: port, family: 1 },
      timeout: 8000
    })
    this.setState(LinkState.READY, `127.0.0.1:${port}`)
  }

  /** Handshake: fixes the workspace and the model route for every session. */
  async initialize(cwd: string, provider: string, model: string): Promise<InitializeResult> {
    const params: InitializeParams = { cwd: cwd, provider: provider, model: model }
    const result = await this.request('initialize', params, 180000)
    const typed = result as InitializeResult
    if (typed.serverInfo !== undefined) {
      this.serverInfo = `${typed.serverInfo.name} ${typed.serverInfo.version}`
    }
    return typed
  }

  /** Queue one user turn; the reply is a durable enqueue receipt, not the answer. */
  async prompt(sessionId: string, text: string): Promise<string> {
    const params: PromptParams = {
      sessionId: sessionId,
      contentBlocks: [{ type: 'text', text: text }]
    }
    const result = await this.request('session/prompt', params, 30000)
    const typed = result as Record<string, string>
    const messageId = typed['messageId']
    return messageId === undefined ? '' : messageId
  }

  /**
   * Restore a persisted session so the next prompt continues its server-side
   * context (replayed from the .zstd log). Rejects when the log is missing
   * or the session is already open; it never creates a replacement.
   */
  async resume(sessionId: string): Promise<void> {
    const params: SessionIdParams = { sessionId: sessionId }
    await this.request('session/resume', params, 30000)
  }

  /**
   * Point a session at a new working directory. The directory must already
   * exist; the change persists into the session log and replays on resume,
   * so files the agent writes land under the new cwd across restarts.
   */
  async setWorkingDirectory(sessionId: string, path: string): Promise<void> {
    const params: WorkingDirectoryParams = { sessionId: sessionId, path: path }
    await this.request('session/working-directory/set', params, 30000)
  }

  /** Ask the runtime to drain and exit. */
  async shutdown(): Promise<void> {
    try {
      await this.request('shutdown', null, 10000)
    } catch (error) {
      // The runtime exits while answering; a lost response is expected.
    }
    this.close()
  }

  close(): void {
    this.failAll(new Error('closed by client'))
    if (this.tcp !== null) {
      this.tcp.off('message')
      this.tcp.off('close')
      this.tcp.off('error')
      this.tcp.close()
      this.tcp = null
    }
    this.setState(LinkState.IDLE, 'closed')
  }

  private request(method: string, params: object | null, timeoutMs: number): Promise<object> {
    return new Promise<object>((resolve, reject) => {
      const tcp = this.tcp
      if (tcp === null) {
        reject(new Error('bridge not connected'))
        return
      }
      const id = this.nextId
      this.nextId += 1
      const entry = new Pending()
      entry.id = id
      entry.method = method
      entry.resolve = resolve
      entry.reject = reject
      entry.timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method} timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.pending.set(id, entry)
      tcp.send({ data: encodeRequest(id, method, params) }).catch((error: BusinessError) => {
        this.pending.delete(id)
        clearTimeout(entry.timer)
        reject(new Error(`${method} send failed: ${error.message}`))
      })
    })
  }

  private onBytes(bytes: ArrayBuffer): void {
    const chunk = this.decoder.decodeWithStream(new Uint8Array(bytes), { stream: true })
    this.carry += chunk
    let index = this.carry.indexOf('\n')
    while (index >= 0) {
      const line = this.carry.substring(0, index)
      this.carry = this.carry.substring(index + 1)
      this.onLine(line)
      index = this.carry.indexOf('\n')
    }
  }

  private onLine(line: string): void {
    const frame = decodeFrame(line)
    if (frame === null) {
      return // diagnostic noise on the same stream
    }
    if (frame.id !== undefined && frame.method === undefined) {
      this.settle(frame)
      return
    }
    if (frame.method === 'session.event') {
      if (this.onEvent !== null && frame.params !== undefined) {
        this.onEvent(frame.params as SessionEventPayload)
      }
      return
    }
    if (frame.method === 'session.status') {
      if (this.onStatus !== null && frame.params !== undefined) {
        this.onStatus(frame.params as SessionStatusPayload)
      }
      return
    }
    if (frame.method === 'subagent.started' || frame.method === 'subagent.finished') {
      if (this.onSubagent !== null && frame.params !== undefined) {
        this.onSubagent(frame.params as SubagentPayload)
      }
    }
  }

  private settle(frame: RpcFrame): void {
    const id = frame.id
    if (id === undefined) {
      return
    }
    const entry = this.pending.get(id)
    if (entry === undefined) {
      return
    }
    this.pending.delete(id)
    clearTimeout(entry.timer)
    if (frame.error !== undefined) {
      if (entry.reject !== null) {
        entry.reject(new Error(`${entry.method}: ${frame.error.message}`))
      }
      return
    }
    if (entry.resolve !== null) {
      entry.resolve(frame.result === undefined ? new EmptyResult() : frame.result)
    }
  }

  private failAll(error: Error): void {
    this.pending.forEach((entry: Pending) => {
      clearTimeout(entry.timer)
      if (entry.reject !== null) {
        entry.reject(error)
      }
    })
    this.pending.clear()
  }
}

/** Shape of the text the runtime streams for one assistant step. */
export class RenderedBlock {
  kind: string = ''
  text: string = ''

  constructor(kind: string, text: string) {
    this.kind = kind
    this.text = text
  }
}

/** Flatten a model message into renderable blocks, tolerating unknown kinds. */
export function renderBlocks(event: EventLike): RenderedBlock[] {
  const out: RenderedBlock[] = []
  const content = event.data?.message?.content
  if (content === undefined) {
    return out
  }
  for (const block of content) {
    const typed = block as BlockLike
    const type = typed.type === undefined ? 'unknown' : typed.type
    if (type === 'text' && typed.text !== undefined && typed.text.length > 0) {
      out.push(new RenderedBlock('text', typed.text))
    } else if (type === 'reasoning' && typed.thinking !== undefined && typed.thinking.length > 0) {
      out.push(new RenderedBlock('reasoning', typed.thinking))
    } else if (type === 'reasoning') {
      // Empty reasoning blocks are common; they must not render a marker.
      continue
    } else if (type === 'tool_use') {
      const name = typed.name === undefined ? 'tool' : typed.name
      out.push(new RenderedBlock('tool', name))
    } else {
      out.push(new RenderedBlock(type, JSON.stringify(block)))
    }
  }
  return out
}
