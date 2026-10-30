import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo as fs } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { BootPhase, NodeHost } from '../host/NodeHost'
import { AppConfig } from '../common/AppConfig'
import { PluginConfig } from '../common/PluginConfig'
import { PluginCatalog, PluginRow } from '../model/PluginCatalog'
import { ChatMessage, Role, SessionStore, SessionSummary, ToolTrace, newSessionId, titleOf } from '../model/ChatModel'
import { ProjectStore, ProjectSummary } from '../model/ProjectModel'
import { renderBlocks, RenderedBlock } from '../model/DshClient'
import { DirGrant } from '../host/DirGrant'
import { ShareInbox } from '../model/ShareInbox'
import { FileTouch, RollbackReport, SnapshotStore, writePathsOf } from '../model/Rollback'
import { EventLike, LinkState, SessionEventPayload, SessionStatusPayload } from '../model/Protocol'
import {
  AcpConfigOption, AcpContentBlock, AcpModelChoice, AcpPermissionRequest, AcpSessionNewResult,
  AcpSetConfigResult, AcpUpdatePayload, findConfigOption, flattenChoices, textOfUpdateContent,
  toolTextOfUpdateContent
} from '../model/AcpProtocol'
import { BootView } from '../view/BootView'
import { ChatView, FileRef } from '../view/ChatView'
import { FileViewer } from '../view/FileViewer'
import { FilesPanel } from '../view/FilesPanel'
import { SessionRail } from '../view/SessionRail'
import { SettingsSheet } from '../view/SettingsSheet'

/** dsh pass-through admission budget: encoded bytes and decoded pixels per image. */
const MAX_ATTACHMENT_BYTES = 4 * 1024 * 1024
const MAX_PASS_THROUGH_PIXELS = 2048 * 2048
/** Display caps for tool arguments and results carried on one tool row. */
const MAX_TOOL_INPUT_CHARS = 1200
const MAX_TOOL_OUTPUT_CHARS = 4000

/**
 * Argument fields worth surfacing on a collapsed tool row, in reading order.
 * `run_code` carries its program in `code`; the fs tools use `path`; search
 * uses `pattern` / `query`. Falling back to the whole JSON keeps exotic tools
 * legible without a per-tool renderer.
 */
const DIGEST_KEYS: string[] = [
  'command', 'code', 'query', 'pattern', 'path', 'file_path', 'filePath', 'url', 'prompt', 'language'
]

function clipText(text: string, max: number): string {
  return text.length > max ? `${text.substring(0, max)}…` : text
}

