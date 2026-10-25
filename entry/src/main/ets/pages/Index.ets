import { common } from '@kit.AbilityKit'
import { BootPhase, NodeHost } from '../host/NodeHost'
import { AppConfig } from '../common/AppConfig'
import { PluginConfig } from '../common/PluginConfig'
import { PluginCatalog, PluginRow } from '../model/PluginCatalog'
import { ChatMessage, Role, SessionStore, SessionSummary, newSessionId, titleOf } from '../model/ChatModel'
import { ProjectStore, ProjectSummary } from '../model/ProjectModel'
import { renderBlocks, RenderedBlock } from '../model/DshClient'
import { EventLike, SessionEventPayload, SessionStatusPayload } from '../model/Protocol'
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

  private host: NodeHost = NodeHost.get()
  private store: SessionStore = new SessionStore()
  private projectStore: ProjectStore = new ProjectStore()
  private context: common.UIAbilityContext | null = null
  /** Session ids the runtime already owns in this process (prompted/resumed). */
  private openedSessions: Set<string> = new Set<string>()
  /** In-flight session opens, deduped per id. */
  private openingSessions: Map<string, Promise<void>> = new Map<string, Promise<void>>()

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
    await this.boot()
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

  private async newSession(): Promise<void> {
    await this.persist()
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
    lines.push(`server: ${this.host.client.getServerInfo()}`)
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
      diagnostics: this.diagnostics,
      pluginRows: this.pluginRows,
      onSave: (key: string, model: string) => {
        void this.saveSettings(key, model)
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
