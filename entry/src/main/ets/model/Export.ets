import { ChatMessage, Role, ToolTrace } from './ChatModel'

/**
 * Markdown export of one conversation.
 *
 * dsh-go exports the session log as a ZIP; ACP has no `session/export` method,
 * and the durable log is a zstd archive the client cannot read, so the honest
 * export is what the app already holds: the transcript. Markdown keeps the
 * thinking and the tool calls visible instead of dropping them, because the
 * reason to export a session is usually to read back how a result was reached.
 *
 * The output is written into the project workspace rather than a private cache
 * so the files panel — and the agent itself — can find it afterwards.
 */

/** One file name component safe for the sandbox filesystem. */
export function exportFileName(title: string, at: Date): string {
  const stem = title.replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim()
  const name = stem.length > 0 ? stem.substring(0, 40) : 'conversation'
  const pad = (value: number): string => `${value}`.padStart(2, '0')
  const stamp = `${at.getFullYear()}${pad(at.getMonth() + 1)}${pad(at.getDate())}` +
    `-${pad(at.getHours())}${pad(at.getMinutes())}`
  return `${name}-${stamp}.md`
}

/** Render the transcript as Markdown. */
export function transcriptMarkdown(messages: ChatMessage[], title: string, exportedAt: Date): string {
  const lines: string[] = []
  lines.push(`# ${title.length > 0 ? title : '会话'}`)
  lines.push('')
  lines.push(`> 导出于 ${exportedAt.toLocaleString()}`)
  lines.push('')
  for (const message of messages) {
    if (message.role === Role.USER) {
      lines.push('## 用户')
      lines.push('')
      lines.push(message.text.length > 0 ? message.text : '（图片）')
      for (const image of message.images) {
        lines.push('')
        lines.push(`![图片](${image})`)
      }
      lines.push('')
      continue
    }
    if (message.role === Role.ASSISTANT) {
      lines.push('## 助手')
      lines.push('')
      if (message.reasoning.length > 0) {
        lines.push('<details><summary>思考过程</summary>')
        lines.push('')
        lines.push(message.reasoning)
        lines.push('')
        lines.push('</details>')
        lines.push('')
      }
      if (message.trace.length > 0) {
        lines.push(...traceLines(message.trace))
        lines.push('')
      }
      if (message.text.length > 0) {
        lines.push(message.text)
      }
      lines.push('')
      continue
    }
    if (message.role === Role.SYSTEM) {
      lines.push(`> ${message.note.length > 0 ? `[${message.note}] ` : ''}${message.text}`)
      lines.push('')
      continue
    }
    lines.push('### 工具')
    lines.push('')
    lines.push(...traceLines(message.trace))
    lines.push('')
  }
  return lines.join('\n')
}

/** Tool calls as a compact list; output is capped so one long result cannot dominate. */
function traceLines(trace: ToolTrace[]): string[] {
  const lines: string[] = []
  lines.push('| 工具 | 状态 | 参数 |')
  lines.push('| --- | --- | --- |')
  for (const entry of trace) {
    const status = entry.status.length > 0 ? entry.status : 'in_progress'
    lines.push(`| ${cell(entry.name)} | ${cell(status)} | ${cell(clip(entry.input, 160))} |`)
  }
  return lines
}

/** Table cells cannot contain pipes or newlines without breaking the table. */
function cell(text: string): string {
  return text.replace(/\|/g, '\\|').replace(/\r?\n/g, ' ').trim()
}

function clip(text: string, max: number): string {
  return text.length > max ? `${text.substring(0, max)}…` : text
}
