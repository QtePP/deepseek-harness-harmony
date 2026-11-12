# dsh-go 能力对齐矩阵

> 对照对象：**dsh-go**（Flutter / Android 客户端，`ccch1mneyyy/dsh-Go`）源码克隆 `/tmp/dsh-go-ref`，
> 依据 `docs/official-parity.md`、`docs/roadmap.md`、`docs/guide/zh/01-chat` … `12-bots`、`README.md`。
> 本仓库基线：HEAD `f4e0e58` + 2026-11-12 的聊天对齐改动（工作树）。
> 判定方式：读本仓 `entry/.../*.ets`、`host/*` 与 dsh 源码（`~/deepseek-harness`）；
> 仓库内已记录的实测（`AGENTS.md` §7、`docs/SPIKE-ACP.md`、`docs/GAP-ANALYSIS.md`）作为既成事实引用。
> **未标「真机」的都是读码结论。**

---

## 0. 一句话结论

- **能纯客户端对齐的，本轮已经对齐**：插话队列、待办条、上下文小环、引用追问、会话搜索（标题）。
  五项全部零协议改动。
- **卡住对齐的不是 UI，是协议面**：ACP 只有 9 个方法、5 种 `session/update`，没有 steering、
  没有 todo / goal / plan / schedule 投影、没有 `commands/execute`、没有 fork / export / jobs /
  子代理目录。dsh-go 的「原生页」大多是 DSH Web API 端点的客户端，本仓没有这些端点。
- 因此 dsh-go 的**「插话」在 ACP 下不可得**，只能降级为**排队续发**（§4.2）。
  「投影类」UI 可以从 `tool_call.rawInput` 反推（待办条就是这么做的）；「宿主能力」只能写 ohos
  插件经桥上报（`boot-report` / `credentials-live` 的模式）。
- **三类明确不做**：要服务端的（分享链接、账号、社区、DS Bot）、要子进程的（插件市场、后台任务、
  终端）、平台权限拿不到的（手机操控）。

---

## 1. 判定口径

| 档位 | 含义 |
|---|---|
| 现状：**有** | 本仓代码里已有原生入口，且能用 |
| 现状：**部分** | 数据或模型侧有、UI 缺；或 UI 有、能力只覆盖一半 |
| 现状：**无** | 没有任何入口 |
| 可行性 **A** | 纯客户端：现有 ACP / SDK 消息 + 本地数据即可，不动协议、不加插件 |
| 可行性 **B** | 要动宿主：ohos 插件经桥上报，或 profile 增行（成本按「一个插件 + 一次载荷迭代」估） |
| 可行性 **C** | 协议或平台不可得：ACP 无通道，且平台禁 fork/exec、或系统权限不开放 |
| 结论：**本轮已落地** | 2026-11-12 工作树里的改动，本地 `bash scripts/test.sh arkts local` 全绿 |
| 结论：**建议下一轮** | 读码判断可行，尚未实现 |
| 结论：**不适用** | 平台/协议/产品口径决定不做，附理由 |

---

## 2. 对齐矩阵

### 2.1 对话与输入

| dsh-go 能力 | dshharmony 现状 | 可行性 | 结论 |
|---|---|---|---|
| **插话队列**：生成中发送三选（插话 / 中断并发送 / 排队），排队消息可改插话、可撤回 | **部分**（本轮补齐排队）：跑动中发送入队，输入框上方排队条可单条 ×、「立即发送」先 `session/cancel` 再续发，发送键在跑动中显示「排队」 | A（客户端队列）+ **C**（steer 不可得） | **本轮已落地**（排队语义）；真·插话不适用，见 §4.2 |
| **待办条**：输入框上方常驻「3/7 · 正在：…」，点开原地展开清单 | **有**（本轮）：`todo_write` 参数投影成 `TodoItem[]`，常驻折叠条，冷启动/切会话从轨迹重建 | A | **本轮已落地** |
| **上下文占用**：输入条圆环 + 用量面板（占用/每轮 token/明细） | **部分**（本轮补环）：`usage_update` 的「上下文 used/size」→ 22vp 环（70%/90% 变色）+ 点击 toast 精确值；无明细、无每轮 token | A（占用比）；**B**（明细需插件上报） | **本轮已落地**（占用比）；明细不适用 |
| **过程折叠**：正常结束的一轮把思考+工具收成一行「已完成 · N 次工具调用」，停止/出错不收，可在外观里关 | **有**（本轮）：轨迹条收成「已完成 · N 步 · 8.4s」；失败转红并写「有失败」，被取消写「已中断」；默认收起。仍无「外观开关」 | A | **本轮已落地**（文案与状态）；外观开关后置 |
| **斜杠命令**：`/compact /export /plan /goal /permission /new /model`，执行走 `commands/execute` | **部分**（本轮）：输入 `/` 弹出 8 条本地动作（新会话 / 模型 / 停止 / 清空排队 / 文件 / 会话 / 设置 / 待办）；`/compact`、`/export`、`/goal` 这类引擎命令没有入口 | A（本地动作映射）；**C**（引擎命令） | **本轮已落地**（本地动作）；引擎命令不适用 |
| **@ 引用**：文件 / 对话 / 子代理（`fileReferences/list`） | **部分**（本轮）：输入 `@` 列出工作区文件（相对路径、4s TTL 索引、300 条上限），点选插入 `@路径`；无对话 / 子代理引用、无缩略图与预览 | A（文件、对话）；**C**（子代理） | **本轮已落地**（文件）；对话引用后置 |
| **语音输入**：系统识别优先，引擎插件兜底 | **无** | A（HMS `@kit.CoreSpeechKit` 设备端识别 + `MICROPHONE` 权限） | **建议下一轮** |
| 附件：相册 / 拍照 / 文件，单条最多 9 个 | **部分**：相册选图 + 系统分享图片进新对话（`ShareInbox`），内联 image block；无拍照、无文件附件 | A（拍照 = picker 的 CAMERA） | 部分已有，补齐成本低 |
| 模型与思考深度切换 | **有**：`session/set_config_option` + 选择器（选项集收缩已适配） | — | 已有 |
| 权限审批卡 + 权限三档 | **有**：`session/request_permission`（allow-once / reject-once，fail-closed）+ 只读 / 平衡 / 宽松 | — | 已有 |
| 凭据遮挡：已发送文本里的 Key 只显示前 8 位 | **有**（本轮）：`common/SecretMask.ets` 命中 `sk-`/GitHub/AWS/JWT/Bearer，渲染时只留前 8 位，气泡下给「已隐藏 N 处凭据」可展开；存储、复制、重发保真 | A（纯正则） | **本轮已落地** |

