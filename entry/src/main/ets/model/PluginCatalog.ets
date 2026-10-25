/**
 * User-facing capability catalog.
 *
 * dsh composes its runtime from entries (cordis plugins); each row here maps
 * one entry id to a switch shown in Settings. Toggling writes a
 * `user.patch.yml` row that the bootstrap passes to `dsh --patch` after the
 * platform patch, so later rows override earlier ones.
 */
export interface CatalogEntry {
  id: string
  label: string
  description: string
}

export interface PluginRow {
  id: string
  label: string
  description: string
  locked: boolean
  enabled: boolean
}

export class PluginCatalog {
  /** Safe to toggle on device: pure in-process capabilities. */
  static readonly TOGGLABLE: CatalogEntry[] = [
    { id: 'tool-web', label: '网页搜索', description: 'web_search / web_fetch 联网检索' },
    { id: 'tool-fs', label: '文件操作', description: '读写与编辑工作区文件' },
    { id: 'tool-todo', label: '任务清单', description: 'todo_write 计划与进度管理' },
    { id: 'tool-goal', label: '目标管理', description: '长目标创建与自动续跑' },
    { id: 'tool-jobs', label: '后台任务', description: '异步 job 启动与跟踪' },
    { id: 'tool-subagent', label: '子代理', description: '委派独立子任务给子代理' },
    { id: 'tool-subagent-fork', label: '上下文分叉', description: 'fork 继承对话上下文的子代理' },
    { id: 'tool-skill', label: '技能加载', description: '加载技能目录的完整指令' },
    { id: 'plan-mode', label: '计划模式', description: '先规划、确认后再执行' },
    { id: 'session-title-llm', label: '智能会话标题', description: '由模型生成会话标题' }
  ]

  /** Disabled by the platform patch; shown as constrained, not switchable. */
  static readonly LOCKED: CatalogEntry[] = [
    { id: 'tool-bash', label: 'Shell 工具 (bash)', description: '依赖子进程，平台禁止' },
    { id: 'tool-pwsh', label: 'Shell 工具 (pwsh)', description: '依赖子进程，平台禁止' },
    { id: 'bash-sandbox', label: 'Bash 沙箱', description: '依赖子进程，平台禁止' },
    { id: 'pwsh-sandbox', label: 'Pwsh 沙箱', description: '依赖子进程，平台禁止' },
    { id: 'subprocess', label: '子进程服务', description: '平台禁止 fork/exec' },
    { id: 'plugin-manager', label: '插件管理器', description: '通过子进程运行包管理器' },
    { id: 'tool-plugin-manager', label: '插件管理工具', description: '依赖插件管理器服务' },
    { id: 'skill-office', label: 'Office 文档转换', description: '绑定原生 FFI 库' }
  ]

  static rows(disabled: Set<string>): PluginRow[] {
    const out: PluginRow[] = []
    for (const entry of PluginCatalog.TOGGLABLE) {
      const row: PluginRow = {
        id: entry.id,
        label: entry.label,
        description: entry.description,
        locked: false,
        enabled: !disabled.has(entry.id)
      }
      out.push(row)
    }
    for (const entry of PluginCatalog.LOCKED) {
      const row: PluginRow = {
        id: entry.id,
        label: entry.label,
        description: entry.description,
        locked: true,
        enabled: false
      }
      out.push(row)
    }
    return out
  }
}
