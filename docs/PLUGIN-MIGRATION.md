# dsh 客户端插件 → 手机端迁移评估

调研对象：`deepseek-harness/packages/client/` 下 **56 个 `ui-*` 客户端插件**（另有 connection /
store / modules / shortcuts / locale 等基础包）。
目标：判断哪些能力值得、且能够迁到 `dshharmony` 的原生 ArkUI 前端。

---

## 一、先厘清一件事：能不能迁，取决于协议可达性

dsh 的 host 能力全都在运行时里，但**客户端只能通过协议拿到**。三条协议能拿到的东西差别很大：

| 能力 | Web API（浏览器 GUI） | ACP（`--profile acp`） | SDK（`--profile sdk`，**当前在用**） |
|---|---|---|---|
| 流式文本增量 | ✅ | ✅ `agent_message_chunk` | ❌ 只有整条 `assistant/message` |
| 流式思考 | ✅ | ✅ `agent_thought_chunk` | ❌ |
| 工具调用实时状态 | ✅ | ✅ `tool_call` / `tool_call_update` | ❌ 只有 `tool/call` + `tool/result` |
| **权限审批** | ✅ | ✅ `approval/request` | ❌ **缺失** |
| 会话列表 / 恢复 | ✅ | ✅ `session/list` / `session/load` | ❌（只能客户端自己记） |
| 取消运行 | ✅ | ✅ `session/cancel` | ❌ |
| 模型 / 推理强度选择 | ✅ | ✅ | 仅 `initialize` 时固定 |
| DSH 特有呈现（plan / goal / todo / elicitation / 终端） | ✅ | ❌ 明确不支持 | ❌ |
| 文件树 / 文档预览 / diff | ✅ | ❌ | ❌ |

**关键结论 1**：当前 SDK 协议下，**需要人工审批的工具调用会直接失败**——`user-approval` 的语义是
“Missing or failed answerers return `unavailable`, so the action fails closed”。不是挂起，是失败。
所以“手机上能不能用工具”这件事，被协议卡住了。

**关键结论 2**：换到 ACP 能一次性解锁 **流式 + 工具实时状态 + 审批 + 会话列表 + 取消**，
这五项恰好是手机端体验的核心；代价是丢掉 plan / goal / todo 这类 DSH 特有卡片。

**关键结论 3**：协议之外的能力（文件树、设置写入、定时任务）不必等上游——**桥是我们自己写的**
（`host/bootstrap.cjs`），可以在同一条 TCP 连接上加自定义 RPC 方法（如 `ohos/fs.list`、
`ohos/settings.write`），与 dsh 协议帧并存。

---

## 二、迁移清单

图例：价值 = 手机端用户价值；成本 = 相对当前代码的增量工作量（S < 1 天，M 1–3 天，L 3 天+）。

### P0 — 必迁（不做就等于残废）

| 插件 | 功能 | 手机价值 | 可达性 | 成本 |
|---|---|---|---|---|
| `ui-approval` | 权限请求审批（允许/拒绝/本次会话记住） | 极高：没它工具只能失败 | ACP `approval/request` | M |
| `ui-chat` + `ui-conversation` | 消息流、滚动状态、操作行 | 极高（已有基础版） | ACP 流式 chunk | S–M |
| `ui-tool` | 工具卡（调用树、每工具专属视图） | 高：看清 agent 在干什么 | ACP `tool_call(_update)` | M |
| `ui-attachment` | 图片/文档附件、草稿区、大图查看 | 高：手机拍照是天然入口 | ACP prompt 支持 image block | S–M |
| `ui-model-selection` | 模型 + 推理强度切换 | 高：按任务切成本 | ACP | S |
| `ui-session` + `ui-workspace` | 会话列表、分组、切换 | 高：手机上必然多会话 | ACP `session/list` | M |

### P1 — 值得迁（体验分水岭）