### 2.2 会话与导航

| dsh-go 能力 | dshharmony 现状 | 可行性 | 结论 |
|---|---|---|---|
| **会话搜索**：抽屉顶部，标题即时匹配、多关键词、高亮；本机引擎可搜内容 | **部分**（本轮）：标题子串过滤（大小写不敏感、空白=不过滤、无匹配有空态、可清除）；无内容搜索、无高亮、无多关键词 | A（标题）；**B**（内容：host FTS + 桥） | **本轮已落地**（标题）；内容搜索后置 |
| **引用追问**：引文放输入框上方，以引用块发出；可选中片段引用 | **部分**（本轮）：长按消息 ›「引用到输入框」，生成 `>` 前缀（≤6 行 / 400 字），可编辑后再发 | A | **本轮已落地**（简版）；选中片段引用建议下一轮 |
| **重新回答**：最后一条回复 ↻，在新对话里重生成，原对话不变 | **有**（本轮）：长按回复 ›「重新回答（新会话）」——保留到该问题前的历史，新会话重发同一问题；ACP 服务端上下文从本轮重启（toast 明说） | A | **本轮已落地** |
| 从这里分叉 | **有**：`forkFrom()` 复制本地轨迹到新 session | — | 已有 |
| 会话重命名 / 归档 / 文件夹 / 多选 / 排序 | **部分**：重命名、删除、项目分类有；无归档、文件夹、多选、排序 | A | 建议下一轮（按需） |
| 未读 / 待确认标记与筛选 | **无** | A | 建议下一轮（低优先） |
| 轨迹与回合用量 | **部分**：工具轨迹（分类、失败高亮）+ 活动条；无时间概览、无回合脚注 token | A | 建议下一轮 |
| 会话日志导出（`/export` → ZIP） | **部分**（本轮）：`/导出对话` 把转录写成 Markdown（思考折叠块 + 工具表）到 `workspace/exports/`；无 ZIP、无服务端原始日志 | A（导出本地缓存的 Markdown）；**B**（完整 ZIP 要解 `.zstd`） | **本轮已落地**（Markdown）；ZIP 不适用 |

### 2.3 消息与产物

| dsh-go 能力 | dshharmony 现状 | 可行性 | 结论 |
|---|---|---|---|
| **图片保存到相册**（长按图片 / 查看页右上角） | **有**（已验成）：全屏查看器右上角 `SaveButton`，点按换临时媒体写权限 → `createAsset`；长按对话里的图片进全屏（真机修了两处：父手势吞子手势、顶栏落进状态栏）。**保存点击本身未验成**——注入点击没有产生相册条目，疑为安全组件不认注入事件，需真手点一次。`showAssetsCreationDialog` 路线不成立（只收媒体库 URI，沙箱路径被拒） | A（安全组件） | **入口已落地**；保存动作待真手验证 |
| **分享卡**：回复 / 选中消息 / 整段对话 → 图片 | **有**（本轮）：长按回复 ›「分享为图片」→ `componentSnapshot` 渲染气泡为 PNG → ShareKit 系统分享面板（真机「分享 1 项 · 16.82 KB」）。`uri` 必须用 `fileUri.getUriFromPath()`，手拼 `file://` 会被 `IPC data is oversized` 拒绝；图片被拒时自动退到分享文字 | A：`componentSnapshot` + ShareKit | **本轮已落地** |
| **分享链接 / `.dshgo` 回放 / 分享码 / 我的分享链接** | **无** | **C**：需自建服务端与账号体系，且与「数据全部留在本机」口径冲突 | **不适用** |
| 产物文件卡与预览 | **有**：`ArtifactDock` + 内嵌 Web / 图片 / 文本预览 + 全屏 | — | 已有（dsh-go 另支持 Office 转 PDF，本仓无 koffi） |
| 消息反馈（好 / 有问题） | **无** | — | 不做（dsh-go 自己也已移除） |
| 凭据遮挡 | 见 2.1 | A | **本轮已落地** |

### 2.4 外观与语言

