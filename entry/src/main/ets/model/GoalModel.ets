/**
 * The goal projection: the standing objective, read back out of the goal tool
 * calls.
 *
 * dsh keeps a goal on the session (`goals/*`) and the desktop UI paints a goal
 * bar above the composer. ACP exposes no projection channel, but the goal is
 * written by the model through `create_goal` / `update_goal`, whose arguments
 * are persisted with the trace — so the bar can be rebuilt from the transcript
 * exactly like the todo list, and survives a cold start for free.
 *
 * Read-only on purpose: editing a goal means `goals/*` mutations, which ACP
 * does not carry. Showing what the agent is working towards is still the part
 * that changes how the user reads the transcript.
 */

/** The standing objective plus the last state transition seen. */
export interface GoalState {
  objective: string
  /** 'active' | 'paused' | 'completed' | 'blocked'. */
  status: string
}

interface RawCreateGoal {
  objective?: string
}

interface RawUpdateGoal {
  action?: string
  objective?: string
  blocked_reason?: string
}

/** Whether a tool name belongs to the goal family (`create_goal`, …). */
export function isGoalTool(name: string): boolean {
  return name.toLowerCase().indexOf('goal') >= 0
}

/**
 * Apply one goal tool call to the state seen so far.
 *
 * Returns null when the call cannot change what the bar shows (a `get_goal`
 * read, malformed JSON, an unknown action), so the caller keeps its state
 * instead of clearing the bar on every unrelated tool call.
 */
export function goalFromJson(prev: GoalState | null, name: string, input: string): GoalState | null {
  const flat = input.trim()
  if (flat.length === 0 || flat.charAt(0) !== '{') {
    return null
  }
  const lower = name.toLowerCase()
  if (lower.indexOf('create') >= 0) {
    let created: RawCreateGoal | null = null
    try {
      created = JSON.parse(flat) as RawCreateGoal
    } catch (error) {
      return null
    }
    const objective = created === null || created.objective === undefined ? '' : created.objective.trim()
    if (objective.length === 0) {
      return null
    }
    return { objective: objective, status: 'active' }
  }
  if (lower.indexOf('update') < 0) {
    return null
  }
  let update: RawUpdateGoal | null = null
  try {
    update = JSON.parse(flat) as RawUpdateGoal
  } catch (error) {
    return null
  }
  if (update === null) {
    return null
  }
  const action = update.action === undefined ? '' : update.action
  const base: GoalState = prev === null ? { objective: '', status: 'active' } : prev
  if (action === 'edit') {
    const objective = update.objective === undefined ? '' : update.objective.trim()
    return { objective: objective.length > 0 ? objective : base.objective, status: 'active' }
  }
  if (action === 'pause') {
    return { objective: base.objective, status: 'paused' }
  }
  if (action === 'resume') {
    return { objective: base.objective, status: 'active' }
  }
  if (action === 'complete') {
    return { objective: base.objective, status: 'completed' }
  }
  if (action === 'blocked') {
    return { objective: base.objective, status: 'blocked' }
  }
  return null
}

/** Parse the ACP `tool_call.rawInput` object; null when it changes nothing. */
export function goalFromRaw(prev: GoalState | null, name: string,
  raw: Record<string, Object> | undefined): GoalState | null {
  if (raw === undefined) {
    return null
  }
  try {
    return goalFromJson(prev, name, JSON.stringify(raw))
  } catch (error) {
    return null
  }
}

/** Chinese caption for the bar's status pill. */
export function goalStatusLabel(status: string): string {
  if (status === 'paused') {
    return '已暂停'
  }
  if (status === 'completed') {
    return '已完成'
  }
  if (status === 'blocked') {
    return '受阻'
  }
  return '进行中'
}

/** Whether the bar should stop drawing attention (a settled goal is history). */
export function goalSettled(status: string): boolean {
  return status === 'completed' || status === 'blocked'
}
