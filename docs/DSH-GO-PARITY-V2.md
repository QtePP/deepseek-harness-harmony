# dsh-go v1.1.0 → 鸿蒙外壳 对齐矩阵（2026-11-15 重做）

> 对照基准：`ccch1mneyyy/dsh-Go` **v1.1.0**，commit `1c465301`（2026-11-15 拉取，`origin/main`）。
> 本仓：`QtePP/deepseek-harness-harmony`，HEAD 见 git log。
> 上一版矩阵基于 dsh-go 的旧快照（单 Flutter 工程、无远程/无桌宠/无插件 UI），**已过时**；
> 本文替换 `docs/DSH-GO-PARITY.md` 的结论表，旧文保留作历史记录。
>
> 可行性分级：
> **A** = 纯客户端能做完（ArkTS，无协议改动，可真机验收）；
> **B** = 能做，但要动 `host/` 或载荷（写 ohos 插件 / 加依赖 / 重打 225MB 载荷）；
> **C** = 鸿蒙上做不到，或缺宿主服务/系统权限/无法替代的原生库——**每一条都给了证据**。

---

## 1. 一句话结论

dsh-go 已经从「一个安卓聊天客户端」长成了「**本机引擎 + 远程主机 + 插件平台 + 桌宠/主题 + 分享与回放 + 手机操控**」的复合体（`app/lib` 下 123 个页面、`packages/` 五个独立包）。
我们的鸿蒙外壳在**对话本身**这一层已经对齐（流式、工具轨迹、排队、待办/目标、上下文、搜索、分享卡、会话管理、外观、字号）；
**没对齐的部分集中在三类**：① 引擎/主机拓扑（远程、网页版）；② 系统级能力（手机操控、悬浮桌宠）；③ 服务端配套（回放链接、插件市场、DS Bot）。

其中**语音输入这一条我上一版判错了**：AGENTS.md 曾写「本机 SDK 不含 `@kit.CoreSpeechKit`」，
本次实测 `hms/ets/kits/@kit.CoreSpeechKit.d.ts` 存在，且 `speechRecognizer` + `textToSpeech` 均可编译通过
（见 §4.1）。它是 A 级，不是 C 级。

---

## 2. 对话与聊天

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 流式回答 / 思考 / 工具轨迹 | 有 | 有（轨迹分类、失败高亮、耗时、子代理计数） | — | 已对齐 |
| 插话排队（中途发消息 → 排队 → 立即发送） | 有（原生 steering） | 有（队列 + 立即发送 = cancel 后重发） | — | 已对齐（语义差：ACP 无 steering，见 §4.2） |
| 过程折叠成一行 | 有 | 有（「已完成 · N 步 · 1 子代理 · 3.3s」） | — | 已对齐 |
| Markdown / 代码高亮 / 公式 | 有（gpt_markdown + val_latex + re_highlight） | 有（自绘 Markdown、代码块、无公式渲染） | A | **公式渲染缺**（LaTeX → 需自写或引 WebView 渲染） |
| 图片输入 | 有 | 有（相册 + 系统分享） | — | 已对齐 |
| **语音输入** | 有（sherpa-onnx 本地 ASR 模型） | 无 | **A** | **可做**：`@kit.CoreSpeechKit` 的 `speechRecognizer`（离线、中文、4.1.0+）。dsh-go 走 ONNX 自下载模型；我们走系统引擎，不需要载荷改动 |
| **朗读（TTS）** | 有（`speech_out.dart`） | 无 | **A** | **可做**：同 kit 的 `textToSpeech`（中英双语、三种音色） |
| 聊天建议 / 快捷问题 | 有（`chatSuggestions`） | 无 | A | 可做（纯 UI） |
| 回复偏好 / 折叠轮次 / 聊天字号 | 有 | 字号有；偏好/折叠无 | A | 可做 |