| dsh-go 能力 | dshharmony 现状 | 可行性 | 结论 |
|---|---|---|---|
| **主题**：明暗 / 六套配色 / 自定义色相 / 跟随壁纸 | **部分**（本轮补六套强调色 + 明暗三档：跟随系统/浅色/深色，启动期生效、持久化；暗色补齐 4 个缺失 token）：`common/Theme.ets` 六色 + `@StorageLink('accent')` 绑定 9 个组件，设置页可选、即时生效、持久化；明暗仍跟随系统，背景与气泡保持中性；无自定义色相、无跟随壁纸 | A（强调色）；**B**（完整配色方案要抽色板层）；**C**（跟随壁纸无三方 API） | **本轮已落地**（强调色）；明暗缺口与壁纸不适用 |
| **对话字号四档**（只放大对话内容，叠加系统字号） | **有**（本轮）：`common/Typography.ets` 四档 0.9×/1×/1.15×/1.3×，`AppStorage['fontScale']` 绑定；只缩放对话内容（正文/思考/工具行/Markdown），按钮与说明保持原尺寸，即时生效并持久化 | A | **本轮已落地** |
| **中英双语**（跟随系统 / 简体中文 / English） | **无**：约 200 处中文字面量硬编码在 `.ets` 里（去重后 206，含模板串） | A：`resources/base|zh_CN|en_US/element/string.json` + `$r('app.string.…')` | **建议下一轮**（机械、量大，先做设置/诊断/错误面） |
| 桌宠 / 壁纸 / 启动画面 | **无** | **C**：Live2D 运行时 + 素材授权，且与外壳定位无关 | **不适用** |

### 2.5 引擎与能力

| dsh-go 能力 | dshharmony 现状 | 可行性 | 结论 |
|---|---|---|---|
| **插件市场**（安装 / 更新 / 卸载 / 批准构建脚本） | **无**；`plugin-manager` 行已被平台补丁禁用 | **C**：安装依赖 pnpm 子进程（禁 fork/exec）；且插件必须进 profile 的 bundle 依赖闭包才可解析 | **不适用**（替代路径 = 编进 ohos profile 模板，已有 3 个先例） |
| 插件开关与插件自带设置页 | **部分**：「dsh 能力开关」= 生成 `user.patch.yml` 的 preset 级开关（重启生效）；无插件自带表单 | A（按 schema 渲染表单） | 开关已有；表单建议下一轮 |
| 模型渠道（DeepSeek 账号 / ChatGPT·Claude 订阅 / 自定义渠道） | **部分**：API Key + 模型选择器；无账号 OAuth、无自定义渠道表单 | **B**（渠道写入要经 host 配置或插件） | 建议下一轮（自定义渠道） |
| **子代理谱系**：顶栏「N 个子智能体」、谱系树、点开接着聊 | **部分**：模型侧有 `subagent` / `subagent_fork` / `list_agents` / `send_message`（进程内可用）；客户端零 UI | A（工具行展示）；**B**（谱系/续聊需插件上报 `subagentCatalog`） | **建议下一轮**（先做展示） |
| **目标条**：编辑 / 暂停 / 恢复 / 清除 | **部分**（本轮补只读条）：`model/GoalModel.ets` 从 `create_goal` / `update_goal` 参数投影 objective + 状态（进行中/已暂停/已完成/受阻），冷启动按轨迹重建；编辑动作仍无入口 | A（只读条，从 tool_call 投影）；**C**（写操作无 ACP 通道） | **本轮已落地**（只读）；编辑不适用 |
| **自动化任务（schedule）**：列表 / 筛选 / 详情 / 运行记录 / cron 编辑 / 顶栏时钟 | **无**：`schedule` + `tool-schedule` 只在 `dsh-sdk-app` / `dsh-web-app` bundle 里，ohos profile（base + acp-app + ohos bundle）未挂载 | **B**：profile 增两行 + 自写投递 provider；后台触发不可靠 | **建议下一轮**（最小闭环） |
| **后台任务（jobs）**：`job/list` / `job/follow` / `job/kill`、实时输出 | **无**：`tool-jobs` 已禁用 | **C**：依赖子进程派生 | **不适用** |
| **远程主机**：SSH / DSH Remote（WebRTC / Relay） | **无**（进程内运行时，没有远程连接概念） | **C**：远程主机跑的是 `dsh web`（HTTP `/api/*` + WS），是另一套协议；且与「不连电脑」口径直接冲突 | **不适用**（除非先改产品口径） |

### 2.6 平台与形态

