/**
 * The `todo_write` projection: the model's standing plan, read back out of the
 * tool call it wrote it with.
 *
 * dsh keeps the todo list on the server as a whole-list snapshot (last write
 * wins, `dsh-tool-todo`); ACP carries no projection channel, so the phone
 * rebuilds the same list from the tool call's arguments. That is why the list
 * survives a cold start: the arguments are part of the persisted transcript,
 * so a replayed session re-derives its plan without asking the runtime.
 *
 * Only the shape the tool documents is accepted — `{todos: [{content, status}]}`
 * with `status` one of pending / in_progress / completed. Anything else is
 * ignored rather than guessed at, because a wrong plan bar is worse than none.
 */

/** One step of the model's plan, in the order the model wrote it. */
export interface TodoItem {
  content: string
  /** 'pending' | 'in_progress' | 'completed'. */
  status: string
}

interface RawTodoItem {
  content?: string
  status?: string
}

interface RawTodoWrite {
  todos?: RawTodoItem[]
}

const STATUSES: string[] = ['pending', 'in_progress', 'completed']

/** Whether a tool name is the todo writer (the stock name is `todo_write`). */
export function isTodoTool(name: string): boolean {
  return name.toLowerCase().indexOf('todo') >= 0
}

/**
 * Parse one tool call's argument JSON into a plan. Returns null when the text
 * is not a todo snapshot — the caller then keeps whatever plan it already has,
 * so an unrelated tool call never wipes the bar.
 */
export function todosFromJson(text: string): TodoItem[] | null {
  const flat = text.trim()
  if (flat.length === 0 || flat.charAt(0) !== '{') {
    return null
  }
  let raw: RawTodoWrite | null = null
  try {
    raw = JSON.parse(flat) as RawTodoWrite
  } catch (error) {
    return null
  }
  if (raw === null || raw.todos === undefined) {
    return null
  }
  const out: TodoItem[] = []
  for (const item of raw.todos) {
    const content = item.content === undefined ? '' : item.content.trim()
    const status = item.status === undefined ? 'pending' : item.status
    if (content.length === 0 || STATUSES.indexOf(status) < 0) {
      continue
    }
    out.push({ content: content, status: status })
  }
  return out
}

/** Parse the ACP `tool_call.rawInput` object; null when it is not a todo write. */
export function todosFromRaw(raw: Record<string, Object> | undefined): TodoItem[] | null {
  if (raw === undefined) {
    return null
  }
  try {
    return todosFromJson(JSON.stringify(raw))
  } catch (error) {
    return null
  }
}

/** Completed steps, for the "3/7" counter. */
export function completedCount(todos: TodoItem[]): number {
  let done = 0
  for (const item of todos) {
    if (item.status === 'completed') {
      done++
    }
  }
  return done
}

/**
 * The step worth naming on the collapsed bar: the one being worked on, else
 * the first still pending, else the last step (a finished plan keeps its
 * closing line visible instead of going blank).
 */
export function activeTodo(todos: TodoItem[]): string {
  for (const item of todos) {
    if (item.status === 'in_progress') {
      return item.content
    }
  }
  for (const item of todos) {
    if (item.status !== 'completed') {
      return item.content
    }
  }
  return todos.length > 0 ? todos[todos.length - 1].content : ''
}

/** Collapsed-bar caption: 「3/7 · 正在：写单元测试」. */
export function todoSummary(todos: TodoItem[]): string {
  if (todos.length === 0) {
    return ''
  }
  const done = completedCount(todos)
  const head = `${done}/${todos.length}`
  const active = activeTodo(todos)
  if (done === todos.length) {
    return `${head} · 已全部完成`
  }
  return active.length > 0 ? `${head} · ${active}` : head
}