## 3. 对话详情与产出

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 单页「对话详情」：轨迹/改动/文件/进度/上下文/子代理 | 有（`ui/session`） | 分散：轨迹在气泡内、文件在产物面板、上下文小环、子代理只计数 | A | **可做**：把已有数据收进一个详情页 |
| **改动（diff 视图）** | 有 | 无 | A | **可做**：`Rollback` 已有每轮文件快照，天然能算 diff |
| 产出文件预览/分享/保存 | 有 | 有（预览、分享卡、存相册） | — | 已对齐 |
| 导出对话（ZIP） | 有 | 有（Markdown，`workspace/exports/`） | A | 可做 ZIP（ArkTS `zlib`） |
| 后台任务（查看输出/停止） | 有（`job_*` 工具） | 无（`tool-jobs` 在 ohos profile 被禁用） | **C** | 依赖子进程派生，鸿蒙禁 fork/exec |

## 4. 引擎与主机拓扑

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 本机引擎 | PRoot 装 Ubuntu + Node + dsh | 进程内嵌 Node（dlopen libnode） | — | **机制不同、能力等价**，且更轻（无 PRoot） |
| **远程主机（SSH / DS-Harness Remote）** | 有（`dartssh2` fork + `packages/dsh_remote`） | 无 | **B** | 可做：载荷里加纯 JS `ssh2`，把「本地 ACP」换成「SSH 通道上的 ACP」；`dsh_remote` 的协议是第三方包，需按其文档实现 |
| **网页版切换** | 有（`ui/web`，原生 ↔ 官方 Web UI 同一会话） | 无 | **C** | 官方 Web UI 由 `dsh-api-gateway` 提供，那是 ACP profile 未挂载的宿主服务（与 §4.3 自动化任务同一个根因）。**WebView 本身我们有**（文件预览已在用 `Web`），缺的是要打开的那个服务 |
| 模型/provider 切换 | 有（多 provider、自定义） | 有（会话内模型选择器，`configOptions` 驱动） | — | 已对齐（自定义 provider 需 B：走 settings 写入 dsh 配置） |

## 5. 系统级能力

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| **手机操控**（读屏、点按、输入，三档确认） | 有（`lib/phone` + 无障碍服务） | 无 | **B（重）** | 鸿蒙有 `AccessibilityExtensionAbility`（SDK 存在，第三方可实现，用户在设置里开启）。但要做成 dsh-go 那样（读屏文本 + 手势注入 + 分档确认 + 敏感操作拦截）是独立工程，且需系统级权限审批 |
| **桌宠 / App 外显示** | 有（`lib/pets` 20 文件、`lib/companion` 26 文件，PNG 帧动画 + 悬浮窗） | 无 | **B（受限）** | 悬浮窗要 `ohos.permission.SYSTEM_FLOAT_WINDOW`：SDK 里 `availableLevel: system_basic`（普通应用是 `normal`），需签名 ACL + AGC 受限权限审批。**美术素材是 AGPL/自有版权，不能拷**，只能自绘 |
| 通知（完成/失败/待审批） | 有 | 有（代码已落地；设备通知开关未开，未验） | A | 已有，待真机开系统开关后验收 |
| 桌面图标多套 | 有（`appIcon`，四款） | 无 | **B（受限）** | 鸿蒙是分层图标（foreground/background），**不支持运行时切换**；只能在打包时选定一套 |
| 桌面快捷方式 | 有（`iconShortcut`） | 有（「新对话」，want 路径已验证） | — | 已对齐 |

## 6. 外观

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 主题色 | 六套 + 跟随壁纸 + 自选色 | 六套 | **A** | 可做「跟随壁纸 / 自选色」（取色 + HSL 调色） |
| 壁纸主题（`lib/wallpaper`） | 有（自定义壁纸 + 取色渲染） | 无 | **A** | 可做：PhotoPicker 选图 → 背景 + 取色 |
| 深色/浅色 | 有 | 有（启动期应用，避免黑屏） | — | 已对齐 |
| 字号 | 有 | 有（四档） | — | 已对齐 |
| 动效开关 / 模糊 | 有（`animations` / `blur`） | 无 | A | 可做 |
| 桌宠 | 有 | 无 | B（受限，同上） | 见 §5 |

