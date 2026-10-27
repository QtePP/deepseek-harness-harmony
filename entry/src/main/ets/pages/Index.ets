import { common } from '@kit.AbilityKit'
import { BootPhase, NodeHost } from '../host/NodeHost'
import { AppConfig } from '../common/AppConfig'
import { PluginConfig } from '../common/PluginConfig'
import { PluginCatalog, PluginRow } from '../model/PluginCatalog'
import { ChatMessage, Role, SessionStore, SessionSummary, newSessionId, titleOf } from '../model/ChatModel'
import { ProjectStore, ProjectSummary } from '../model/ProjectModel'
import { renderBlocks, RenderedBlock } from '../model/DshClient'
import { EventLike, SessionEventPayload, SessionStatusPayload } from '../model/Protocol'
import {
  AcpConfigOption, AcpModelChoice, AcpPermissionRequest, AcpSessionNewResult, AcpSetConfigResult,
  AcpUpdatePayload, findConfigOption, flattenChoices
} from '../model/AcpProtocol'
import { BootView } from '../view/BootView'
import { ChatView, FileRef } from '../view/ChatView'
import { FileViewer } from '../view/FileViewer'
import { SessionRail } from '../view/SessionRail'
import { SettingsSheet } from '../view/SettingsSheet'

/**
 * App shell.
 *
 * Everything the user touches runs on the device: the ArkUI surface here, the
 * dsh runtime inside the same process, and a loopback TCP bridge between them.
 * Layout switches at 840vp — rail + chat on tablets/2in1, chat only on phones
 * (the rail then lives in a sheet). Chat-created files open in a full-screen
 * viewer cover; capabilities are toggled through a user patch file.
 */
@Entry
@Component
struct Index {
  @State phase: BootPhase = BootPhase.IDLE
  @State detail: string = ''
  @State messages: ChatMessage[] = []
  @State sessions: SessionSummary[] = []
  @State currentId: string = ''
  @State running: boolean = false
  @State showSettings: boolean = false
  @State showSessions: boolean = false
  @State showViewer: boolean = false
  @State viewerPath: string = ''
  @State viewerName: string = ''
  @State diagnostics: string = ''
  @State widthVp: number = 360
  @State title: string = '新会话'
  @State pluginRows: PluginRow[] = []
  @State projects: ProjectSummary[] = []
  @State currentProjectId: string = ProjectStore.DEFAULT_ID
  @State showModelPicker: boolean = false
  @State modelLabel: string = ''
  @State showModelSheet: boolean = false
  @State modelChoices: AcpModelChoice[] = []
  @State approvalVisible: boolean = false
  @State approvalText: string = ''

  private host: NodeHost = NodeHost.get()
  private store: SessionStore = new SessionStore()
  private projectStore: ProjectStore = new ProjectStore()
  private context: common.UIAbilityContext | null = null
  /** Session ids the runtime already owns in this process (prompted/resumed). */
  private openedSessions: Set<string> = new Set<string>()
  /** In-flight session opens, deduped per id. */
  private openingSessions: Map<string, Promise<void>> = new Map<string, Promise<void>>()
  /** Server approval waiting for the user; null once answered. */
  private approvalRequest: AcpPermissionRequest | null = null
  /** Live assistant bubble being filled by streaming chunks. */
  private liveAssistant: ChatMessage | null = null
  /** Current model config value (JSON array string on the wire). */
  private currentModelValue: string = ''
  /** A reconnect chain is running; at most one may exist. */
  private reconnecting: boolean = false
  /** A turn was in flight when the bridge socket dropped. */
  private turnInFlight: boolean = false
  /** A drop that arrived while the reconnect chain was already running. */
  private redispatchDisconnect: string = ''

  aboutToAppear(): void {
    void this.init()
  }