| dsh-go 能力 | dshharmony 现状 | 可行性 | 结论 |
|---|---|---|---|
| **手机操控**：无障碍读屏 + 点按、三档确认、悬浮条、Android Shell | **无** | **C**：鸿蒙上「控制其它 App」要系统级签名 / 受限 ACL，三方应用拿不到（`docs/NEEDS-ANALYSIS.md` §1.D 已判定此路为死） | **不适用** |
| **网页版切换**：原生 / 网页一键切换、同一对话、手机布局注入 | **无** | **C**：本仓定位是「不套壳浏览器」；设备上也没有 `dsh web` 监听端口（只有 4517 桥） | **不适用** |
| 系统通知（完成 / 出错 / 等你确认 / 提问，点开直达） | **有**（本轮）：`common/Notify.ets`，后台时一轮完成 / 出错 / 待审批各发一条本地通知，前台不发，首次用才要授权；暂无「点开直达」wantAgent | A：`NotificationKit` 本地通知 + 已有 `session/status`、`request_permission` 事件 | **本轮已落地**（通知）；直达后置 |
| 系统分享进来（文字 / 图片 → 新对话） | **有**：`ShareInbox`（冷启 `onCreate` / 热启 `onNewWant`，图片先拷进沙箱） | — | 已有 |
| 桌面快捷方式 / 快速设置磁贴 | **部分**（本轮补桌面快捷方式）：`shortcuts.json` + `ohos.ability.shortcuts` 元数据，want 的 `shortcutId` 经 `AppStorage` 交给页面，冷启动与 `onNewWant` 都开新会话（`aa start --ps shortcutId new_chat` 实测打开「新会话」）。**桌面长按菜单未显示该条目**（启动器行为，未深究）；快速设置磁贴未做 | A：`shortcuts` profile + want 参数 | **本轮已落地**（want 路径）；启动器显示待查 |
| 应用内更新（GitHub Releases + SHA-256 + PackageInstaller） | **无** | **C**：鸿蒙走 AGC 分发，没有 APK 侧载等价路径；本仓发布包只能经 AGC | **不适用** |
| DS Bot / 社区 / 论坛 | **无** | **C**：服务端 + 插件生态，与外壳定位无关 | **不适用** |

### 2.7 反向对照（本仓有、dsh-go 没有）

| 能力 | 说明 |
|---|---|
| 回合回撤并还原该轮写入的文件 | `model/Rollback.ets`；dsh-go 只有「编辑后重发」 |
| 项目 = 独立 workspace | `model/ProjectModel.ets`，每项目一个目录；dsh-go 的工作区是「主机上的目录」 |
| 进程内运行时，无 Linux 环境 | 装包即用，无 proot / Ubuntu；代价是没有 bash / pnpm / git |
| 能力开关即 profile 补丁 | Settings 生成 `user.patch.yml`，重启生效；dsh-go 是运行时装插件 |

---

## 3. 本轮已落地（2026-11-12）

验收状态：`bash scripts/test.sh arkts local` 全绿（ArkTS 38 文件 + LocalUnit 构建通过；三轮合计 15 项）。
**真机未验收。**

### 3.1 插话队列

- **行为**：跑动中发送 → 入队（toast「本轮进行中，已排队；结束后自动发送」）；输入框上方排队条
  显示「排队 N 条 · 本轮结束后自动发送」，每行可 ×；「立即发送」在 ACP 下先 `session/cancel`
  掐断当前轮，再由 settle 路径续发；发送键在跑动中显示「排队」。
- **实现**：`pages/Index.ets` 的 `QueuedTurn` / `enqueue` / `dequeueAt` / `sendQueuedNow` /
  `flushQueue`；`view/ChatView.ets` 的 `queueStrip()`。
- **续发触发点两处**（这是关键，别只改一处）：
  - ACP 路径：`send()` 的 `finally` —— `session/prompt` 的响应就是回合结束；
  - SDK 路径：`turn/end` 事件 —— prompt 早在入队时就回了回执，settle 只能靠事件。
- **队列清空点**：切会话、新会话、断线重置都会清。队列属于它被输入的那个对话，带进别的会话
  等于把话说到错上下文。
- **已知边界**：SDK profile 下「立即发送」是空操作（SDK 5 个方法里没有 cancel），只能等
  `turn/end`；ACP 下才有「掐断当前轮」的语义。

### 3.2 待办条

- **数据来源**：`todo_write` 的参数 `{todos:[{content,status}]}`，语义是**整表替换**
  （`@deepseek-ai/dsh-tool-todo` 头注释：last-write-wins）。
- **投影点两处**：ACP `tool_call.rawInput`（`packages/acp/acp/src/updates.ts` 的 `toolCallUpdate`）、
  SDK `tool/call` 的 `arguments`。解析器 `model/TodoModel.ets` 只接受文档形状，其他形状忽略
  （错的行事历比没有更糟）。
- **冷启动为什么能重建**：参数随轨迹持久化，`refreshTodos()` 从消息缓存倒序找最后一个
  `todo_write` 重放即可，不需要向运行时再要一次。
- **已知边界**：模型不调 `todo_write` 就没有条；`tools` 行是 `mode: native`，`todo_write` 在模型
  工具表里（21 个直出工具之一）。

### 3.3 上下文小环

- **数据来源**：`usage_update` 的 `{used, size}`（dsh 变体，不是 ACP 规范的 tokens）。客户端把它写成
  assistant 行的注记「上下文 used/size」，环从注记解析——注记是随消息持久化的，所以切会话也在。
- **显示**：22vp 环 + 70% / 90% 两档变色，点击 toast「上下文 12k/128k · 9%」。
- **已知边界**：`usage_update` 在 `assistant/message` 之后才发（同文件 `assistantUpdates`），一轮中间
  环不刷新；没有 breakdown、没有每轮 token、没有费用。

### 3.4 引用追问

- **行为**：长按任意消息 ›「引用到输入框」→ 取前 6 行 / 400 字，逐行加 `>` 前缀，插到 draft 顶部，
  可编辑后再发。
