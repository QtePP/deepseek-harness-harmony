/**
 * Visual taxonomy for timeline nodes.
 *
 * A run timeline mixes two kinds of node — a thought run and a tool call — and
 * tool calls are not interchangeable: a read, a write, a search and a shell
 * command carry different risk and different user intent. Grouping them by
 * what they do (rather than by which tool happens to be installed) keeps the
 * rail legible: the colour and the glyph say "this touched files" or "this
 * went to the network" before any text is read.
 */

/** What a node does, independent of the concrete tool name. */
export enum NodeKind {
  THOUGHT = 'thought',
  READ = 'read',
  WRITE = 'write',
  SEARCH = 'search',
  NETWORK = 'network',
  EXEC = 'exec',
  OTHER = 'other'
}

/** Kind of a tool call, inferred from its name. */
export function toolKindOf(name: string): NodeKind {
  const n = name.toLowerCase()
  // Checked first: `todo_write` writes a task list, not a file, and must not
  // inherit the warm "this changed your files" colour.
  if (contains(n, 'todo') || contains(n, 'skill') || contains(n, 'subagent') || contains(n, 'plan')) {
    return NodeKind.OTHER
  }
  if (contains(n, 'web') || contains(n, 'fetch') || contains(n, 'http') || contains(n, 'curl')) {
    return NodeKind.NETWORK
  }
  if (contains(n, 'glob') || contains(n, 'grep') || contains(n, 'search') || contains(n, 'find')) {
    return NodeKind.SEARCH
  }
  if (contains(n, 'bash') || contains(n, 'shell') || contains(n, 'exec') || contains(n, 'run_code')
    || contains(n, 'terminal')) {
    return NodeKind.EXEC
  }
  if (contains(n, 'write') || contains(n, 'edit') || contains(n, 'create') || contains(n, 'delete')
    || contains(n, 'remove') || contains(n, 'mkdir')) {
    return NodeKind.WRITE
  }
  if (contains(n, 'read') || contains(n, 'open') || contains(n, 'cat') || contains(n, 'list')
    || contains(n, 'ls')) {
    return NodeKind.READ
  }
  return NodeKind.OTHER
}

function contains(hay: string, needle: string): boolean {
  return hay.indexOf(needle) >= 0
}

/** Short verb shown before the tool name, so the row reads as an action. */
export function kindVerb(kind: NodeKind): string {
  switch (kind) {
    case NodeKind.READ:
      return '读取'
    case NodeKind.WRITE:
      return '写入'
    case NodeKind.SEARCH:
      return '查找'
    case NodeKind.NETWORK:
      return '联网'
    case NodeKind.EXEC:
      return '执行'
    default:
      return '调用'
  }
}

/**
 * Accent colour per kind. Read is calm, write is warm (it changed something),
 * search and network are informational, exec is the heaviest, and a failure
 * overrides everything with the danger colour.
 */
export function kindAccent(kind: NodeKind): string {
  switch (kind) {
    case NodeKind.READ:
      return '#5B8DEF'
    case NodeKind.WRITE:
      return '#E08A3C'
    case NodeKind.SEARCH:
      return '#8B7BE8'
    case NodeKind.NETWORK:
      return '#3FA6A0'
    case NodeKind.EXEC:
      return '#6B7280'
    default:
      return '#9CA3AF'
  }
}

/** Tinted background for the node's pill; kept very light so text stays legible. */
export function kindTint(kind: NodeKind): string {
  switch (kind) {
    case NodeKind.READ:
      return '#EEF3FE'
    case NodeKind.WRITE:
      return '#FDF3E8'
    case NodeKind.SEARCH:
      return '#F1EEFD'
    case NodeKind.NETWORK:
      return '#E8F5F4'
    case NodeKind.EXEC:
      return '#F2F3F5'
    default:
      return '#F5F6F8'
  }
}

/**
 * Glyph per kind. These are the system symbol names verified against the
 * API 26 SDK; an unknown name fails the ArkTS resource check at build time.
 */
export function kindGlyph(kind: NodeKind): Resource {
  switch (kind) {
    case NodeKind.READ:
      return $r('sys.symbol.doc_text')
    case NodeKind.WRITE:
      return $r('sys.symbol.arrow_down_circle')
    case NodeKind.SEARCH:
      return $r('sys.symbol.magnifyingglass')
    case NodeKind.NETWORK:
      return $r('sys.symbol.link')
    case NodeKind.EXEC:
      return $r('sys.symbol.code')
    default:
      return $r('sys.symbol.info_circle')
  }
}

/** Status label + colour; a failure must never look like a success. */
export function statusLabel(status: string): string {
  if (status === 'failed') {
    return '失败'
  }
  if (status === 'in_progress') {
    return '进行中'
  }
  if (status === 'completed') {
    return '完成'
  }
  return ''
}
