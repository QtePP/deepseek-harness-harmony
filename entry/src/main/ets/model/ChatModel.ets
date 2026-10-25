import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { common } from '@kit.AbilityKit'
import { ProjectStore } from './ProjectModel'

/** Who produced a rendered bubble. */
export enum Role {
  USER = 'user',
  ASSISTANT = 'assistant',
  TOOL = 'tool',
  SYSTEM = 'system'
}

/** One rendered bubble; observed so a single append re-renders the list. */
@Observed
export class ChatMessage {
  id: string = ''
  role: Role = Role.ASSISTANT
  text: string = ''
  /** Secondary line: tool name, usage, interruption marker. */
  note: string = ''
  at: number = 0

  constructor(id: string, role: Role, text: string, note: string) {
    this.id = id
    this.role = role
    this.text = text
    this.note = note
    this.at = Date.now()
  }
}

/** Index row for the session rail. */
export interface SessionSummary {
  id: string
  title: string
  updatedAt: number
  /** Owning project; rows written before projects existed normalise to default. */
  projectId: string
}

/**
 * Tolerant wire view of one persisted index row. Sessions stored by older
 * app versions lack `projectId`; the index is the only place it lives.
 */
interface StoredIndexRow {
  id: string
  title: string
  updatedAt: number
  projectId?: string
}

interface StoredMessage {
  id: string
  role: string
  text: string
  note: string
  at: number
}

interface StoredSession {
  id: string
  title: string
  updatedAt: number
  messages: StoredMessage[]
}

/**
 * Local conversation store.
 *
 * dsh owns the durable session log on the runtime side; this store only keeps
 * what the phone needs to paint a list before the runtime answers, and to
 * survive a cold start without a round trip.
 */
export class SessionStore {
  private static readonly STORE = 'dsh_sessions'
  private static readonly INDEX_KEY = 'index'
  private static readonly MAX_MESSAGES = 200
  private store: preferences.Preferences | null = null

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, SessionStore.STORE)
  }

  /** Newest first; optional `projectId` narrows the list to one project. */
  async list(projectId?: string): Promise<SessionSummary[]> {
    if (this.store === null) {
      return []
    }
    const raw = await this.store.get(SessionStore.INDEX_KEY, '[]') as string
    let rows: StoredIndexRow[] = []
    try {
      rows = JSON.parse(raw) as StoredIndexRow[]
    } catch (error) {
      return []
    }
    const out: SessionSummary[] = []
    for (const row of rows) {
      const owner = row.projectId === undefined ? ProjectStore.DEFAULT_ID : row.projectId
      if (projectId !== undefined && owner !== projectId) {
        continue
      }
      const summary: SessionSummary = {
        id: row.id,
        title: row.title,
        updatedAt: row.updatedAt,
        projectId: owner
      }
      out.push(summary)
    }
    out.sort((a: SessionSummary, b: SessionSummary) => b.updatedAt - a.updatedAt)
    return out
  }

  async save(sessionId: string, projectId: string, title: string, messages: ChatMessage[]): Promise<void> {
    if (this.store === null) {
      return
    }
    const kept = messages.slice(Math.max(0, messages.length - SessionStore.MAX_MESSAGES))
    const stored: StoredSession = {
      id: sessionId,
      title: title,
      updatedAt: Date.now(),
      messages: kept.map((m: ChatMessage) => {
        const row: StoredMessage = { id: m.id, role: m.role, text: m.text, note: m.note, at: m.at }
        return row
      })
    }
    await this.store.put(`session.${sessionId}`, JSON.stringify(stored))
    await this.store.put(SessionStore.INDEX_KEY, JSON.stringify(await this.mergeIndex(sessionId, projectId, title)))
    await this.store.flush()
  }

  async load(sessionId: string): Promise<ChatMessage[]> {
    if (this.store === null) {
      return []
    }
    const raw = await this.store.get(`session.${sessionId}`, '') as string
    if (raw.length === 0) {
      return []
    }
    try {
      const stored = JSON.parse(raw) as StoredSession
      return stored.messages.map((row: StoredMessage) => {
        const role = row.role === Role.USER ? Role.USER
          : (row.role === Role.TOOL ? Role.TOOL : (row.role === Role.SYSTEM ? Role.SYSTEM : Role.ASSISTANT))
        const message = new ChatMessage(row.id, role, row.text, row.note)
        message.at = row.at
        return message
      })
    } catch (error) {
      return []
    }
  }

  private async mergeIndex(sessionId: string, projectId: string, title: string): Promise<SessionSummary[]> {
    const existing = await this.list()
    let found = false
    for (const row of existing) {
      if (row.id === sessionId) {
        row.title = title
        row.updatedAt = Date.now()
        found = true
        break
      }
    }
    if (!found) {
      const fresh: SessionSummary = { id: sessionId, title: title, updatedAt: Date.now(), projectId: projectId }
      existing.push(fresh)
    }
    return existing
  }

  /** Move every session of one project to another (index rows only). */
  async reassignProject(fromId: string, toId: string): Promise<void> {
    if (this.store === null || fromId === toId) {
      return
    }
    const rows = await this.list()
    for (const row of rows) {
      if (row.projectId === fromId) {
        row.projectId = toId
      }
    }
    await this.store.put(SessionStore.INDEX_KEY, JSON.stringify(rows))
    await this.store.flush()
  }
}

/** New session id; the runtime creates the agent lazily on first prompt. */
export function newSessionId(): string {
  return util.generateRandomUUID(true)
}

/** Derive a rail title from the first user line. */
export function titleOf(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  if (flat.length === 0) {
    return '新会话'
  }
  return flat.length > 24 ? flat.substring(0, 24) + '…' : flat
}