| 插件 | 功能 | 手机价值 | 可达性 | 成本 |
|---|---|---|---|---|
| `ui-trajectory` | 事件账本 + 时序总览 | 中高：排查长任务 | ACP 事件 + `turn/step` | M |
| `ui-deliverables` | 本轮改动文件、交付卡、文件对比 | 高：手机上看“改了什么” | 需 side-channel 或 ArkTS 直读沙箱 | M–L |
| `ui-sidebar-files` | 工作区文件树 | 高 | **ArkTS 直接读沙箱**（工作区就在本机） | S |
| `ui-sidebar-documentpreview` | Markdown/代码/图片/PDF 预览 | 中高 | ArkTS 渲染 | M |
| `ui-jobs` | 后台任务列表与流式输出 | 中：长任务多时有用 | 需 side-channel | M |
| `ui-commands` | `/` 斜杠命令 | 中 | 命令本质是 prompt 文本 | S |
| `ui-input-trigger` + `ui-reference` | `/`、`@` 补全与引用 | 中 | 纯前端 + 本地索引 | M |
| `ui-skill` | 技能列表与技能卡 | 中 | 部分（技能内容注入 prompt） | M |
| `ui-permission-presets` | read-only / workspace-write / full 切换 | 高：手机更需要收紧权限 | 需 side-channel | S |
| `ui-theme` | 主题与字号 | 中：手机字号更重要 | 纯前端（令牌映射） | S |

### P2 — 可选 / 视需求

| 插件 | 判断 |
|---|---|
| `ui-schedule` | 手机端价值其实很高（定时任务 + 通知），但 host 侧 `schedule` 服务不在 ACP/SDK 里，需要 side-channel。**若做，配合系统通知是杀手级** |
| `ui-subagent` | 子智能体目录；ACP 无对应呈现，只能从事件推断 |
| `ui-workflow-run` | DSH 特有 workflow 节点，ACP 不支持 |
| `ui-agent-preset` | 预设选择；写入 host 配置需 side-channel |
| `ui-settings-*`（11 个） | 模型/密钥页已自建；其余是 host 配置写操作，需 side-channel 或直接改配置文件 |
| `ui-settings-plugin-inventory` | 只读清单，好做但价值低 |
| `ui-message-feedback` | 点赞/反馈，需要 host feedback 服务，未暴露 |
| `ui-open-in-app` | 手机上退化为系统“打开方式” |
| `ui-brand-official` | 品牌位，低优先级 |

### 不迁（平台或语义限制）

| 插件 | 原因 |
|---|---|
| `ui-sidebar-terminal` | 需要 PTY；鸿蒙沙箱无 `/dev/ptmx`，也无法 fork |
| `ui-plugin-manager` / `ui-settings-plugins` | 插件装卸依赖 pnpm 子进程，鸿蒙禁 fork |
| `ui-layout` / `ui-dockkit` / `ui-sidebar-right` | 桌面三栏 + 停靠布局，手机上是反模式 |
| `ui-shortcuts` | 键盘快捷键，触屏无意义 |
| `ui-directory-picker-native` | 已被系统文件选择器取代（ArkTS `picker`） |
| `ui-plan` / `ui-goal` | DSH 特有，ACP 明确不提供；要做得自己造 |
| `ui-user-questions`（`ask_user_question`） | ACP 不含 elicitation；要做得走 side-channel |

---

## 三、建议的落地顺序

**第 1 步（收益最大）：把后端从 SDK profile 换成 ACP profile。**
改动集中在 `model/DshClient.ets`（方法名与握手参数）和 `pages/Index.ets`（事件渲染）：

- `initialize` 增加 `protocolVersion` + `clientCapabilities`
- 会话用 `session/new` 建、`session/list` 列、`session/load` 恢复
- 渲染 `session/update` 的 `agent_message_chunk` / `agent_thought_chunk` / `tool_call(_update)`
- 处理服务端反向请求 `approval/request`（弹审批条），回 `session/request_permission` 的结果
- 发送中的“停止”按钮接 `session/cancel`

**第 2 步：在桥上加 side-channel。**
`bootstrap.cjs` 里已有 TCP 连接，把非 dsh 协议的方法挂在同一连接上（帧格式仍 JSON-RPC，
方法名加前缀 `ohos/`），用于：文件树、文件内容、diff、设置写入、定时任务、ask_user_question。

**第 3 步：把“本机优势”用满。**
工作区就在应用沙箱里，`ui-sidebar-files` / `ui-sidebar-documentpreview` / `ui-deliverables`
这三类在 Web 端要走 HTTP 的能力，在手机上可以直接用 ArkTS 文件 API 读，**比 Web 端更快**。

---

## 四、一句话总结

真正卡住手机端体验的不是 UI 插件数量，而是**协议**：SDK 协议缺审批、缺流式、缺会话列表。
把这层换成 ACP，再补一条自定义 side-channel，56 个插件里 **约 20 个**能迁、**6 个**是手机端刚需，
剩下的要么是桌面专属，要么被鸿蒙沙箱限制（PTY、子进程、原生插件）。