- **与 dsh-go 的差异**：dsh-go 是「输入框上方的引文胶囊 + 选中片段引用」，本仓是 draft 前缀。
  模型读到的内容等价，用户保留编辑权；没有独立胶囊是因为 ACP `prompt` 只收 text / image block，
  没有引用类型可发。
- **已知边界**：不支持「选中一段文字再引用」（Markdown 组件目前没有选区 API）。

### 3.5 会话搜索

- **行为**：会话栏顶部按标题过滤，大小写不敏感，空白输入 = 不过滤（不是「无结果」），无匹配显示
  「没有匹配的会话」，可一键清除。
- **数据源**：本地 `SessionStore` 索引。**不是** `session/list` —— 后者只返回已关闭 / 已持久化的
  会话，活跃会话不在其中，当索引用会漏掉正在聊的那个。
- **未做**：内容搜索、多关键词、高亮（见 §6）。

### 3.6 目标条（只读）

- **数据来源**：`create_goal` 的 `{objective}` 与 `update_goal` 的 `{action, objective}`；`get_goal`
  不改变状态，被忽略。
- **投影点两处**：ACP `tool_call.rawInput`、SDK `tool/call` 的 `arguments`；解析器
  `model/GoalModel.ets` 把动作映射成状态（`active` / `paused` / `completed` / `blocked`）。
- **冷启动**：`refreshGoal()` 与 `refreshTodos()` 同一套倒序重放，取最新一次 goal 写入。
- **为什么只读**：编辑走 `goals/*`，ACP 没有这个通道；照抄 dsh-go 的编辑面板会得到点不动的按钮。
- **已知边界**：目标被清除（`update_goal action` 里没有清除语义时）不会从轨迹里消失；会话里没有
  goal 工具调用时条不显示。

### 3.7 重新回答

- **行为**：长按回复 ›「重新回答（新会话）」——保留到该问题之前的消息，新建会话，重发同一个问题
  （文字 + 图片附件一起）。
- **实现**：`Index.regenerate()` 复用分叉的路径（`store.save` → 切 `currentId` → `ensureAcpSession`
  → `send`）。
- **代价要说明**：ACP 没有历史注入通道，新会话的服务端上下文从这一轮重新开始；toast 明写
  「服务端上下文从本轮重新开始」，不假装上下文还在。
- **未做**：不新建会话的原地重答（需要 `session/fork` 或删除末轮，ACP 都没有）。

### 3.8 完成摘要（过程折叠）

- **行为**：一轮 settle 后轨迹条从「N 步」变成「已完成 · N 步 · 8.4s」；有失败转红写「有失败」，
  有未完成项写「已中断」。
- **数据**：`ToolTrace.at` / `doneAt` 已在 ACP 与 SDK 两条路径都记录，时长是首调用到末调用。
- **未做**：外观里的「完成后收起过程」开关（当前默认收起，展开状态不持久化）。

### 3.9 凭据遮挡

- **范围**：`sk-…`、`ghp_/gho_/ghs_/ghu_`、`AKIA…`、JWT（`eyJ.…`）、`Bearer …`。
- **只遮挡渲染**：`message.text` 保持原文，复制、重发、回撤都不受影响；气泡下给「已隐藏 N 处凭据」
  可展开。
- **未做**：用户自定义正则、更多云厂商 key 形状（宁可漏，不可误遮正文）。

### 3.10 系统通知

- **触发**：后台时一轮完成 / 出错 / 等待审批；前台不发。
- **实现**：`common/Notify.ets` + `EntryAbility` 的 `onForeground` / `onBackground` 写
  `Notify.setForeground()`（静态字段而非 AppStorage，ability 不是 UI 组件）。
- **授权**：首次后台通知时 `requestEnableNotification`，用户拒绝后不再打扰。
- **未做**：点通知直达会话（wantAgent）、通知分组与免打扰时段。

### 3.11 保存图片到相册

- **路线**：`SaveButton` 安全组件 → 临时 `WRITE_IMAGEVIDEO` → `createAsset` → 写字节。
  **`showAssetsCreationDialog` 不行**：它只收媒体库 URI，沙箱路径进不去（读 SDK d.ts 与错误码
  `-203/-3006` 得出），网上流传的「用户确认即授权」用法在这里不成立。
- **入口**：全屏查看器右上角；对话里长按图片直接进全屏。
- **未做**：批量保存、保存视频（本仓不产生视频）。

### 3.12 斜杠命令面板（本地动作）

- **行为**：草稿以 `/` 开头且是单个 token 时，输入框上方弹出命令面板；点一条即执行并清空草稿。
  八条：新会话 / 模型 / 停止 / 清空排队 / 文件 / 会话 / 设置 / 待办。
- **为什么只有八条**：`commands/execute` 在 ACP 下不存在（§4.4），`/compact`、`/export`、`/goal`
  都执行不了；列出来就是给用户一个点不动的菜单。
- **已知边界**：无参数补全、无键盘上下选择（手机没有物理键盘这一诉求）。

### 3.13 `@` 文件引用

- **行为**：草稿里最后一个 `@` 之后的 token 作为查询，列出工作区文件（相对路径，最多 8 条），
  点选把 `@token` 替换成 `@相对路径`。
- **索引**：`common/WorkspaceFiles.ets` 深度 3、上限 300 条、跳过 `node_modules` / `oh_modules` /
  `.git` / `build`；`Index` 侧按 4s TTL 缓存，输入不触发递归遍历。