  private async init(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    this.context = context
    await AppConfig.load(context)
    await PluginConfig.load(context)
    this.pluginRows = PluginCatalog.rows(PluginConfig.disabled)
    await this.projectStore.init(context)
    this.projects = await this.projectStore.list()
    this.currentProjectId = await this.projectStore.loadLastSelected()
    await this.store.init(context)
    this.sessions = await this.store.list(this.currentProjectId)
    await this.restoreLatest()

    this.host.client.onEvent = (payload: SessionEventPayload) => {
      this.handleEvent(payload)
    }
    this.host.client.onStatus = (payload: SessionStatusPayload) => {
      if (payload.sessionId === this.currentId && payload.status !== undefined) {
        this.running = payload.status === 'running'
      }
    }
    this.host.acp.onUpdate = (payload: AcpUpdatePayload) => {
      this.handleAcpUpdate(payload)
    }
    this.host.acp.onPermission = (request: AcpPermissionRequest) => {
      this.handleAcpPermission(request)
    }
    this.host.acp.onDisconnect = (reason: string) => {
      this.handleAcpDisconnect(reason)
    }
    await this.boot()
    // ACP session ids come from the server: a fresh app start with no
    // persisted conversation opens one immediately so the first prompt and
    // the model picker have a live session to target.
    await this.ensureAcpCurrentSession()
  }

  /** Cold start / project switch: open the most recent conversation of the current project. */
  private async restoreLatest(): Promise<void> {
    this.running = false
    if (this.sessions.length === 0) {
      this.currentId = newSessionId()
      this.messages = []
      this.title = '新会话'
      return
    }
    const latest = this.sessions[0]
    this.currentId = latest.id
    this.messages = await this.store.load(latest.id)
    this.title = latest.title
  }

  private async boot(): Promise<void> {
    if (this.context === null) {
      return
    }
    await this.host.boot(this.context, (phase: BootPhase, detail: string) => {
      this.phase = phase
      this.detail = detail
    })
  }

  private append(message: ChatMessage): void {
    const next = this.messages.slice()
    next.push(message)
    this.messages = next
  }

