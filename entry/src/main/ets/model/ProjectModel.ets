import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { fileIo as fs } from '@kit.CoreFileKit'

/** One conversation category: a named bucket of sessions with its own workspace. */
export interface ProjectSummary {
  id: string
  name: string
  updatedAt: number
}

/**
 * Conversation categories ("projects").
 *
 * Every project owns a workspace directory. Sessions created inside it are
 * pointed there via session/working-directory/set before their first prompt,
 * so files the agent produces land in the project's workspace and survive
 * app restarts (the change persists in the session log and replays on
 * resume). The default project is the legacy bucket: it keeps the
 * filesDir/workspace directory initialize fixed, and owns every session
 * stored before projects existed.
 */
export class ProjectStore {
  static readonly DEFAULT_ID = 'default'
  static readonly DEFAULT_NAME = '默认'
  private static readonly STORE = 'dsh_projects'
  private static readonly INDEX_KEY = 'index'
  private static readonly LAST_KEY = 'last_selected'
  private store: preferences.Preferences | null = null

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, ProjectStore.STORE)
    if ((await this.list()).length === 0) {
      const seed: ProjectSummary = {
        id: ProjectStore.DEFAULT_ID,
        name: ProjectStore.DEFAULT_NAME,
        updatedAt: Date.now()
      }
      await this.writeIndex([seed])
    }
  }

  /** Default project first, everything else newest-first. */
  async list(): Promise<ProjectSummary[]> {
    const def: ProjectSummary[] = []
    const rest: ProjectSummary[] = []
    for (const row of await this.readIndex()) {
      if (row.id === ProjectStore.DEFAULT_ID) {
        def.push(row)
      } else {
        rest.push(row)
      }
    }
    rest.sort((a: ProjectSummary, b: ProjectSummary) => b.updatedAt - a.updatedAt)
    const out: ProjectSummary[] = []
    for (const row of def) {
      out.push(row)
    }
    for (const row of rest) {
      out.push(row)
    }
    return out
  }

  async create(context: common.UIAbilityContext, name: string): Promise<ProjectSummary> {
    const project: ProjectSummary = {
      id: util.generateRandomUUID(true),
      name: name,
      updatedAt: Date.now()
    }
    const index = await this.readIndex()
    index.push(project)
    await this.writeIndex(index)
    ProjectStore.ensureWorkspace(context, project.id)
    return project
  }

  async rename(id: string, name: string): Promise<void> {
    if (id === ProjectStore.DEFAULT_ID) {
      return
    }
    const index = await this.readIndex()
    for (const row of index) {
      if (row.id === id) {
        row.name = name
        row.updatedAt = Date.now()
        break
      }
    }
    await this.writeIndex(index)
  }

  /**
   * Forget a project. Its workspace directory stays on disk; the caller
   * reassigns the project's sessions (SessionStore.reassignProject).
   */
  async remove(id: string): Promise<void> {
    if (id === ProjectStore.DEFAULT_ID) {
      return
    }
    const kept: ProjectSummary[] = []
    for (const row of await this.readIndex()) {
      if (row.id !== id) {
        kept.push(row)
      }
    }
    await this.writeIndex(kept)
  }

  /** Last project the user worked in; falls back to default when gone. */
  async loadLastSelected(): Promise<string> {
    const saved = await this.readKey(ProjectStore.LAST_KEY, ProjectStore.DEFAULT_ID)
    for (const row of await this.readIndex()) {
      if (row.id === saved) {
        return saved
      }
    }
    return ProjectStore.DEFAULT_ID
  }

  async saveLastSelected(id: string): Promise<void> {
    if (this.store === null) {
      return
    }
    await this.store.put(ProjectStore.LAST_KEY, id)
    await this.store.flush()
  }

  /** Absolute workspace dir; the default project keeps the legacy path. */
  static workspaceDir(context: common.UIAbilityContext, projectId: string): string {
    if (projectId === ProjectStore.DEFAULT_ID) {
      return `${context.filesDir}/workspace`
    }
    return `${context.filesDir}/workspaces/${projectId}`
  }

  /**
   * Create the workspace dir if missing. session/working-directory/set
   * rejects paths that do not exist, so this must run before the call.
   */
  static ensureWorkspace(context: common.UIAbilityContext, projectId: string): void {
    if (projectId === ProjectStore.DEFAULT_ID) {
      return
    }
    try {
      const root = `${context.filesDir}/workspaces`
      if (!fs.accessSync(root)) {
        fs.mkdirSync(root)
      }
      const dir = ProjectStore.workspaceDir(context, projectId)
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir)
      }
    } catch (error) {
      console.error(`workspace create failed: ${(error as Error).message}`)
    }
  }

  private async readIndex(): Promise<ProjectSummary[]> {
    const raw = await this.readKey(ProjectStore.INDEX_KEY, '[]')
    try {
      return JSON.parse(raw) as ProjectSummary[]
    } catch (error) {
      return []
    }
  }

  private async readKey(key: string, fallback: string): Promise<string> {
    if (this.store === null) {
      return fallback
    }
    return await this.store.get(key, fallback) as string
  }

  private async writeIndex(index: ProjectSummary[]): Promise<void> {
    if (this.store === null) {
      return
    }
    await this.store.put(ProjectStore.INDEX_KEY, JSON.stringify(index))
    await this.store.flush()
  }
}
