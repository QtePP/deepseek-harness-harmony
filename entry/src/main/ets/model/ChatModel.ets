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

/** One tool invocation inside an assistant turn's collapsed trace. */
@Observed
export class ToolTrace {
  name: string = ''
  /** ACP toolCallId; empty where the profile carries no call id. */
  callId: string = ''
  /** Argument digest: the readable fields, capped. */
  input: string = ''
  /** Result text, capped for display. */
  output: string = ''
  /** 'in_progress' | 'completed' | 'failed'. */
  status: string = 'in_progress'
  at: number = 0
  /**
   * Reasoning length on the host row when this call started; the merged
   * thinking timeline splits the reasoning text there. -1 (legacy rows)
   * renders the call after the reasoning text.
   */
  reasonOffset: number = -1
  /** Epoch ms when the call settled (completed/failed); 0 while running. */
  doneAt: number = 0

  constructor(name: string) {
    this.name = name
    this.at = Date.now()
  }
}

/** One rendered bubble; observed so a single append re-renders the list. */
@Observed
export class ChatMessage {
  id: string = ''
  role: Role = Role.ASSISTANT
  text: string = ''
  /** Secondary line: tool name, usage, interruption marker. */
  note: string = ''
  /** Sandbox path of an attached image; empty for plain text turns. */
  image: string = ''
  /** All attached image paths (multi-select); `image` mirrors the first for old readers. */
  images: string[] = []
  /**
   * Thinking text streamed before the answer (`agent_thought_chunk`). Kept on
   * the assistant row it belongs to and rendered as a collapsible block.
   */
  reasoning: string = ''
  /** ACP toolCallId; `tool_call_update` finds its own row by this key. */
  toolCallId: string = ''
  /** Tool arguments digest: the argument fields worth reading, first lines. */
  toolInput: string = ''
  /** Tool result text, capped for display. */
  toolOutput: string = ''
  /** 'in_progress' | 'completed' | 'failed' | '' (unknown). */
  toolStatus: string = ''
  /** Tool invocations of this turn, rendered as the expandable 轨迹 chip. */
  trace: ToolTrace[] = []
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

/** One persisted trace entry of a turn's tool call list. */
interface StoredTrace {
  name: string
  callId?: string
  input?: string
  output?: string
  status?: string
  reasonOffset?: number
  doneAt?: number
}

interface StoredMessage {
  id: string
  role: string
  text: string
  note: string
  image?: string
  at: number
  /** Rows written before thinking/tool detail existed simply omit these. */
  reasoning?: string
  toolCallId?: string
  toolInput?: string
  toolOutput?: string
  toolStatus?: string
  /** Tool trace of the turn this row hosted; rows before traces omit it. */
  trace?: StoredTrace[]
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
        if (m.images.length > 0) {
          row.image = JSON.stringify(m.images)
        } else if (m.image.length > 0) {
          row.image = m.image
        }
        if (m.reasoning.length > 0) {
          row.reasoning = m.reasoning
        }
        if (m.toolCallId.length > 0) {
          row.toolCallId = m.toolCallId
          row.toolInput = m.toolInput
          row.toolOutput = m.toolOutput
          row.toolStatus = m.toolStatus
        }
        if (m.trace.length > 0) {
          row.trace = m.trace.map((entry: ToolTrace) => {
            const item: StoredTrace = { name: entry.name }
            if (entry.callId.length > 0) {
              item.callId = entry.callId
            }
            if (entry.input.length > 0) {
              item.input = entry.input
            }
            if (entry.output.length > 0) {
              item.output = entry.output
            }
            if (entry.status.length > 0) {
              item.status = entry.status
            }
            if (entry.reasonOffset >= 0) {
              item.reasonOffset = entry.reasonOffset
            }
            if (entry.doneAt > 0) {
              item.doneAt = entry.doneAt
            }
            return item
          })
        }
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
        const storedImage = row.image === undefined ? '' : row.image
        if (storedImage.length > 1 && storedImage.startsWith('[')) {
          // Multi-image rows persist a JSON array; a failed parse falls back to the raw string.
          try {
            const paths = JSON.parse(storedImage) as string[]
            if (paths instanceof Array) {
              for (const path of paths) {
                if (typeof path === 'string' && path.length > 0) {
                  message.images.push(path)
                }
              }
            }
          } catch (error) {
            message.images = []
          }
          if (message.images.length === 0) {
            message.images.push(storedImage)
          }
        } else if (storedImage.length > 0) {
          message.images.push(storedImage)
        }
        message.image = message.images.length > 0 ? message.images[0] : ''
        message.reasoning = row.reasoning === undefined ? '' : row.reasoning
        message.toolCallId = row.toolCallId === undefined ? '' : row.toolCallId
        message.toolInput = row.toolInput === undefined ? '' : row.toolInput
        message.toolOutput = row.toolOutput === undefined ? '' : row.toolOutput
        message.toolStatus = row.toolStatus === undefined ? '' : row.toolStatus
        if (row.trace !== undefined) {
          for (const item of row.trace) {
            const entry = new ToolTrace(item.name)
            entry.callId = item.callId === undefined ? '' : item.callId
            entry.input = item.input === undefined ? '' : item.input
            entry.output = item.output === undefined ? '' : item.output
            entry.status = item.status === undefined ? 'completed' : item.status
            entry.reasonOffset = item.reasonOffset === undefined ? -1 : item.reasonOffset
            entry.doneAt = item.doneAt === undefined ? 0 : item.doneAt
            message.trace.push(entry)
          }
        }
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

  /** Drop one session: its index row and its cached message blob. */
  async remove(sessionId: string): Promise<void> {
    if (this.store === null) {
      return
    }
    const rows = await this.list()
    const kept: SessionSummary[] = []
    for (const row of rows) {
      if (row.id !== sessionId) {
        kept.push(row)
      }
    }
    await this.store.put(SessionStore.INDEX_KEY, JSON.stringify(kept))
    await this.store.delete(`session.${sessionId}`)
    await this.store.flush()
  }

  /** Rename one session: its index row title plus the cached blob's title. */
  async rename(sessionId: string, title: string): Promise<void> {
    if (this.store === null || title.length === 0) {
      return
    }
    const rows = await this.list()
    for (const row of rows) {
      if (row.id === sessionId) {
        row.title = title
        break
      }
    }
    await this.store.put(SessionStore.INDEX_KEY, JSON.stringify(rows))
    const raw = await this.store.get(`session.${sessionId}`, '') as string
    if (raw.length > 0) {
      try {
        const stored = JSON.parse(raw) as StoredSession
        stored.title = title
        await this.store.put(`session.${sessionId}`, JSON.stringify(stored))
      } catch (error) {
        // The index rename above still applies; the blob keeps its old title.
      }
    }
    await this.store.flush()
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