- **为什么用相对路径**：运行时的 cwd 就是项目 workspace，相对路径在转录里可读、模型也能直接用。
- **已知边界**：不索引沙箱外（绑定目录）的文件；没有缩略图/内容预览；`@` 之后打空格即关闭面板。

### 3.14 主题色（六套强调色）

- **范围**：只换强调色——按钮、链接、选中行、上下文环、发送键、进度；背景/气泡/文字保持中性资源，
  因此暗色模式不需要第二套配色表。
- **实现**：`common/Theme.ets`（六色 + id↔value 归一化）、`AppStorage['accent']` 为传输通道，
  9 个组件用 `@StorageLink('accent')` 绑定；`AppConfig.saveAccent()` 同时写 prefs 与 AppStorage，
  重启后从 prefs 恢复。
- **已知边界**：无自定义色相、无跟随壁纸（平台无三方 API）；`surface_selected` / `bubble_user`
  仍是固定资源，不与强调色联动（避免暗色对比度回归）。

### 3.15 真机验收（2026-11-12，手机，ACP profile）

`bash scripts/deploy.sh <serial>` 调试签名装机，`devecocli ui` 驱动真机逐项点击。

| 项 | 结果 |
|---|---|
| 冷启 / 安装 / 会话恢复 | 通过 |
| `/` 命令面板（9 条） | 通过（首版手机端回调缺失，已修） |
| `@` 文件选择与插入 | 通过（首版缓存键缺陷导致列表恒空，已修） |
| `/导出对话` | 通过：写出 `workspace/exports/<标题>-<时间>.md`（3.3 KB），模型随后读到该文件 |
| 待办条 | 通过：模型 `todo_write` 后显示「3/3 · 已全部完成」 |
| 目标条 | 通过：`create_goal` 后「进行中」，`update_goal complete` 后转「已完成」并变灰 |
| 完成摘要 | 通过：`已完成 · N 步 · 2.6s`、`有失败 · 8 步 · 3.0s` |
| 上下文小环 | 通过（输入条右侧） |
| 凭据遮挡 | 通过：`sk-abcde…` + 「已隐藏 1 处凭据」 |
| 排队发送 | 通过：跑动中入队 → settle 后自动发出，模型确认收到 |
| 主题色 | 通过：琥珀即时生效、重启后保持（设置页「保存」按钮已改为跟色） |
| 重新回答 | 通过：新会话「· 重答」、原会话保留（首版标题被覆盖、多一条服务端提示，已修） |
| 长按菜单 | 通过：复制 / 引用 / 分支 / 重答 / 回撤 |
| 桌面快捷方式「新对话」 | 通过（want 注入）：`aa start --ps shortcutId new_chat` 打开「新会话」；桌面长按菜单未显示条目 |
| 外观三档 | 通过：浅色 / 深色各自重启后保持；**运行中切色会黑屏**，故只在启动期应用（已按此实现） |
| 分享卡（回复 → 图片） | 通过：系统分享面板「分享 1 项 · 16.82 KB」 |
| 图片保存到相册 | **已验成（真手）**：系统授权框 + toast「已保存到相册」；自动化点击无效（安全组件）：长按 → 全屏 → 「保存图片」按钮可见且位置正确（修了父手势与状态栏两处缺陷）；点击未产生相册条目，疑安全组件不认注入点击 |
| 通知 | **未验成**：设备 `allowEnableNotification=false`，`requestEnableNotification` 不弹框也不改状态；需在系统设置手动开启后再验 |

---

## 4. 协议边界（后续 agent 必读）

### 4.1 两套协议的分野

| | dsh-go | dshharmony |
|---|---|---|
| 传输 | `POST /api/<endpoint>` + WebSocket `/api/remote.mux`（`packages/dsh_client/lib/src/carrier.dart`） | 回环 TCP `127.0.0.1:4517` 上的换行 JSON-RPC，stdio 被 `PassThrough` 劫持 |
| 协议 | DSH Web API（`packages/api/session-controller` 一族端点） | ACP（`--profile acp`，ohos profile 下重映射为 `ohos`） |
| 方法面 | 全量端点：prompt / updateQueue / fork / export / goals / jobs / commands / settings / fs / upload … | **9 个方法**（8 请求 + 1 通知）+ **5 种 `session/update`** |
| 插话 | `session.prompt` 带 `mode: 'queue' \| 'steer'` | **无** |

结论：**dsh-go 的「原生页」大多是 Web API 端点的客户端**。本仓没有这些端点，照抄 UI 会造出点不动
的按钮。

### 4.2 `session/prompt` 在跑时拒绝第二条

- 代码：`packages/acp/acp/src/session.ts:225`

  ```ts
  if (this.inflight !== undefined) throw invalidParams('a prompt is already in flight for this session')
  ```

- 同一个方法内部其实调的是 `agent.followup(message)`（`session.ts:275`），语义是**排到下一轮**
  （`next-turn`）。真正「下一步就看到」的是 `agent.steer()`（`packages/core/agent-loop/src/agent.ts:183`，
  写入 `next-step`）。Web API 才暴露这个选择（`packages/api/session-controller/src/commands.ts:338-339`：
  `mode === 'steer' ? agent.steer(message) : agent.followup(message)`）；**ACP 没有暴露 mode**。