## 7. 语言

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 中/英双语（跟随系统 + 手动切） | 有（`lib/l10n`，全量） | **全中文硬编码** | **A** | 可做但工程量大：全部界面字符串迁到 `resources/base/element/string.json` + `zh_CN`/`en_US` 限定词目录，`i18n.System.setAppPreferredLanguage()` 切换 |

## 8. 分享与社区

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 分享卡（回复 → 图片） | 有 | 有（真机验成） | — | 已对齐 |
| **对话回放链接**（E2E 加密，浏览器里回放） | 有（`lib/share_hosted` + 自有服务器） | 无 | **C** | 依赖 **他们的**托管服务器 + 端到端加密协议；我们既没有服务器也不该连他们的。**替代方案（A）**：本地导出单文件 HTML（内嵌对话数据），用 `Web` 组件打开，可分享文件而非链接 |
| 分享配置打包（设置/插件/技能 → 链接/二维码/文件） | 有（`lib/share_code`） | 无 | **B** | 文件形态可做（A）；链接/二维码需服务器（C） |
| 论坛 / 社区 / DS Bot | 有（`lib/forum`） | 无 | **C** | 依赖他们的 Discourse 实例与 Bot 后端 |

## 9. 插件与自动化

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 插件原生界面（工具卡/表单/面板） | 有（`lib/plugins` 21 文件 + `packages/` SDK + `market/`） | 无 | **B** | ACP 没有插件 UI 通道。可做的路子：自定义 ohos 插件 + **文件侧信道**（像 `credentials-live` 监听 `.api-key` 那样），插件把卡片 JSON 写到 `<dsh-home>/cards/`，外壳轮询渲染。协议要我们自己定，不能复用他们的 SDK（AGPL + 形态不同） |
| 插件市场 | 有（`market/`） | 无 | C | 服务端 + 生态 |
| **自动化任务** | 有（`dsh-schedule` + 18-schedules 文档） | 无 | **C**（已实测） | `schedule` 插件要 `ctx.sessionController`（`dsh-api-session-controller` 32 个 peer 依赖，含整套 HTTP 网关）。插进 ohos profile 后 runtime 直接报 `pending (waiting for service: sessionController)` |
| Agent 预设编辑 | 有（`ui/agents`，读 `agentPresets`） | 无 | **B** | ACP 无该通道 |

## 10. 工具与其他

| 功能 | dsh-go | 本仓 | 分级 | 结论 |
|---|---|---|---|---|
| 终端 | 有（xterm + 工作区 shell） | 无 | **C** | 禁 fork/exec，没有可跑的东西 |
| 工作区文件浏览 | 有 | 有（`@` 引用 + 文件面板） | — | 已对齐 |
| 搜索对话（标题 + 内容） | 有 | 有（标题 + 缓存转录） | — | 已对齐（我们只搜本地缓存 200 条/会话，边界已在 UI 写明） |
| 用量统计 | 有（`lib/usage`，账本 + 统计） | 只有每轮「+N」 | **A** | 可做：把每轮增量累计成日/会话账本 |
| 更新检查 | 有（GitHub Releases） | 无 | A | 可做 |
| 横屏 / 平板 / 桌面 | 有（自适应） | 有（840vp 断点） | A | 需补横屏真机验收 |

---

## 11. 硬边界（C 级）逐条证据

1. **终端**：鸿蒙禁 fork/exec（`AGENTS.md` §5 第一条）。没有 shell 可跑，xterm 也无输入源。
2. **网页版**：官方 Web UI 由 `dsh-api-gateway` 提供；ACP profile 只挂 `dsh-acp-app`，网关整套不在。
   与「自动化任务」同一根因：缺的是宿主服务，不是工具。
3. **自动化任务**：实测日志 `schedule (@deepseek-ai/dsh-schedule): pending (waiting for service: sessionController)`
   （2026-11-13 本地起 runtime 取证，已回滚）。
