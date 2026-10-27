import { socket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'
import { decodeFrame, encodeRequest, LinkState, RpcFrame } from './Protocol'
import {
  AcpCancelParams, AcpClientCapabilities, AcpCloseParams, AcpContentBlock, AcpInitializeParams, AcpInitializeResult,
  AcpPermissionPayload, AcpPermissionRequest, AcpPermissionResponse, AcpPermissionOutcome,
  AcpPromptParams, AcpPromptResult, AcpResumeParams, AcpSessionNewParams, AcpSessionNewResult,
  AcpSetConfigParams, AcpUpdatePayload, encodeNotification
} from './AcpProtocol'

/** A request waiting for its response frame. */
class AcpPending {
  id: number = 0
  method: string = ''
  resolve: ((value: object) => void) | null = null
  reject: ((error: Error) => void) | null = null
  timer: number = -1
}

/** Placeholder result for replies whose payload is empty. */
class AcpEmptyResult {
}

/**
 * Client for the ACP profile of the in-process dsh runtime.
 *
 * Same transport as DshClient (loopback TCP, newline-delimited JSON-RPC) but
 * the ACP method surface: server-generated session ids, a blocking
 * session/prompt answered by `{stopReason}`, streaming session/update
 * notifications, a fire-and-forget session/cancel, and server-initiated
 * approval requests the UI must answer (`allow-once` / `reject-once`,
 * fail-closed). The bridge keeps the runtime alive across socket drops;
 * after a reconnect `initialize` is idempotent and an active session is
 * continued by prompting it directly (never resume — AGENTS.md §4.2).
 *
 * The client does not reconnect by itself: a drop is reported once through
 * `onDisconnect` and the app shell owns the recovery (backoff, then the
 * reset semantics of SPIKE-ACP §11 for an orphaned turn).
 */
export class AcpClient {
  private tcp: socket.TCPSocket | null = null
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  private carry: string = ''
  private nextId: number = 1
  private pending: Map<number, AcpPending> = new Map<number, AcpPending>()
  private state: LinkState = LinkState.IDLE
  private serverInfo: string = ''
  /** Single-fire guard: 'error' and 'close' both fire for one drop. */
  private dropped: boolean = false

  onState: ((state: LinkState, detail: string) => void) | null = null
  onUpdate: ((payload: AcpUpdatePayload) => void) | null = null
  onPermission: ((request: AcpPermissionRequest) => void) | null = null
  onDisconnect: ((reason: string) => void) | null = null

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
    if (this.tcp !== null) {
      this.close()
    }
    this.dropped = false
    this.setState(LinkState.CONNECTING, `127.0.0.1:${port}`)
    const tcp = socket.constructTCPSocketInstance()
    this.tcp = tcp

    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onBytes(info.message)
    })
    tcp.on('close', () => {
      this.failAll(new Error('bridge closed'))
      this.setState(LinkState.FAILED, 'bridge closed')
      this.fireDisconnect('bridge closed')
    })
    tcp.on('error', (error: BusinessError) => {
      this.failAll(new Error(`bridge error ${error.code}`))
      this.setState(LinkState.FAILED, `socket ${error.code}`)
      this.fireDisconnect(`socket ${error.code}`)
    })

    await tcp.bind({ address: '127.0.0.1', port: 0, family: 1 })
    await tcp.connect({
      address: { address: '127.0.0.1', port: port, family: 1 },
      timeout: 8000
    })
    this.setState(LinkState.READY, `127.0.0.1:${port}`)
  }

  /** Handshake; idempotent, so a reconnect may simply send it again. */
  async initialize(): Promise<AcpInitializeResult> {
    const caps: AcpClientCapabilities = {}
    const params: AcpInitializeParams = { protocolVersion: 1, clientCapabilities: caps }
    const result = await this.request('initialize', params, 30000)
    const typed = result as AcpInitializeResult
    const agent = typed.agentInfo
    if (agent !== undefined) {
      const name = agent.name === undefined ? '' : agent.name
      const version = agent.version === undefined ? '' : agent.version
      this.serverInfo = `${name} ${version}`.trim()
    }
    return typed
  }

  /** Allocate a server-owned session rooted at the given cwd. */
  async sessionNew(cwd: string): Promise<AcpSessionNewResult> {
    const params: AcpSessionNewParams = { cwd: cwd, mcpServers: [] }
    const result = await this.request('session/new', params, 30000)
    return result as AcpSessionNewResult
  }

  /**
   * Load a persisted session. Rejects with `already active` for a session the
   * server still holds — callers treat that as "already loaded" and prompt
   * the session directly instead of resuming.
   */
  async sessionResume(sessionId: string, cwd: string): Promise<AcpSessionNewResult> {
    const params: AcpResumeParams = { sessionId: sessionId, cwd: cwd, mcpServers: [] }
    const result = await this.request('session/resume', params, 30000)
    return result as AcpSessionNewResult
  }

  /**
   * Run one full turn; resolves when the server answers `{stopReason}`
   * (`end_turn` / `cancelled`). Stream content arrives as session/update
   * notifications while this promise is pending.
   */
  async sessionPrompt(sessionId: string, text: string): Promise<AcpPromptResult> {
    const block: AcpContentBlock = { type: 'text', text: text }
    const params: AcpPromptParams = { sessionId: sessionId, prompt: [block] }
    const result = await this.request('session/prompt', params, 600000)
    return result as AcpPromptResult
  }

  /**
   * Ask the running turn to stop. A notification: no id, no response frame;
   * the pending session/prompt settles with `{stopReason:"cancelled"}`.
   */
  sessionCancel(sessionId: string): void {
    const tcp = this.tcp
    if (tcp === null) {
      return
    }
    const params: AcpCancelParams = { sessionId: sessionId }
    tcp.send({ data: encodeNotification('session/cancel', params) }).catch((_error: BusinessError) => {
    })
  }

  /**
   * Close a session: it enters `session/list` and can be `session/resume`d.
   * Recovery closes an orphaned in-flight turn with this (SPIKE-ACP §11) —
   * its prompt response is lost with the dropped socket and its updates
   * carry no turn id, so the end of the turn is undetectable.
   */
  async sessionClose(sessionId: string): Promise<void> {
    const params: AcpCloseParams = { sessionId: sessionId }
    await this.request('session/close', params, 30000)
  }

  /**
   * Switch one config option. `value` for `model` is a JSON array string
   * (e.g. '["deepseek-official","deepseek-flash"]'); the response carries the
   * new authoritative `configOptions` — the option list shrinks as choices
   * are made, so the caller must rebuild its picker from every response.
   */
  async setConfigOption(sessionId: string, configId: string, value: string): Promise<object> {
    const params: AcpSetConfigParams = { sessionId: sessionId, configId: configId, value: value }
    return await this.request('session/set_config_option', params, 30000)
  }

  /** Answer a server-initiated approval request; fail-closed upstream. */
  respondPermission(id: number, optionId: string): void {
    const tcp = this.tcp
    if (tcp === null) {
      return
    }
    const outcome: AcpPermissionOutcome = { outcome: 'selected', optionId: optionId }
    const body: AcpPermissionResponse = { outcome: outcome }
    const frame: RpcFrame = { jsonrpc: '2.0', id: id, result: body }
    tcp.send({ data: JSON.stringify(frame) + '\n' }).catch((_error: BusinessError) => {
    })
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

  /**
   * Report an unexpected transport drop exactly once (deliberate `close()`
   * unregisters the handlers first, so it never reaches here).
   */
  private fireDisconnect(reason: string): void {
    if (this.dropped) {
      return
    }
    this.dropped = true
    if (this.onDisconnect !== null) {
      this.onDisconnect(reason)
    }
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
      const entry = new AcpPending()
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
    const id = frame.id
    const method = frame.method
    if (method !== undefined && id !== undefined) {
      // Server-initiated request (approval); every known one is a permission.
      if (method === 'session/request_permission') {
        const request = new AcpPermissionRequest()
        request.id = id
        request.payload = frame.params === undefined ? null : frame.params as AcpPermissionPayload
        if (this.onPermission !== null) {
          this.onPermission(request)
        }
      }
      return
    }
    if (method !== undefined) {
      // Notification; the only one on this profile is session/update.
      if (method === 'session/update') {
        if (this.onUpdate !== null && frame.params !== undefined) {
          this.onUpdate(frame.params as AcpUpdatePayload)
        }
      }
      return
    }
    if (id !== undefined) {
      this.settle(frame)
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
      entry.resolve(frame.result === undefined ? new AcpEmptyResult() : frame.result)
    }
  }

  private failAll(error: Error): void {
    this.pending.forEach((entry: AcpPending) => {
      clearTimeout(entry.timer)
      if (entry.reject !== null) {
        entry.reject(error)
      }
    })
    this.pending.clear()
  }
}