  private handleEvent(payload: SessionEventPayload): void {
    if (payload.sessionId !== this.currentId) {
      return
    }
    const event: EventLike | undefined = payload.event
    if (event === undefined) {
      return
    }
    const type = event.type === undefined ? '' : event.type

    if (type === 'assistant/message') {
      const blocks: RenderedBlock[] = renderBlocks(event)
      let text = ''
      const notes: string[] = []
      for (const block of blocks) {
        if (block.kind === 'text') {
          text += block.text
        } else if (block.kind === 'reasoning') {
          notes.push('思考')
        } else {
          notes.push(block.text)
        }
      }
      if (text.trim().length === 0) {
        return
      }
      this.append(new ChatMessage(newSessionId(), Role.ASSISTANT, text, notes.join(' · ')))
      void this.persist()
      return
    }

    if (type === 'tool/call') {
      const name = event.data?.name === undefined ? '工具' : event.data?.name
      const args = event.data?.arguments === undefined ? '' : event.data?.arguments
      const preview = args.length > 160 ? args.substring(0, 160) + '…' : args
      this.append(new ChatMessage(newSessionId(), Role.TOOL, `${name}\n${preview}`, '工具调用'))
      return
    }

    if (type === 'tool/result') {
      const kind = event.data?.reason?.kind
      const reason = kind === undefined ? '完成' : kind
      this.append(new ChatMessage(newSessionId(), Role.TOOL, reason, '工具结果'))
      return
    }

    if (type === 'session/title') {
      // The runtime derives a fallback title from the first prompt; prefer it.
      const title = event.data?.title
      if (title !== undefined && title.length > 0) {
        this.title = title
      }
      return
    }

    if (type === 'turn/end') {
      this.running = false
      const reason = event.data?.reason
      if (reason !== undefined && reason.error !== undefined) {
        const err = reason.error
        const note = err.code !== undefined && err.code.length > 0 ? err.code : '错误'
        const text = err.message !== undefined && err.message.length > 0 ? err.message : '回合失败'
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM, text, note))
      }
      void this.persist()
      return
    }
  }

  private async persist(): Promise<void> {
    if (this.messages.length === 0) {
      return
    }
    await this.store.save(this.currentId, this.currentProjectId, this.title, this.messages)
    this.sessions = await this.store.list(this.currentProjectId)
  }

  /**
   * Make the runtime own this session before its first prompt in this
   * process. Any persisted log — even one holding only a working-directory
   * switch — resumes, replaying the saved cwd with it; ids without a log
   * start fresh, and non-default projects first point the session at the
   * project workspace so its files land there. In-flight opens dedupe on
   * one promise per id.
   */
  private ensureSessionOpen(id: string, projectId: string): Promise<void> {
    if (this.openedSessions.has(id)) {
      return Promise.resolve()
    }
    const pending = this.openingSessions.get(id)
    if (pending !== undefined) {
      return pending
    }
    const task = this.openSessionOnRuntime(id, projectId)
    this.openingSessions.set(id, task)
    return task
  }

  private async openSessionOnRuntime(id: string, projectId: string): Promise<void> {
    try {
      try {
        await this.host.client.resume(id)
        this.openedSessions.add(id)
        return
      } catch (error) {
        const message = (error as Error).message
        if (!message.includes('not found')) {
          this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
            `会话上下文未能从服务端恢复，将按新上下文继续：${message}`, '会话恢复'))
        }
      }
      if (projectId !== ProjectStore.DEFAULT_ID && this.context !== null) {
        ProjectStore.ensureWorkspace(this.context, projectId)
        const dir = ProjectStore.workspaceDir(this.context, projectId)
        try {
          await this.host.client.setWorkingDirectory(id, dir)
          this.openedSessions.add(id)
        } catch (error) {
          this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
            `项目工作区设置失败，本次将在默认工作区运行：${(error as Error).message}`, '项目'))
        }
      }
    } finally {
      this.openingSessions.delete(id)
    }
  }

  private async send(text: string): Promise<void> {
    if (this.host.isAcp()) {
      await this.sendAcp(text)
      return
    }
    if (this.messages.length === 0) {
      this.title = titleOf(text)
    }
    this.append(new ChatMessage(newSessionId(), Role.USER, text, ''))
    void this.persist()
    await this.ensureSessionOpen(this.currentId, this.currentProjectId)
    this.running = true
    try {
      await this.host.client.prompt(this.currentId, text)
      this.openedSessions.add(this.currentId)
    } catch (error) {
      this.running = false
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM, `发送失败：${(error as Error).message}`, '错误'))
    }
  }

  /**
   * ACP session ids are minted by the server, so an empty conversation needs
   * one allocated before the first prompt. Runs after boot and after project
   * switches; conversations restored from the store keep their server id and
   * resume lazily on first send instead.
   */
  private async ensureAcpCurrentSession(): Promise<void> {
    if (!this.host.isAcp() || this.phase !== BootPhase.READY) {
      return
    }
    if (this.openedSessions.has(this.currentId) || this.messages.length > 0) {
      return
    }
    const created = await this.createAcpSession()
    if (created.length > 0) {
      this.currentId = created
    }
  }

  /** Allocate a server-owned session rooted at the project workspace. */
  private async createAcpSession(): Promise<string> {
    if (this.context === null) {
      return ''
    }
    const cwd = ProjectStore.workspaceDir(this.context, this.currentProjectId)
    if (this.currentProjectId !== ProjectStore.DEFAULT_ID) {
      ProjectStore.ensureWorkspace(this.context, this.currentProjectId)
    }
    try {
      const result = await this.host.acp.sessionNew(cwd)
      const sessionId = result.sessionId === undefined ? '' : result.sessionId
      if (sessionId.length === 0) {
        throw new Error('session/new 未返回 sessionId')
      }
      this.openedSessions.add(sessionId)
      this.applyAcpConfig(result)
      return sessionId
    } catch (error) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM, `新建会话失败：${(error as Error).message}`, '错误'))
      return ''
    }
  }

  /**
   * Make the server own the current session before prompting it. Resumed
   * sessions replay their server-side context; `already active` (reconnect)
   * counts as loaded; an id the server never saw is replaced by a fresh
   * session so the conversation can continue, at the cost of its context.
   */
  private async ensureAcpSession(): Promise<void> {
    if (this.context === null || this.openedSessions.has(this.currentId)) {
      return
    }
    const cwd = ProjectStore.workspaceDir(this.context, this.currentProjectId)
    try {
      const restored = await this.host.acp.sessionResume(this.currentId, cwd)
      this.openedSessions.add(this.currentId)
      this.applyAcpConfig(restored)
      return
    } catch (error) {
      const message = (error as Error).message
      if (message.includes('already active')) {
        this.openedSessions.add(this.currentId)
        return
      }
    }
    const created = await this.createAcpSession()
    if (created.length === 0) {
      return
    }
    this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
      '原会话上下文在服务端不可用，已新开会话继续（历史消息仍在下方）。', '会话'))
    this.currentId = created
  }

  /** One ACP turn: stream chunks into a live bubble, settle on stopReason. */
  private async sendAcp(text: string): Promise<void> {
    if (this.messages.length === 0) {
      this.title = titleOf(text)
    }
    this.append(new ChatMessage(newSessionId(), Role.USER, text, ''))
    void this.persist()
    if (this.reconnecting) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
        '连接正在恢复，该消息未发送，请稍后重发。', '连接'))
      return
    }
    await this.ensureAcpSession()
    this.running = true
    this.liveAssistant = null
    this.turnInFlight = true
    try {
      const result = await this.host.acp.sessionPrompt(this.currentId, text)
      this.turnInFlight = false
      this.running = false
      this.liveAssistant = null
      const stop = result.stopReason === undefined ? '' : result.stopReason
      if (stop === 'cancelled') {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM, '本轮已取消', '取消'))
      } else if (stop !== 'end_turn' && stop.length > 0) {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM, `回合结束：${stop}`, '结束'))
      }
      void this.persist()
    } catch (error) {
      this.turnInFlight = false
      this.running = false
      this.liveAssistant = null
      // A transport drop is explained by the reconnect flow instead; every
      // other failure stays a plain send error.
      const message = (error as Error).message
      if (!this.isTransportDrop(message)) {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM, `发送失败：${message}`, '错误'))
      }
    }
  }

  /** Whether an error message describes the bridge socket dropping. */
  private isTransportDrop(message: string): boolean {
    return message.includes('bridge closed') || message.includes('bridge error') ||
      message.includes('bridge not connected') || message.includes('send failed')
  }

  /** Render one session/update notification into the transcript. */
  private handleAcpUpdate(payload: AcpUpdatePayload): void {
    if (payload.sessionId !== this.currentId) {
      return
    }
    const update = payload.update
    if (update === undefined) {
      return
    }
    const kind = update.sessionUpdate === undefined ?
      (update.type === undefined ? '' : update.type) : update.sessionUpdate
    if (kind === 'agent_message_chunk') {
      const text = update.content === undefined ? '' : (update.content.text === undefined ? '' : update.content.text)
      if (text.length === 0) {
        return
      }
      if (this.liveAssistant === null) {
        const fresh = new ChatMessage(newSessionId(), Role.ASSISTANT, text, '')
        this.liveAssistant = fresh
        this.append(fresh)
      } else {
        this.liveAssistant.text += text
      }
      return
    }
    if (kind === 'agent_thought_chunk') {
      if (this.liveAssistant !== null && this.liveAssistant.note.length === 0) {
        this.liveAssistant.note = '思考中…'
      }
      return
    }
    if (kind === 'tool_call') {
      const title = update.title === undefined ?
        (update.toolKind === undefined ? '工具调用' : update.toolKind) : update.title
      this.append(new ChatMessage(newSessionId(), Role.TOOL, title, '工具调用'))
      return
    }
    if (kind === 'tool_call_update') {
      if (update.status === 'failed') {
        this.append(new ChatMessage(newSessionId(), Role.TOOL, '工具执行失败', '工具结果'))
      }
      return
    }
    if (kind === 'usage_update') {
      if (this.liveAssistant !== null) {
        const used = update.used === undefined ? 0 : update.used
        const size = update.size === undefined ? 0 : update.size
        this.liveAssistant.note = `上下文 ${used}/${size}`
      }
    }
  }

  /** Surface a server approval request; unanswered dialogs fail closed. */
  private handleAcpPermission(request: AcpPermissionRequest): void {
    this.approvalRequest = request
    const payload = request.payload
    let title = '工具请求'
    if (payload !== null && payload.toolCall !== undefined && payload.toolCall.title !== undefined &&
      payload.toolCall.title.length > 0) {
      title = payload.toolCall.title
    }
    this.approvalText = title
    this.approvalVisible = true
  }

  private answerApproval(allow: boolean): void {
    const request = this.approvalRequest
    this.approvalRequest = null
    this.approvalVisible = false
    if (request === null) {
      return
    }
    this.host.acp.respondPermission(request.id, allow ? 'allow-once' : 'reject-once')
  }

  private stopAcp(): void {
    if (!this.running) {
      return
    }
    this.host.acp.sessionCancel(this.currentId)
  }

  /**
   * The bridge socket dropped unexpectedly (a probe stole the single client
   * slot, or a transport failure). The bridge keeps the runtime alive, so
   * recovery needs no app restart: reconnect after a backoff that leaves
   * short probe experiments alone, then either reattach quietly (no turn
   * was lost) or run the reset semantics of SPIKE-ACP §11 for an orphaned
   * turn — close it (its response is lost with the socket and its end is
   * undetectable), resume the session, and tell the user to resend.
   */
  private handleAcpDisconnect(reason: string): void {
    if (this.phase !== BootPhase.READY) {
      return
    }
    if (this.reconnecting) {
      // The running chain notices the new drop and restarts itself.
      this.redispatchDisconnect = reason
      return
    }
    this.reconnecting = true
    const orphan = this.turnInFlight
    this.turnInFlight = false
    this.running = false
    this.liveAssistant = null
    // Any pending approval belongs to the dropped connection's request; the
    // orphaned turn (if any) is closed below, so the dialog is moot.
    this.approvalRequest = null
    this.approvalVisible = false
    this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
      `与 dsh 运行时的连接中断（${reason}），正在重新连接…`, '连接'))
    void this.persist()
    void this.reconnectAcp(orphan)
  }

  /** Backoff chain: 2 min first, doubling, capped at 5 min, 6 attempts. */
  private async reconnectAcp(orphan: boolean): Promise<void> {
    let delayMs = 120000
    for (let attempt = 0; attempt < 6; attempt++) {
      await this.delay(delayMs)
      if (this.phase !== BootPhase.READY) {
        this.finishReconnect()
        return
      }
      try {
        await this.host.acp.connect(AppConfig.BRIDGE_PORT)
        await this.host.acp.initialize()
        await this.reattachAcp(orphan)
        this.finishReconnect()
        return
      } catch (error) {
        delayMs = Math.min(delayMs * 2, 300000)
      }
    }
    this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
      '重新连接失败：请检查运行时状态后重启应用。', '连接'))
    void this.persist()
    this.finishReconnect()
  }

  /** End the chain; restart immediately if another drop queued meanwhile. */
  private finishReconnect(): void {
    this.reconnecting = false
    const reason = this.redispatchDisconnect
    if (reason.length > 0) {
      this.redispatchDisconnect = ''
      this.handleAcpDisconnect(reason)
    }
  }

  /**
   * After a successful reconnect: a session whose turn was orphaned is
   * closed and resumed (reset semantics); an idle session stays active
   * server-side and is simply prompted directly on the next send. A
   * transport failure here throws so the reconnect chain retries.
   */
  private async reattachAcp(orphan: boolean): Promise<void> {
    if (this.context === null || !orphan) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM, '已重新连接。', '连接'))
      void this.persist()
      return
    }
    try {
      await this.host.acp.sessionClose(this.currentId)
    } catch (error) {
      const message = (error as Error).message
      if (this.isTransportDrop(message) || message.includes('timed out')) {
        throw error as Error
      }
      // Already closed server-side (e.g. the probe that took the slot) —
      // the resume below still applies.
    }
    try {
      const cwd = ProjectStore.workspaceDir(this.context, this.currentProjectId)
      const restored = await this.host.acp.sessionResume(this.currentId, cwd)
      this.openedSessions.add(this.currentId)
      this.applyAcpConfig(restored)
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
        '已重新连接。断线时的那一轮已中断，需要的话请重发该消息。', '连接'))
    } catch (error) {
      const message = (error as Error).message
      if (this.isTransportDrop(message) || message.includes('timed out')) {
        throw error as Error
      }
      this.openedSessions.delete(this.currentId)
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
        '已重新连接，但原会话在服务端已不可用；下次发送将自动新开会话继续。', '连接'))
    }
    void this.persist()
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve()
      }, ms)
    })
  }

  /**
   * Adopt the authoritative configOptions carried by session/new, resume and
   * set_config_option responses. The option list shrinks as selections are
   * made, so every response rebuilds the picker; a cached list goes stale.
   */
  private applyAcpConfig(result: AcpSessionNewResult): void {
    const model = findConfigOption(result.configOptions, 'model')
    if (model === null) {
      this.showModelPicker = false
      return
    }
    this.modelChoices = flattenChoices(model.options)
    this.currentModelValue = model.currentValue === undefined ? '' : model.currentValue
    let label = ''
    for (const choice of this.modelChoices) {
      if (choice.value === this.currentModelValue) {
        label = choice.name
        break
      }
    }
    this.modelLabel = label.length === 0 ? '模型' : label
    this.showModelPicker = this.modelChoices.length > 1
  }

  private async pickModel(choice: AcpModelChoice): Promise<void> {
    this.showModelSheet = false
    if (choice.value === this.currentModelValue) {
      return
    }
    if (!this.openedSessions.has(this.currentId)) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM, '会话尚未在服务端激活，请先发送一条消息。', '模型'))
      return
    }
    try {
      const raw = await this.host.acp.setConfigOption(this.currentId, 'model', choice.value)
      const typed = raw as AcpSetConfigResult
      const wrapped: AcpSessionNewResult = { configOptions: typed.configOptions }
      this.applyAcpConfig(wrapped)
    } catch (error) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
        `模型切换失败（该选项可能已不可用）：${(error as Error).message}`, '模型'))
    }
  }

  /** Profile and approval tier are boot-time env; persisted for next launch. */
  private async saveProfileChoice(profile: string, permissionMode: string): Promise<void> {
    if (this.context === null) {
      return
    }
    await AppConfig.saveRuntimeChoice(this.context, profile, permissionMode)
  }

  private async newSession(): Promise<void> {
    await this.persist()
    if (this.host.isAcp()) {
      const created = await this.createAcpSession()
      if (created.length === 0) {
        return // failure note already appended
      }
      this.currentId = created
      this.messages = []
      this.title = '新会话'
      this.running = false
      this.liveAssistant = null
      this.showSessions = false
      return
    }
    this.currentId = newSessionId()
    this.messages = []
    this.title = '新会话'
    this.running = false
    this.showSessions = false
  }

  private async openSession(id: string): Promise<void> {
    this.showSessions = false
    if (id === this.currentId) {
      return
    }
    await this.persist()
    this.currentId = id
    this.messages = await this.store.load(id)
    let title = '新会话'
    for (const row of this.sessions) {
      if (row.id === id) {
        title = row.title
        break
      }
    }
    this.title = title
    this.running = false
  }

  /**
   * Open a workspace file referenced from chat. Absolute paths (as emitted
   * by tool calls) pass through; relative paths resolve against the current
   * project's workspace, which is also the session's runtime cwd.
   */
  private openFile(ref: FileRef): void {
    if (this.context === null) {
      return
    }
    let path = ref.path
    if (!path.startsWith('/')) {
      path = `${ProjectStore.workspaceDir(this.context, this.currentProjectId)}/${path}`
    }
    this.viewerPath = path
    this.viewerName = ref.name
    this.showViewer = true
  }

  private currentProjectName(): string {
    for (const project of this.projects) {
      if (project.id === this.currentProjectId) {
        return project.name
      }
    }
    return ProjectStore.DEFAULT_NAME
  }

  /** Switch category: park the current conversation, then load the target's. */
  private async selectProject(id: string): Promise<void> {
    if (id === this.currentProjectId) {
      return
    }
    await this.persist()
    this.currentProjectId = id
    await this.projectStore.saveLastSelected(id)
    this.sessions = await this.store.list(id)
    await this.restoreLatest()
    await this.ensureAcpCurrentSession()
  }

  private async createProject(name: string): Promise<void> {
    if (this.context === null) {
      return
    }
    const project = await this.projectStore.create(this.context, name)
    this.projects = await this.projectStore.list()
    await this.selectProject(project.id)
  }

  private async renameProject(id: string, name: string): Promise<void> {
    await this.projectStore.rename(id, name)
    this.projects = await this.projectStore.list()
  }

  /**
   * Delete a project: its sessions move to the default category (their
   * runtime logs and workspace files stay untouched) and the strip falls
   * back to default when the removed one was active.
   */
  private async deleteProject(id: string): Promise<void> {
    if (id === ProjectStore.DEFAULT_ID) {
      return
    }
    if (id === this.currentProjectId) {
      await this.persist()
    }
    await this.store.reassignProject(id, ProjectStore.DEFAULT_ID)
    await this.projectStore.remove(id)
    this.projects = await this.projectStore.list()
    if (this.currentProjectId === id) {
      this.currentProjectId = ProjectStore.DEFAULT_ID
      await this.projectStore.saveLastSelected(ProjectStore.DEFAULT_ID)
      this.sessions = await this.store.list(ProjectStore.DEFAULT_ID)
      await this.restoreLatest()
    }
  }

  private async togglePlugin(id: string, enabled: boolean): Promise<void> {
    if (this.context === null) {
      return
    }
    await PluginConfig.setDisabled(this.context, id, !enabled)
    this.pluginRows = PluginCatalog.rows(PluginConfig.disabled)
  }

  private async saveSettings(key: string, model: string): Promise<void> {
    if (this.context === null) {
      return
    }
    await AppConfig.save(this.context, key, model)
    this.showSettings = false
  }

  private refreshDiagnostics(): void {
    if (this.context === null) {
      return
    }
    const lines: string[] = []
    lines.push(`phase: ${this.phase}`)
    lines.push(`detail: ${this.detail}`)
    lines.push(`server: ${this.host.isAcp() ? this.host.acp.getServerInfo() : this.host.client.getServerInfo()}`)
    lines.push(`profile: ${AppConfig.profile} (${AppConfig.permissionMode})`)
    lines.push(`crash: ${this.host.crashInfo()}`)
    lines.push('--- bridge ---')
    lines.push(this.host.bridgeStatus(this.context))
    lines.push('--- node log ---')
    for (const line of this.host.tail(120)) {
      lines.push(line)
    }
    this.diagnostics = lines.join('\n')
  }

  @Builder
  settingsSheet() {
    SettingsSheet({
      initialKey: AppConfig.apiKey,
      initialModel: AppConfig.model,
      initialProfile: AppConfig.profile,
      initialPermission: AppConfig.permissionMode,
      diagnostics: this.diagnostics,
      pluginRows: this.pluginRows,
      onSave: (key: string, model: string) => {
        void this.saveSettings(key, model)
      },
      onProfileChange: (profile: string, permissionMode: string) => {
        void this.saveProfileChoice(profile, permissionMode)
      },
      onRefreshDiagnostics: () => this.refreshDiagnostics(),
      onResetPayload: () => {
        this.diagnostics = '已标记重建；请彻底退出并重新打开应用。'
      },
      onTogglePlugin: (id: string, enabled: boolean) => {
        void this.togglePlugin(id, enabled)
      }
    })
  }

  @Builder
  sessionsSheet() {
    SessionRail({
      sessions: this.sessions,
      currentId: this.currentId,
      projects: this.projects,
      currentProjectId: this.currentProjectId,
      onSelect: (id: string) => {
        void this.openSession(id)
      },
      onNew: () => {
        void this.newSession()
      },
      onSelectProject: (id: string) => {
        void this.selectProject(id)
      },
      onNewProject: (name: string) => {
        void this.createProject(name)
      },
      onRenameProject: (id: string, name: string) => {
        void this.renameProject(id, name)
      },
      onDeleteProject: (id: string) => {
        void this.deleteProject(id)
      }
    })
  }

  @Builder
  viewerCover() {
    FileViewer({
      filePath: this.viewerPath,
      fileName: this.viewerName,
      onClose: () => {
        this.showViewer = false
      }
    })
  }

  build() {
    Stack() {
      if (this.phase !== BootPhase.READY) {
        BootView({
          phase: this.phase,
          detail: this.detail,
          onRetry: () => {
            void this.boot()
          },
          onShowDiagnostics: () => {
            this.refreshDiagnostics()
            this.showSettings = true
          }
        })
      } else {
        // Wrapper node for the viewer cover: bindContentCover must not share
        // a node with bindSheet (same-node binding breaks the full modal).
        Stack() {
          if (this.widthVp >= 840) {
            Row() {
              SessionRail({
                sessions: this.sessions,
                currentId: this.currentId,
                projects: this.projects,
                currentProjectId: this.currentProjectId,
                onSelect: (id: string) => {
                  void this.openSession(id)
                },
                onNew: () => {
                  void this.newSession()
                },
                onSelectProject: (id: string) => {
                  void this.selectProject(id)
                },
                onNewProject: (name: string) => {
                  void this.createProject(name)
                },
                onRenameProject: (id: string, name: string) => {
                  void this.renameProject(id, name)
                },
                onDeleteProject: (id: string) => {
                  void this.deleteProject(id)
                }
              })
                .width(260)

              Divider().vertical(true).color($r('app.color.divider'))

              ChatView({
                messages: $messages,
                running: this.running,
                title: this.title,
                projectName: this.currentProjectName(),
                showModelPicker: this.showModelPicker,
                modelLabel: this.modelLabel,
                canStop: this.host.isAcp(),
                onSend: (text: string) => {
                  void this.send(text)
                },
                onNewSession: () => {
                  void this.newSession()
                },
                onOpenSettings: () => {
                  this.refreshDiagnostics()
                  this.showSettings = true
                },
                onPickModel: () => {
                  this.showModelSheet = true
                },
                onStop: () => this.stopAcp(),
                onOpenFile: (ref: FileRef) => this.openFile(ref)
              })
                .layoutWeight(1)
            }
            .width('100%')
            .height('100%')
          } else {
            Column() {
              ChatView({
                messages: $messages,
                running: this.running,
                title: this.title,
                projectName: this.currentProjectName(),
                showModelPicker: this.showModelPicker,
                modelLabel: this.modelLabel,
                canStop: this.host.isAcp(),
                showSessionsEntry: true,
                onSend: (text: string) => {
                  void this.send(text)
                },
                onNewSession: () => {
                  void this.newSession()
                },
                onOpenSettings: () => {
                  this.refreshDiagnostics()
                  this.showSettings = true
                },
                onOpenSessions: () => {
                  this.showSessions = true
                },
                onPickModel: () => {
                  this.showModelSheet = true
                },
                onStop: () => this.stopAcp(),
                onOpenFile: (ref: FileRef) => this.openFile(ref)
              })
            }
            .width('100%')
            .height('100%')
            .bindSheet($$this.showSessions, this.sessionsSheet(), {
              height: SheetSize.LARGE,
              dragBar: true,
              onDisappear: () => {
                this.showSessions = false
              }
            })
          }
        }
        .bindContentCover($$this.showViewer, this.viewerCover(), {
          modalTransition: ModalTransition.DEFAULT,
          onDisappear: () => {
            this.showViewer = false
          }
        })
      }

      if (this.approvalVisible) {
        Column() {
          Column({ space: 12 }) {
            Text('工具请求审批')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            Text(this.approvalText)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Text('允许后本次工具改动将执行；拒绝则工具按失败处理。')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
            Row({ space: 10 }) {
              Button('拒绝')
                .layoutWeight(1)
                .backgroundColor($r('app.color.surface_muted'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => this.answerApproval(false))
              Button('允许')
                .layoutWeight(1)
                .onClick(() => this.answerApproval(true))
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(20)
          .width('86%')
          .constraintSize({ maxWidth: 460 })
          .borderRadius(16)
          .backgroundColor($r('app.color.background'))
          .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 8 })
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(0,0,0,0.4)')
      }

      if (this.showModelSheet) {
        Column() {
          Column({ space: 12 }) {
            Text('模型')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            Scroll() {
              Column({ space: 4 }) {
                ForEach(this.modelChoices, (choice: AcpModelChoice) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(choice.name)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                      if (choice.description.length > 0) {
                        Text(choice.description)
                          .fontSize(11)
                          .fontColor($r('app.color.text_tertiary'))
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    if (choice.value === this.currentModelValue) {
                      Text('当前')
                        .fontSize(11)
                        .fontColor($r('app.color.brand'))
                    }
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 8 })
                  .onClick(() => {
                    void this.pickModel(choice)
                  })
                }, (choice: AcpModelChoice) => choice.value)
              }
              .width('100%')
            }
            .constraintSize({ maxHeight: 360 })
            .width('100%')
            Text('选项列表来自服务端实时返回；切换后部分选项可能不再可用。')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
          .alignItems(HorizontalAlign.Start)
          .padding(20)
          .width('86%')
          .constraintSize({ maxWidth: 460 })
          .borderRadius(16)
          .backgroundColor($r('app.color.background'))
          .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 8 })
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.showModelSheet = false
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = Number(newValue.width)
      if (!Number.isNaN(width)) {
        this.widthVp = width
      }
    })
    .bindSheet($$this.showSettings, this.settingsSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      onDisappear: () => {
        this.showSettings = false
      }
    })
  }
}