4. **回放链接 / 分享码 / 论坛 / DS Bot / 插件市场**：全部依赖 dsh-go 自己的服务端（`services/`、`market/`、`site/`）。
   我们既不该连、也没有对等实现。可替代的是「本地文件形态」（HTML 回放、ZIP 打包）。
5. **桌宠 App 外显示**：`ohos.permission.SYSTEM_FLOAT_WINDOW` 在 SDK 的 `PermissionDefinitions.json` 里
   `availableLevel: system_basic`（普通应用 `normal`），需签名 ACL + AGC 受限权限审批；素材版权也不允许拷。
6. **桌面图标多套**：鸿蒙分层图标在打包期固定，运行期不可换。
7. **手机操控**：技术上可做（`AccessibilityExtensionAbility` 在 SDK 里），但等于重写一个无障碍代理，
   且要过系统权限审批——不是「抄一段 UI」的量级。

## 11.5 官方 dsh 上游（2026-11-15 拉取）

基准：`deepseek-ai/deepseek-harness` master `39163dd3`（release 同步提交，`dsh` **0.2.2-rc.3**）。
我们载荷里钉的是 **0.2.1-rc.4**。

**协议面：没变。** 逐条核对 `packages/acp/acp/README.md` 与源码，仍是
`initialize / session/new / session/list / session/resume / session/close /
session/set_config_option / session/prompt / session/cancel（+ `$/cancel_request`）`，
服务端通知仍是 `session/update`（5 种 kind：`agent_message_chunk` / `agent_thought_chunk` /
`tool_call` / `tool_call_update` / `usage_update`）与 `session/request_permission`。
**结论：我们的客户端对 0.2.2 仍然兼容，不需要改协议代码。**

官方 README 里还有一句对我们特别重要的定性：

> this server intentionally exposes only the standard ACP v1 surface …
> Avoid it when a human needs DSH-specific presentation cards, plans, titles, todos,
> terminal views, or elicitation.

这等于官方承认：**待办/计划/标题/卡片/终端视图不在 ACP 里，是有意为之**。
我们从 `tool_call.rawInput` 反推待办/目标的做法，是这个约束下的唯一出路，不是权宜之计。

**工具面：官方比我们多 5 个包**（载荷里没有）：
`tool-agent-team`、`tool-lsp`、`tool-office`（koffi，签名域外无法加载）、
`tool-subagent-oar`、`tool-worktree`（要 git）。
我们载荷里其实**已经有** `tool-schedule` / `tool-jobs` / `tool-terminal` / `tool-workflow` / `tool-present`，
卡住的从来不是包，是宿主服务（§11.3）。

**要不要升级载荷？** 收益 = 新工具 + 上游修 bug；成本 = 重跑 `assemble-payload`
（618 包重装 + 225MB 重打）+ 全量回归。协议不变，所以**不升级也不会坏**；
建议单独开一轮做「升 0.2.2 并回归」，而不是夹在功能开发里。

## 12. 与「三端一致」的关系

dsh-go 覆盖 Android（+ 桌面/网页形态）；本仓覆盖鸿蒙手机/平板/2in1。
「三端一致」在本仓的落点是：**同一套 dsh 引擎 + 同一套能力口径 + 各端各自的系统集成**。
按上面矩阵，真正影响一致性的缺口排序（性价比从高到低）：

1. **语音输入 / 朗读**（A，系统 kit 现成，用户可感知）
2. **中英双语**（A，工程量大但机械）
3. **对话详情页（含 diff）**（A，数据都已有）
4. **用量统计**（A，小）
5. **壁纸/自选主题色**（A，中等）
6. **远程主机（SSH）**（B，要动载荷）
7. **插件原生卡片**（B，要自定协议）
8. **手机操控 / 桌宠**（B 重，且要权限审批）

## 13. 本轮落地

见 `CHANGELOG.md` 对应条目与 AGENTS.md §7。本轮先做两件事：

- **修正 AGENTS.md 的错误结论**：`@kit.CoreSpeechKit` 存在（`hms/ets/kits/`），语音输入与朗读从 C 降为 A。
- 新增本文件，替换过时矩阵。