/** One-line-ish digest of a tool call's arguments for the collapsed row. */
function digestToolInput(raw: Record<string, Object> | undefined): string {
  if (raw === undefined) {
    return ''
  }
  for (const key of DIGEST_KEYS) {
    const value = raw[key]
    if (value === undefined) {
      continue
    }
    if (typeof value === 'string') {
      const text = value as string
      if (text.length > 0) {
        return clipText(text, MAX_TOOL_INPUT_CHARS)
      }
    }
  }
  try {
    return clipText(JSON.stringify(raw), MAX_TOOL_INPUT_CHARS)
  } catch (error) {
    return ''
  }
}

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
  @State showFiles: boolean = false
  @State filesTick: number = 0
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
  /** Share prefill landing in the composer (absorbed once by ChatView). */
  @State shareText: string = ''
  @State attachPaths: string[] = []

  private host: NodeHost = NodeHost.get()
  private store: SessionStore = new SessionStore()
  private projectStore: ProjectStore = new ProjectStore()
  private context: common.UIAbilityContext | null = null
  /** Session ids the runtime already owns in this process (prompted/resumed). */
  private openedSessions: Set<string> = new Set<string>()
  /** Tool trace entries of the live turn, keyed by toolCallId so updates land. */
  private toolRows: Map<string, ToolTrace> = new Map<string, ToolTrace>()
  /** Assistant row hosting the live turn's expandable tool trace. */
  private traceRow: ChatMessage | null = null
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
  /** Pre-turn file snapshots, keyed by turn key (see Rollback.ets). */
  private snapshots: SnapshotStore = new SnapshotStore()
  /** Files each rollback-able turn touched, keyed by turn key. */
  private turnTouches: Map<string, FileTouch[]> = new Map<string, FileTouch[]>()
  /** The turn currently accepting touches; '' when no turn is running. */
  private activeTurnKey: string = ''
  /** Per-message turn key, so a long-press can name the turn it rolls back. */
  private messageTurn: Map<string, string> = new Map<string, string>()
  /**
   * Streaming chunks buffered between frames.
   *
   * The runtime emits thought/message chunks far faster than the screen
   * refreshes, and each one used to reassign `reasoning`/`text`, so ArkUI
   * re-laid-out the row dozens of times a second and the transcript visibly
   * lagged the model. Batching them into one apply per ~60ms keeps the UI at
   * frame rate while the text still arrives incrementally.
   */
  private updateQueue: AcpUpdatePayload[] = []
  private updateTimer: number = -1

  aboutToAppear(): void {
    ShareInbox.setListener((text: string, imagePath: string, imageName: string) => {
      this.landShare(text, imagePath, imageName)
    })
    void this.init()
  }

  aboutToDisappear(): void {
    ShareInbox.clearListener()
  }

  /** A share landed: text prefills the draft, an image rides along as attachment. */
  private landShare(text: string, imagePath: string, imageName: string): void {
    if (text.length > 0) {
      this.shareText = text
    }
    if (imagePath.length > 0) {
      void this.attachSharedImage(imagePath, imageName)
    }
  }

  /**
   * Stage a shared image through the same JPEG transcode the picker uses.
   * Shared files arrive in whatever format the sender produced (PNG, HEIC,
   * oversized camera JPEG); only a clean JFIF inside the attachment budget
   * survives admission, and everything else would fail at request time.
   */
  private async attachSharedImage(path: string, name: string): Promise<void> {
    const staged = await this.transcodeToJpeg(path)
    if (staged === null) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
        `无法处理分享的图片${name.length > 0 ? `「${name}」` : ''}，请改用相册选择。`, '错误'))
      return
    }
    this.attachPaths = [staged]
  }

  private async init(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    this.context = context
    await AppConfig.load(context)
    await PluginConfig.load(context)
    this.pluginRows = PluginCatalog.rows(PluginConfig.disabled)
    await this.projectStore.init(context)
    this.projects = await this.projectStore.list()
    this.snapshots.init(context.filesDir)
    // Re-activate persisted directory grants so bound project workspaces are
    // reachable at their real paths; failure is non-fatal (the affected
    // project surfaces a clear error when its session opens).
    try {
      await DirGrant.activate(await this.projectStore.boundUris())
    } catch (error) {
      // Grants may be missing after a reinstall; binding again fixes it.
    }
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
      this.queueAcpUpdate(payload)
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
      let reasoning = ''
      const notes: string[] = []
      for (const block of blocks) {
        if (block.kind === 'text') {
          text += block.text
        } else if (block.kind === 'reasoning') {
          // Thinking is content, not a badge: keep it for the collapsible block.
          reasoning += block.text
        } else {
          notes.push(block.text)
        }
      }
      if (text.trim().length === 0 && reasoning.trim().length === 0) {
        return
      }
      const message = new ChatMessage(newSessionId(), Role.ASSISTANT, text, notes.join(' · '))
      message.reasoning = reasoning
      this.append(message)
      void this.persist()
      return
    }

    if (type === 'tool/call') {
      const name = event.data?.name === undefined ? '工具' : event.data?.name
      const args = event.data?.arguments === undefined ? '' : event.data?.arguments
      if (this.traceRow === null) {
        // The trace rides the assistant row this turn's thinking lives on;
        // a call before any message gets a fresh host row.
        let host: ChatMessage | null = null
        for (let index = this.messages.length - 1; index >= 0; index--) {
          if (this.messages[index].role === Role.ASSISTANT) {
            host = this.messages[index]
            break
          }
        }
        if (host === null) {
          host = new ChatMessage(newSessionId(), Role.ASSISTANT, '', '')
          this.append(host)
        }
        this.traceRow = host
      }
      const entry = new ToolTrace(name)
      entry.input = clipText(args, MAX_TOOL_INPUT_CHARS)
      entry.reasonOffset = this.traceRow.reasoning.length
      this.traceRow.trace = this.traceRow.trace.concat([entry])
      return
    }

    if (type === 'tool/result') {
      const kind = event.data?.reason?.kind
      const reason = kind === undefined ? '完成' : kind
      this.settleLatestTrace(reason)
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

  /** Settle the newest still-running trace entry (SDK profile carries no call id). */
  private settleLatestTrace(reason: string): void {
    if (this.traceRow === null) {
      return
    }
    const entries = this.traceRow.trace
    for (let index = entries.length - 1; index >= 0; index--) {
      const entry = entries[index]
      if (entry.status === 'completed' || entry.status === 'failed') {
        continue
      }
      entry.status = reason === 'error' ? 'failed' : 'completed'
      entry.doneAt = Date.now()
      entry.output = entry.output.length > 0 ? entry.output : reason
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

  // ---------------------------------------------------------------- rollback

  /** Open a new rollback-able turn and bind its key to the user message. */
  private beginTurn(userMessageId: string): void {
    const key = `${this.currentId}.${Date.now()}`
    this.activeTurnKey = key
    this.turnTouches.set(key, [])
    this.messageTurn.set(userMessageId, key)
  }

  /**
   * Record the pre-turn state of every path a write call names. Called on
   * `tool_call`, before the tool body runs, which is the only moment the old
   * bytes are still on disk.
   */
  private captureTouches(name: string, raw: Record<string, Object> | undefined): void {
    if (this.activeTurnKey.length === 0 || !this.snapshots.ready()) {
      return
    }
    // Same cwd the session itself was opened with, so a relative tool path
    // resolves to the file the tool actually wrote.
    const cwd = this.workspaceOf(this.currentProjectId)
    for (const path of writePathsOf(name, raw, cwd)) {
      const list = this.turnTouches.get(this.activeTurnKey)
      if (list === undefined) {
        continue
      }
      // One snapshot per path per turn: a later write to the same file must
      // not overwrite the original bytes with the turn's own intermediate.
      let seen = false
      for (const touch of list) {
        if (touch.path === path) {
          seen = true
          break
        }
      }
      if (seen) {
        continue
      }
      const touch = this.snapshots.capture(this.activeTurnKey, path)
      if (touch !== null) {
        list.push(touch)
      }
    }
  }

  /** Close the running turn; snapshots stay so it can still be rolled back. */
  private endTurn(): void {
    this.activeTurnKey = ''
  }

  /**
   * Roll one turn back: truncate the transcript at the message that opened it,
   * restore every file the turn touched, then rebuild the server session from
   * the shortened history. ACP has no truncate verb, so "rewinding" the model
   * means closing the old session and opening a fresh one.
   */
  private async rollbackTurn(messageId: string): Promise<void> {
    const turnKey = this.messageTurn.get(messageId)
    const index = this.messageIndex(messageId)
    if (index < 0) {
      return
    }
    const touches = turnKey === undefined ? [] : this.turnTouches.get(turnKey)
    const report = new RollbackReport()
    if (touches !== undefined) {
      for (const touch of touches) {
        this.snapshots.revert(touch, report)
      }
    }
    // Drop the message that opened the turn and everything after it: the turn
    // and its answer are exactly the suffix the user asked to take back.
    this.messages = this.messages.slice(0, index)
    this.attachPaths = []
    this.traceRow = null
    this.toolRows.clear()
    this.liveAssistant = null
    this.endTurn()
    if (turnKey !== undefined) {
      this.snapshots.discard(turnKey)
      this.turnTouches.delete(turnKey)
      this.messageTurn.delete(messageId)
    }
    await this.persist()
    await this.rebuildServerSession()
    this.toastRollback(report, index)
  }

  private messageIndex(messageId: string): number {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        return i
      }
    }
    return -1
  }

  private toastRollback(report: RollbackReport, remaining: number): void {
    const parts: string[] = []
    if (report.restored > 0) {
      parts.push(`还原 ${report.restored} 个文件`)
    }
    if (report.deleted > 0) {
      parts.push(`删除 ${report.deleted} 个新增文件`)
    }
    if (report.failed > 0) {
      parts.push(`${report.failed} 个未能回退`)
    }
    const filePart = parts.length > 0 ? `，${parts.join('、')}` : ''
    const message = remaining === 0
      ? `已回撤到会话开头${filePart}`
      : `已回撤到该消息之前${filePart}`
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 })
  }

  /**
   * Fork: copy the transcript up to (not including) the chosen message into a
   * new session and switch to it. The original session is left untouched, so
   * the user can explore an alternative without losing the first branch.
   */
  private async forkFrom(messageId: string): Promise<void> {
    const index = this.messageIndex(messageId)
    if (index <= 0) {
      return
    }
    const kept = this.messages.slice(0, index)
    const forkId = newSessionId()
    const forkTitle = `${this.title.length > 0 ? this.title : '会话'} · 分支`
    await this.store.save(forkId, this.currentProjectId, forkTitle, kept)
    this.currentId = forkId
    this.title = forkTitle
    this.messages = kept
    this.openedSessions.delete(forkId)
    this.traceRow = null
    this.toolRows.clear()
    this.liveAssistant = null
    this.sessions = await this.store.list(this.currentProjectId)
    await this.ensureAcpSession()
    this.getUIContext().getPromptAction().showToast({
      message: `已从该消息分支出新会话（保留 ${kept.length} 条）`,
      duration: 2500
    })
  }

  /**
   * Replace the server-side session with one built from the shortened
   * transcript. `session/close` retires the old id; the next prompt lazily
   * opens a fresh session whose history is exactly what is on screen.
   */
  private async rebuildServerSession(): Promise<void> {
    const oldId = this.currentId
    this.openedSessions.delete(oldId)
    try {
      if (this.host.isAcp() && this.host.acp.getState() === LinkState.READY) {
        await this.host.acp.sessionClose(oldId)
      }
    } catch (error) {
      // A session that was never opened server-side has nothing to close.
    }
    this.currentId = newSessionId()
    this.openedSessions.delete(this.currentId)
    this.toolRows.clear()
    this.traceRow = null
    this.liveAssistant = null
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
        if (this.boundOf(projectId) === null) {
          ProjectStore.ensureWorkspace(this.context, projectId)
        }
        const dir = this.workspaceOf(projectId)
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

  private async send(text: string, attachPaths: string[]): Promise<void> {
    if (this.host.isAcp()) {
      await this.sendAcp(text, attachPaths)
      return
    }
    if (attachPaths.length > 0) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM, 'SDK 通道暂不支持图片输入，本次仅发送文字。', '提示'))
    }
    if (text.length === 0) {
      return
    }
    if (this.messages.length === 0) {
      this.title = titleOf(text)
    }
    this.append(new ChatMessage(newSessionId(), Role.USER, text, ''))
    void this.persist()
    await this.ensureSessionOpen(this.currentId, this.currentProjectId)
    this.running = true
    this.traceRow = null
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
    const cwd = this.workspaceOf(this.currentProjectId)
    if (this.currentProjectId !== ProjectStore.DEFAULT_ID &&
      this.boundOf(this.currentProjectId) === null && this.context !== null) {
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
    const cwd = this.workspaceOf(this.currentProjectId)
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
  private async sendAcp(text: string, attachPaths: string[]): Promise<void> {
    const blocks: AcpContentBlock[] = []
    if (attachPaths.length > 0) {
      if (!this.host.acp.getImagePrompts()) {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
          '当前连接未开放图片输入：需默认模型为 DeepSeek-V4.1-Flash，修改后重启应用生效。', '提示'))
        return
      }
      for (const path of attachPaths) {
        const imageBlock = this.readImageBlock(path)
        if (imageBlock === null) {
          this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
            '附件图片不可发送：仅支持 PNG/JPEG/WebP/GIF，且不超过 15MB。', '错误'))
          return
        }
        blocks.push(imageBlock)
      }
    }
    if (text.length > 0) {
      const textBlock: AcpContentBlock = { type: 'text', text: text }
      blocks.push(textBlock)
    }
    if (blocks.length === 0) {
      return
    }
    if (this.messages.length === 0) {
      this.title = titleOf(text.length > 0 ? text : '图片请求')
    }
    // The label is derived from the image count at render time; storing a
    // literal here would freeze today's wording into persisted history.
    const user = new ChatMessage(newSessionId(), Role.USER, text, '')
    for (const path of attachPaths) {
      user.images.push(path)
    }
    user.image = attachPaths.length > 0 ? attachPaths[0] : ''
    this.append(user)
    this.attachPaths = []
    void this.persist()
    if (this.reconnecting) {
      this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
        '连接正在恢复，该消息未发送，请稍后重发。', '连接'))
      return
    }
    await this.ensureAcpSession()
    this.running = true
    this.liveAssistant = null
    this.traceRow = null
    this.toolRows.clear()
    this.turnInFlight = true
    // Open the rollback window before the prompt goes out, so tool calls that
    // arrive during this turn have somewhere to record their snapshots.
    this.beginTurn(user.id)
    try {
      const result = await this.host.acp.sessionPromptBlocks(this.currentId, blocks)
      this.turnInFlight = false
      this.running = false
      this.liveAssistant = null
      this.endTurn()
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
      this.endTurn()
      // A transport drop is explained by the reconnect flow instead; image
      // rejections get targeted advice; everything else stays a send error.
      const message = (error as Error).message
      if (this.isTransportDrop(message)) {
        return
      }
      if (message.includes('does not declare image input')) {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
          '当前会话模型不支持图片输入：点右上角「模型」切换到 DeepSeek-V4.1-Flash 后重试。', '提示'))
      } else if (message.includes('inline image prompts were not advertised')) {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
          '当前连接未开放图片输入：需默认模型为 DeepSeek-V4.1-Flash 并重启应用。', '提示'))
      } else {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM, `发送失败：${message}`, '错误'))
      }
    }
  }

  /** Whether an error message describes the bridge socket dropping. */
  private isTransportDrop(message: string): boolean {
    return message.includes('bridge closed') || message.includes('bridge error') ||
      message.includes('bridge not connected') || message.includes('send failed')
  }

  /**
   * Read one sandbox image into an inline ACP image block. The server only
   * accepts canonical base64 with the four raster MIME types; the 15MB cap
   * keeps the base64 frame well inside practical socket sizes.
   */
  private readImageBlock(path: string): AcpContentBlock | null {
    const mime = this.imageMimeOf(path)
    if (mime.length === 0) {
      return null
    }
    try {
      const stat = fs.statSync(path)
      if (stat.size <= 0 || stat.size > 15 * 1024 * 1024) {
        return null
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      const buffer = new ArrayBuffer(stat.size)
      fs.readSync(file.fd, buffer)
      fs.closeSync(file)
      const base64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer))
      const block: AcpContentBlock = { type: 'image', data: base64, mimeType: mime }
      return block
    } catch (error) {
      return null
    }
  }

  /** Wire MIME for the four accepted raster formats; '' means unsupported. */
  private imageMimeOf(path: string): string {
    const dot = path.lastIndexOf('.')
    const ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : ''
    if (ext === 'png') {
      return 'image/png'
    }
    if (ext === 'jpg' || ext === 'jpeg') {
      return 'image/jpeg'
    }
    if (ext === 'webp') {
      return 'image/webp'
    }
    if (ext === 'gif') {
      return 'image/gif'
    }
    return ''
  }

  /**
   * System photo picker (no permission needed): pick one image, transcode it
   * to JPEG so every source format (incl. HEIC/BMP) passes `readImageBlock`,
   * and stage it in the sandbox as the pending attachment.
   */
  private async pickImage(): Promise<void> {
    if (this.context === null) {
      return
    }
    try {
      const options = new photoAccessHelper.PhotoSelectOptions()
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
      options.maxSelectNumber = 9
      const picker = new photoAccessHelper.PhotoViewPicker()
      const selected = await picker.select(options)
      hilog.info(0x0000, 'PickImage', 'select returned %{public}d uris', selected.photoUris.length)
      if (selected.photoUris.length === 0) {
        return
      }
      const staged: string[] = []
      for (const uri of selected.photoUris) {
        const path = await this.transcodeToJpeg(uri)
        if (path !== null) {
          staged.push(path)
        }
      }
      if (staged.length === 0) {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
          '所选图片无法读取，请换一张重试。', '错误'))
        return
      }
      this.attachPaths = staged
    } catch (error) {
      const err = error as BusinessError
      hilog.warn(0x0000, 'PickImage', 'pick failed: %{public}d %{public}s',
        err.code === undefined ? 0 : err.code, err.message === undefined ? '' : err.message)
      if (err.message !== undefined && err.message.length > 0) {
        this.append(new ChatMessage(newSessionId(), Role.SYSTEM,
          `图片选择失败：${err.message}`, '错误'))
      }
    }
  }

  /**
   * Decode any picker URI (via fd; media URIs are not accepted directly) and re-encode as JPEG.
   * The output is kept inside dsh's pass-through normalization budget — single-frame,
   * metadata-free 8-bit sRGB at ≤ 2048² pixels and ≤ 4MB bytes — so the server never needs
   * its (unavailable on-device) sharp re-encoding path.
   */
  private async transcodeToJpeg(uri: string): Promise<string | null> {
    if (this.context === null) {
      return null
    }
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY)
    try {
      const source = image.createImageSource(src.fd)
      try {
        const pixel = await source.createPixelMap()
        const downscale = await this.fitPixelBudget(pixel)
        const packer = image.createImagePacker()
        try {
          for (const quality of [85, 75, 65, 55, 45]) {
            const option: image.PackingOption = { format: 'image/jpeg', quality: quality }
            const data = await packer.packing(pixel, option)
            if (data.byteLength <= MAX_ATTACHMENT_BYTES || quality === 45) {
              const path = this.writePickedJpeg(data)
              hilog.info(0x0000, 'PickImage',
                'packed %{public}d bytes at q%{public}d (downscaled: %{public}s)',
                data.byteLength, quality, `${downscale}`)
              return path
            }
          }
          return null
        } finally {
          packer.release()
          pixel.release()
        }
      } finally {
        source.release()
      }
    } catch (error) {
      hilog.warn(0x0000, 'PickImage', 'transcode failed: %{public}s', `${error}`)
      return null
    } finally {
      fs.closeSync(src)
    }
  }

  /**
   * Scale a decoded pixel map down to dsh's pass-through pixel budget (2048²).
   * PixelMap.applyScale takes width/height ratios (not target sizes); passing
   * target dimensions is silently ignored, so ratio semantics must be kept.
   */
  private async fitPixelBudget(pixel: image.PixelMap): Promise<boolean> {
    let info = await pixel.getImageInfo()
    let pixels = info.size.width * info.size.height
    if (pixels <= MAX_PASS_THROUGH_PIXELS) {
      return false
    }
    const ratio = Math.sqrt(MAX_PASS_THROUGH_PIXELS / pixels) * 0.98
    await pixel.applyScale(ratio, ratio, image.AntiAliasingLevel.MEDIUM)
    info = await pixel.getImageInfo()
    pixels = info.size.width * info.size.height
    if (pixels > MAX_PASS_THROUGH_PIXELS) {
      const retry = Math.sqrt(MAX_PASS_THROUGH_PIXELS / pixels) * 0.98
      await pixel.applyScale(retry, retry, image.AntiAliasingLevel.MEDIUM)
    }
    return true
  }

  /** Write transcoded JPEG bytes into filesDir/picked with a random name. */
  private writePickedJpeg(data: ArrayBuffer): string | null {
    if (this.context === null) {
      return null
    }
    const dir = `${this.context.filesDir}/picked`
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir)
    }
    const destPath = `${dir}/${util.generateRandomUUID(true)}.jpg`
    const file = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(file.fd, data)
    } finally {
      fs.closeSync(file)
    }
    return destPath
  }

  /** The assistant row streaming chunks land in; created on the first chunk. */
  private liveRow(): ChatMessage {
    if (this.liveAssistant === null) {
      const fresh = new ChatMessage(newSessionId(), Role.ASSISTANT, '', '')
      this.liveAssistant = fresh
      this.append(fresh)
    }
    return this.liveAssistant
  }

  /** Render one session/update notification into the transcript. */
  /** Buffer one chunk; a single timer drains the queue per frame. */
  private queueAcpUpdate(payload: AcpUpdatePayload): void {
    this.updateQueue.push(payload)
    if (this.updateTimer >= 0) {
      return
    }
    this.updateTimer = setTimeout(() => {
      this.updateTimer = -1
      this.drainAcpUpdates()
    }, 60)
  }

  private drainAcpUpdates(): void {
    if (this.updateQueue.length === 0) {
      return
    }
    const batch = this.updateQueue
    this.updateQueue = []
    for (const payload of batch) {
      this.handleAcpUpdate(payload)
    }
  }

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
      const text = textOfUpdateContent(update.content)
      if (text.length === 0) {
        return
      }
      const row = this.liveRow()
      row.text += text
      return
    }
    if (kind === 'agent_thought_chunk') {
      // Thinking arrives as its own stream before the answer; keep the text and
      // render it as a collapsible block instead of a transient "思考中…" note.
      // After a tool call froze the live row, thinking keeps flowing into the
      // trace host so the merged timeline stays chronological.
      const thought = textOfUpdateContent(update.content)
      if (thought.length === 0) {
        return
      }
      const row = this.traceRow !== null && this.liveAssistant === null ?
        this.traceRow : this.liveRow()
      row.reasoning += thought
      return
    }
    if (kind === 'tool_call') {
      const callId = update.toolCallId === undefined ? '' : update.toolCallId
      const name = update.title === undefined ?
        (update.toolKind === undefined ? '工具调用' : update.toolKind) : update.title
      // One trace per turn, hosted on the row that holds this turn's thinking:
      // each entry records the thinking length at attach so the renderer can
      // interleave calls with the thought stream in order.
      if (this.traceRow === null) {
        this.traceRow = this.liveRow()
      }
      const entry = new ToolTrace(name)
      entry.callId = callId
      entry.input = digestToolInput(update.rawInput)
      entry.reasonOffset = this.traceRow.reasoning.length
      entry.status = update.status === undefined ? 'in_progress' : update.status
      if (entry.status === 'completed' || entry.status === 'failed') {
        entry.doneAt = Date.now()
      }
      // Snapshot before the write lands: the tool call is announced first, so
      // this is the last moment the pre-turn bytes still exist on disk.
      this.captureTouches(name, update.rawInput)
      if (callId.length > 0) {
        this.toolRows.set(callId, entry)
      }
      // Freeze the live row so the answer opens a fresh bubble below the trace.
      this.liveAssistant = null
      this.traceRow.trace = this.traceRow.trace.concat([entry])
      return
    }
    if (kind === 'tool_call_update') {
      const callId = update.toolCallId === undefined ? '' : update.toolCallId
      const entry = callId.length > 0 ? this.toolRows.get(callId) : undefined
      if (entry === undefined) {
        return
      }
      if (update.status !== undefined && update.status.length > 0) {
        if ((update.status === 'completed' || update.status === 'failed') &&
          entry.status !== 'completed' && entry.status !== 'failed') {
          entry.doneAt = Date.now()
        }
        entry.status = update.status
      }
      const output = toolTextOfUpdateContent(update.content)
      if (output.length > 0) {
        entry.output = clipText(output, MAX_TOOL_OUTPUT_CHARS)
      }
      return
    }
    if (kind === 'usage_update') {
      const used = update.used === undefined ? 0 : update.used
      const size = update.size === undefined ? 0 : update.size
      const label = `上下文 ${used}/${size}`
      if (this.liveAssistant !== null) {
        this.liveAssistant.note = label
      } else {
        // The live row was frozen by a tool call; the usage note belongs to
        // the newest assistant row of this turn regardless.
        for (let index = this.messages.length - 1; index >= 0; index--) {
          if (this.messages[index].role === Role.ASSISTANT) {
            this.messages[index].note = label
            break
          }
        }
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
      const cwd = this.workspaceOf(this.currentProjectId)
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
      this.traceRow = null
      this.toolRows.clear()
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
    this.liveAssistant = null
    this.traceRow = null
    this.toolRows.clear()
  }

  /**
   * Delete one conversation end to end: close it server-side when this
   * process owns it, drop the cached index row and message blob, and remove
   * the durable server log under dsh-home. Workspace files survive — they
   * belong to the project, not the conversation.
   */
  private async deleteSession(id: string): Promise<void> {
    const isCurrent = id === this.currentId
    if (isCurrent && this.running) {
      this.getUIContext().getPromptAction().showToast({
        message: '本轮回复仍在进行，请先停止或等待完成',
        duration: 2500
      })
      return
    }
    if (this.host.isAcp() && this.openedSessions.has(id)) {
      try {
        await this.host.acp.sessionClose(id)
      } catch (error) {
        // Best effort: the local rows and the log dir go regardless.
      }
    }
    this.openedSessions.delete(id)
    await this.store.remove(id)
    this.deleteSessionLogs(id)
    this.sessions = await this.store.list(this.currentProjectId)
    if (!isCurrent) {
      return
    }
    this.running = false
    this.liveAssistant = null
    this.traceRow = null
    this.toolRows.clear()
    if (this.sessions.length === 0) {
      this.currentId = newSessionId()
      this.messages = []
      this.title = '新会话'
      await this.ensureAcpCurrentSession()
      return
    }
    const latest = this.sessions[0]
    this.currentId = latest.id
    this.messages = await this.store.load(latest.id)
    this.title = latest.title
  }

  /**
   * Rename one conversation locally: index row, cached message blob and —
   * when it is the open one — the live header. The durable server log keeps
   * its id; dsh re-derives nothing from the local title.
   */
  private async renameSession(id: string, title: string): Promise<void> {
    const name = title.trim()
    if (name.length === 0) {
      return
    }
    await this.store.rename(id, name)
    this.sessions = await this.store.list(this.currentProjectId)
    if (id === this.currentId) {
      this.title = name
    }
  }

  /** Best-effort removal of the durable log dir dsh keeps per session id. */
  private deleteSessionLogs(id: string): void {
    if (this.context === null) {
      return
    }
    const root = `${this.context.filesDir}/dsh-home/sessions`
    try {
      if (!fs.accessSync(root)) {
        return
      }
      const slugs = fs.listFileSync(root)
      for (const slug of slugs) {
        try {
          const target = `${root}/${slug}/${id}`
          if (fs.accessSync(target)) {
            fs.rmdirSync(target)
          }
        } catch (error) {
          // Keep scanning; the log may sit under another slug.
        }
      }
    } catch (error) {
      // No readable sessions root — nothing durable to clean.
    }
  }

  /**
   * Resolve a chat file reference to a real sandbox path.
   *
   * The transcript only carries what the model typed, and that path is
   * relative to whichever cwd the *runtime* session had — which is not always
   * the project the user is looking at now (sessions outlive project
   * switches, and older turns predate the current project). So every
   * plausible root is probed and the first existing file wins; a miss still
   * returns the most likely path so the viewer can show it verbatim.
   */
  /**
   * Which project a resolved path belongs to, or '' when it is the open one.
   *
   * A reference that falls through to a sibling project still opens — that is
   * deliberate (a path pasted from an older conversation should work) — but
   * the chip names the owner so the conversation never looks like it produced
   * a file that actually lives elsewhere.
   */
  private foreignProjectOf(resolved: string): string {
    if (resolved.length === 0) {
      return ''
    }
    const current = this.workspaceOf(this.currentProjectId)
    if (current.length > 0 && (resolved === current || resolved.startsWith(`${current}/`))) {
      return ''
    }
    for (const project of this.projects) {
      const root = this.workspaceOf(project.id)
      if (root.length > 0 && (resolved === root || resolved.startsWith(`${root}/`))) {
        return project.name
      }
    }
    // Runtime state (session logs, snapshots) is not an artifact of any project.
    if (this.context !== null) {
      const runtime = `${this.context.filesDir}/dsh-home`
      if (resolved === runtime || resolved.startsWith(`${runtime}/`)) {
        return ''
      }
    }
    // A bound external directory, or the sandbox root itself.
    return '其他目录'
  }

  private resolveFile(ref: FileRef): string {
    const candidates = this.candidatePaths(ref.path)
    for (const path of candidates) {
      try {
        if (fs.accessSync(path)) {
          return path
        }
      } catch (error) {
        // Not under this root; keep probing.
      }
    }
    // Nothing resolved: return '' rather than the first candidate. Handing back
    // a path we know is absent made the viewer blame the file instead of the
    // lookup, which is the "文件不存在" that showed for files that do exist.
    return ''
  }

  /**
   * Absolute paths pass through; relative ones fan out over known roots.
   *
   * The current project's workspace comes first and is the only root treated
   * as authoritative. Other projects and the sandbox root stay as a last
   * resort so a reference pasted from an older conversation still opens, but
   * `resolveFile` reports which root won (see `resolveFileIn`), because a hit
   * outside the open project is not the same file the user meant.
   */
  private candidatePaths(raw: string): string[] {
    const out: string[] = []
    if (this.context === null) {
      return out
    }
    let path = raw.trim()
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length)
    }
    while (path.startsWith('./')) {
      path = path.substring(2)
    }
    if (path.startsWith('/')) {
      out.push(path)
      return out
    }
    const home = path.startsWith('~/') ? path.substring(2) : ''
    const relative = home.length > 0 ? home : path
    const roots: string[] = []
    const current = this.workspaceOf(this.currentProjectId)
    if (current.length > 0) {
      roots.push(current)
    }
    roots.push(ProjectStore.workspaceDir(this.context, ProjectStore.DEFAULT_ID))
    for (const project of this.projects) {
      roots.push(this.workspaceOf(project.id))
    }
    roots.push(this.context.filesDir)
    const seen = new Set<string>()
    for (const root of roots) {
      if (root.length === 0 || seen.has(root)) {
        continue
      }
      seen.add(root)
      out.push(`${root}/${relative}`)
    }
    return out
  }

  /** Open a workspace file referenced from chat in the full-screen cover. */
  private openFile(ref: FileRef): void {
    const path = this.resolveFile(ref)
    if (path.length === 0) {
      // Say why nothing opened. A silent no-op reads as a broken button.
      this.getUIContext().getPromptAction().showToast({
        message: `找不到「${ref.name}」：它不在当前项目的可访问目录内。`,
        duration: 2600
      })
      return
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
    // ACP/ohos runs the credentials-live plugin: the staged key hot-publishes
    // within ~2s. SDK keeps the boot-frozen env; only a restart picks it up.
    this.getUIContext().getPromptAction().showToast({
      message: this.host.isAcp() ? '已保存，新密钥即将生效' : '已保存，重启应用后生效',
      duration: 2000
    })
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

  /** The project summary when projectId carries a bound user directory. */
  private boundOf(projectId: string): ProjectSummary | null {
    for (const project of this.projects) {
      if (project.id === projectId && project.boundPath !== undefined && project.boundPath.length > 0) {
        return project
      }
    }
    return null
  }

  /** Bound user dir wins; otherwise the project's sandbox workspace. */
  private workspaceOf(projectId: string): string {
    if (this.context === null) {
      return ''
    }
    const bound = this.boundOf(projectId)
    if (bound !== null) {
      return bound.boundPath === undefined ? '' : bound.boundPath
    }
    return ProjectStore.workspaceDir(this.context, projectId)
  }

  /** Long-press "绑定用户目录": pick a folder, persist + activate the grant. */
  private async bindProjectDir(id: string): Promise<void> {
    if (this.context === null) {
      return
    }
    try {
      const granted = await DirGrant.grant(this.context)
      await this.projectStore.bindDir(id, granted.uri, granted.path, granted.label)
      this.projects = await this.projectStore.list()
      this.getUIContext().getPromptAction().showToast({
        message: `已绑定「${granted.label}」，该项目新会话将在该目录工作`,
        duration: 2500
      })
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({
        message: (error as Error).message,
        duration: 2500
      })
    }
  }

  /** Long-press "解绑用户目录": revoke the grant, fall back to the sandbox dir. */
  private async unbindProjectDir(id: string): Promise<void> {
    const bound = this.boundOf(id)
    if (this.context === null || bound === null) {
      return
    }
    try {
      await DirGrant.revoke(bound.boundUri === undefined ? '' : bound.boundUri)
      await this.projectStore.unbindDir(id)
      this.projects = await this.projectStore.list()
      this.getUIContext().getPromptAction().showToast({
        message: '已解绑，该项目新会话将回到应用沙箱工作区',
        duration: 2500
      })
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({
        message: (error as Error).message,
        duration: 2500
      })
    }
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
      onDeleteSession: (id: string) => {
        void this.deleteSession(id)
      },
      onRenameSession: (id: string, title: string) => {
        void this.renameSession(id, title)
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
      },
      onBindProjectDir: (id: string) => {
        void this.bindProjectDir(id)
      },
      onUnbindProjectDir: (id: string) => {
        void this.unbindProjectDir(id)
      }
    })
  }

  @Builder
  filesSheet() {
    FilesPanel({
      projectName: this.currentProjectName(),
      workspacePath: this.workspaceOf(this.currentProjectId),
      refreshTick: this.filesTick,
      onOpenFile: (path: string, name: string) => {
        const ref: FileRef = { path: path, name: name }
        this.openFile(ref)
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
                onDeleteSession: (id: string) => {
                  void this.deleteSession(id)
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
                },
                onBindProjectDir: (id: string) => {
                  void this.bindProjectDir(id)
                },
                onUnbindProjectDir: (id: string) => {
                  void this.unbindProjectDir(id)
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
                shareText: this.shareText,
                attachPaths: this.attachPaths,
                onSend: (text: string, attachPaths: string[]) => {
                  void this.send(text, attachPaths)
                },
                onNewSession: () => {
                  void this.newSession()
                },
                onOpenSettings: () => {
                  this.refreshDiagnostics()
                  this.showSettings = true
                },
                onOpenFiles: () => {
                  this.filesTick += 1
                  this.showFiles = true
                },
                onPickModel: () => {
                  this.showModelSheet = true
                },
                onStop: () => this.stopAcp(),
                onOpenFile: (ref: FileRef) => this.openFile(ref),
                onResolveFile: (ref: FileRef) => this.resolveFile(ref),
                onForeignProject: (resolved: string) => this.foreignProjectOf(resolved),
                onShareTextConsumed: () => {
                  this.shareText = ''
                },
                onRemoveAttachment: () => {
                  this.attachPaths = []
                },
                onPickImage: () => {
                  void this.pickImage()
                },
                onRollback: (messageId: string) => {
                  void this.rollbackTurn(messageId)
                },
                onFork: (messageId: string) => {
                  void this.forkFrom(messageId)
                }
              })
                .layoutWeight(1)
                .bindSheet($$this.showFiles, this.filesSheet(), {
                  height: SheetSize.LARGE,
                  dragBar: true,
                  showClose: false,
                  onDisappear: () => {
                    this.showFiles = false
                  }
                })
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
                shareText: this.shareText,
                attachPaths: this.attachPaths,
                onSend: (text: string, attachPaths: string[]) => {
                  void this.send(text, attachPaths)
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
                onOpenFiles: () => {
                  this.filesTick += 1
                  this.showFiles = true
                },
                onPickModel: () => {
                  this.showModelSheet = true
                },
                onStop: () => this.stopAcp(),
                onOpenFile: (ref: FileRef) => this.openFile(ref),
                onResolveFile: (ref: FileRef) => this.resolveFile(ref),
                onForeignProject: (resolved: string) => this.foreignProjectOf(resolved),
                onShareTextConsumed: () => {
                  this.shareText = ''
                },
                onRemoveAttachment: () => {
                  this.attachPaths = []
                },
                onPickImage: () => {
                  void this.pickImage()
                },
                onRollback: (messageId: string) => {
                  void this.rollbackTurn(messageId)
                },
                onFork: (messageId: string) => {
                  void this.forkFrom(messageId)
                }
              })
              .bindSheet($$this.showFiles, this.filesSheet(), {
                height: SheetSize.LARGE,
                dragBar: true,
                showClose: false,
                onDisappear: () => {
                  this.showFiles = false
                }
              })
            }
            .width('100%')
            .height('100%')
            .bindSheet($$this.showSessions, this.sessionsSheet(), {
              height: SheetSize.LARGE,
              dragBar: true,
              showClose: false,
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