- 所以：**「真·插话」在 ACP 下不可得**。能做到的上限是「客户端排队 + 上一轮 settle 后续发」。
  想让模型立刻看到，唯一手段是 `session/cancel` 掐断当前轮再发——本仓「立即发送」做的就是这件事，
  按钮文案也如实这么写。
- 另一个坑：`agent.cancel()` 默认 `keepInbox: false`，会清空服务端 inbox。**排队必须放在客户端**，
  不能指望服务端的 `next-turn` 替你留住。

### 4.3 `session/cancel` 是通知，不是请求

- 注册在 `onNotification`（`packages/acp/acp/src/index.ts:388`）；带 `id` 当请求发会 `Method not found`
  （`AGENTS.md` §4.2 真机实测）。
- 发出后 inflight 的 `session/prompt` 以 `{stopReason:"cancelled"}` 结束（`session.ts:309-312`）。
- **推论**：队列的「下一轮」触发点必须同时覆盖 `end_turn` 和 `cancelled`，否则用户按一次停止，
  队列就永远卡住。

### 4.4 ACP 没有的通道

| 能力 | dsh-go 走的通道 | ACP 现状 | 本仓的替代 |
|---|---|---|---|
| 插话 / 排队编辑（改插话、撤回、立即发送） | `session.prompt{mode}`、`session/updateQueue` | 无 | 客户端队列（§3.1） |
| todo / plan / goal 投影 | `projections`（`todos` / `plan` / `goal`） | 无（只有 5 种 update） | 从 `tool_call.rawInput` 反推（§3.2） |
| 斜杠命令执行 | `commands/execute` | 无 | 只能做本地动作映射 |
| 会话分叉 | `session/fork` | 无 | 客户端复制本地轨迹（已实现） |
| 会话导出 | `session.export`（ZIP） | 无 | 只能导本地缓存 |
| 后台任务 | `job/list` / `follow` / `kill` | 无 | 不适用 |
| 子代理目录 / 谱系 | `subagentCatalog` 投影 | 无 | 需插件经桥上报 |
| 文件树 / 文件上传 | `fs/listDirectory`、`fileUploads/upload` | 无（附件只有内联 image block） | 读沙箱 `workspace/`（不经协议） |
| 设置 / 权限 / 目标写操作 | `settings/mutate`、`goals/*` | 只有 `session/set_config_option`（`model` / `reasoning_effort`） | 权限档位启动期固化 |
| 会话列表 | `session/list`（全量） | 只回**已关闭 / 已持久化**会话 | 本地 `SessionStore` 索引 |
| 上下文明细 | `contextPressure` / `contextBreakdown` | 只有 `usage_update{used,size}` | 只显示占用比 |

### 4.5 由此推出的实现纪律

1. **不要把 Web API 的语义搬进 ACP 客户端**：steer、queue 编辑、projections 在 ACP 下不存在。
2. **任何「跑动中再发」的入口都必须走队列**，并保证 `end_turn` / `cancelled` / 断线重置三条
   settle 路径都能 flush。
3. **要宿主数据时先问「能不能从 tool_call 反推」**；不能就写 ohos 插件经桥上报（照
   `boot-report` / `credentials-live`），不要试图给 ACP 加方法——那要改上游。
4. **`session/list` 不能当会话索引**，索引以本地 `SessionStore` 为准。
5. 协议假设一旦变化，同一 commit 更新 `AGENTS.md` §4.2 与 `docs/SPIKE-ACP.md`。

---

## 5. 不适用清单

| 能力 | 为什么不适用 | 若坚持要做的代价 |
|---|---|---|
| 插件市场 | 安装依赖 pnpm 子进程；插件还须进 profile 的 bundle 依赖闭包 | 自建纯 JS 包管理器 + 改 dsh 路由表机制，超出「不改 dsh 源码」口径 |
| 后台任务（jobs） | 没有子进程就没有「后台命令」这一概念 | 用 worker_threads 另造一套，与 dsh 的 job 协议不兼容 |
| 手机操控 | 鸿蒙「控制其它 App」需系统级签名 / 受限 ACL | 拿不到权限，无替代 |
| 远程主机 | 对端是 `dsh web`（另一套 Web API）；且与「不连电脑」口径冲突 | 再写一套 Web API 客户端 + 改产品口径 |
| 网页版切换 | 本仓不是 WebView 壳；设备上没有 `dsh web` 端口 | 等于换产品形态 |
| 分享链接 / 回放 / 分享码 | 需自建分享服务端与账号体系，内容要出设备 | 服务端 + 合规成本，且与本地优先叙事冲突 |
| DS Bot / 社区 / 论坛 | 服务端 + 插件生态，与外壳定位无关 | 不投入 |
| 应用内更新 | 鸿蒙走 AGC 分发，无 APK 侧载等价路径 | 只能等 AGC 审核发布 |
| 桌宠 / 壁纸 / 启动画面 | Live2D 运行时 + 素材授权 | 与本仓「务实外壳」定位不符 |
| 消息反馈（好 / 有问题） | dsh-go 自己已移除 | 不做 |

---

## 6. 下一步建议（按收益 / 成本排序）

> 2026-11-12 第三轮更新：第 1、2、3、4、5、7、8 条已落地（§3.6–§3.13），第 9 条「主题色」见 §3.14。
> 余下第 6（语音输入）**被 SDK 挡住**：本机 DevEco SDK（API 26）不含 HMS `@kit.CoreSpeechKit`，
> `ets/kits` 与 `api/@hms.ai.speechRecognizer.d.ts` 都不存在，无法编译；要做得先引入 HMS Core SDK。


1. **过程折叠**：一轮正常结束后把思考 + 工具收成一行「已完成 · N 次工具调用」，停止/出错不收，
   外观里可关。—— `turn/end` 的 `reason.kind` 和 `tool_call` 计数客户端已经全有，纯 UI 改动。
2. **重新回答**：最后一条回复加 ↻，在新会话里重发最后一条用户消息。—— 与「从此处分支」复用
   同一条路径（本地轨迹 + 新 sessionId + `send`），无协议依赖。
3. **只读目标条**：输入框上方一条 goal 摘要。—— 与待办条同法：`create_goal` / `update_goal` 的
   参数随轨迹持久化，客户端重放即可，不需要协议改动。
4. **图片保存到相册**：长按图片 › 保存。—— `photoAccessHelper.showAssetsCreationDialog` 由用户在
   系统对话框里确认，即授予写入权限，不需要申请 `WRITE_IMAGEVIDEO` 这类受限权限。
5. **系统通知**：一轮完成 / 出错 / 等你确认 / 向你提问。—— `NotificationKit` 本地通知即可，
   事件源是本仓已经收到的 `session/status` 与 `session/request_permission`，成本最低且是手机独有能力。
6. **语音输入**：麦克风 → 文字填进输入框。—— HMS `@kit.CoreSpeechKit` 的 `speechRecognizer` 是
   设备端识别，只多一条 `MICROPHONE` 权限，完全不碰 dsh 协议。
7. **凭据遮挡**：已发送消息里的 Key / 令牌只显示前 8 位，点眼睛看原文。—— 纯客户端正则（照
   `dsh-client-ui-secret-mask` 的规则移植），安全向、零协议依赖。
8. **本地斜杠命令面板 + 文件 @ 引用**：`/` 只映射已有动作（新会话、切模型、停止、清排队、切项目），
   `@` 读本地 workspace 目录插路径。—— 两者都只用客户端已有能力（`FilesPanel` / `DirGrant`），
   不新增协议。

再往下一轮的 B 级项（要写 ohos 插件 + 载荷迭代，单独立项）：子代理谱系与续聊、自动化任务最小闭环、
会话内容搜索（`session-query-sqlite` 默认 `openAt: never`，且 `node:sqlite` 在 `--jitless` 下的可用性
未验证）、插件自带设置表单。

---

## 7. 取证索引

| 结论 | 位置 |
|---|---|
| ACP 方法集固定 9 个 | `packages/acp/acp/src/index.ts:379-388` |
| prompt 在跑时拒绝第二条 | `packages/acp/acp/src/session.ts:225` |
| ACP prompt 内部是 `followup`（排队到下一轮） | `packages/acp/acp/src/session.ts:275` |
| `steer` / `followup` / `inject` 的目标队列 | `packages/core/agent-loop/src/agent.ts:179-189` |
| Web API 的 `queue` / `steer` 选择 | `packages/api/session-controller/src/commands.ts:338-339` |
| 队列项编辑 / 撤回 / 改插话 | `packages/api/session-controller/src/commands.ts:430-456` |
| `tool_call` 带 `rawInput`（待办条的数据源） | `packages/acp/acp/src/updates.ts:52-62` |
| `todo_write` 是整表替换 | `packages/todo/tool-todo/src/index.ts` 头注释 |
| `usage_update` 只有 `{used,size}` | `packages/acp/acp/src/updates.ts` 的 `usageUpdate`、`model/AcpProtocol.ets:17` |
| `session-query-sqlite` 默认关闭搜索 | `packages/bundle/base/cordis.patch.yml:157-163` |
| `goal` / `tool-goal` / `tool-todo` 在 base 已挂载 | `packages/bundle/base/cordis.patch.yml:323,433,440` |
| `jobs` / `tool-jobs` 与子进程的关系 | `packages/bundle/base/cordis.patch.yml:96,289`；`host/patches/ohos.patch.yml` |
| `schedule` / `tool-schedule` 只在 sdk-app / web-app | `packages/bundle/sdk-app/cordis.patch.yml:54-62`；`packages/bundle/acp-app/cordis.patch.yml` |
| schedule 投递依赖 `sessionController`（ACP 无） | `packages/schedule/schedule/src/index.ts:133` |
| 插件市场被平台补丁禁用 | `host/patches/ohos.patch.yml`（`plugin-manager` / `tool-plugin-manager`） |
| 待办条 / 队列 / 引用 / 搜索的本仓实现 | `entry/src/main/ets/model/TodoModel.ets`、`pages/Index.ets`、`view/ChatView.ets`、`view/SessionRail.ets` |
| 相册写入 API 与权限模型 | SDK `@ohos.file.photoAccessHelper.d.ts` 的 `showAssetsCreationDialog` |
| 语音识别 API | HMS SDK `@kit.CoreSpeechKit` → `@hms.ai.speechRecognizer.d.ts` |
| dsh-go 的协议与能力面 | `/tmp/dsh-go-ref/packages/dsh_client/lib/src/{carrier,session_api,transcript}.dart`、`docs/official-parity.md` |
