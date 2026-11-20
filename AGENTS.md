# AGENTS.md — dshharmony 多智能体协作公约与统一语言

> 本文件面向在本仓库工作的所有 AI 代理（deveco code、workbuddy、GitHub Copilot 等）与人类协作者。
> 它是**统一语言（ubiquitous language）与口径的唯一权威**：与 docs/、历史对话或任何 agent 的
> 会话记忆冲突时，以本文件与当前代码为准；口径变更必须同一 commit 修订本文件。
> 最后对齐：2026-11-20。

## 1. 项目身份（一句话口径）

**本仓库是 dsh 的鸿蒙外壳，dsh 是这个仓库唯一的大脑。**

- 仓库：<https://github.com/QtePP/deepseek-harness-harmony>（MIT）
- 形态：原生 ArkUI 客户端 + **同一应用进程内**的 dsh 运行时；不套壳浏览器、不投屏、不连电脑。
- 覆盖形态：`deviceTypes` = phone / tablet / **2in1**（鸿蒙电脑），840vp 布局断点切换单/双栏。
- 目标平台：API 26 / HarmonyOS 7.0.0，arm64-v8a，minAPI 26（装不上 HarmonyOS 6.x）。
- 类比：VS Code 与其进程内扩展引擎；或 Electron 之于 Chromium+Node。

## 2. 统一语言（术语表）

| 术语 | 定义 | 锚点 |
|---|---|---|
| **dsh** | 唯一的「大脑」：npm 包 `@deepseek-ai/dsh`（**0.2.2-rc.5**，依赖树 **676 包**，npm install 实测 added 计数）。会话、工具调用、插件、模型适配、持久化全部来自它；本仓库不含任何 AI 能力 | 载荷内 node_modules |
| **Harness / 外壳** | 本仓库自身：ArkUI 界面 + 宿主适配层 | 本仓库 |
| **Payload / 载荷** | `dsh-payload.zip`（≈240MB 十进制 / 227 MiB）：dsh 及其依赖打进 HAP rawfile，首启解包到沙箱 | `scripts/assemble-payload.mjs`、`entry/.../host/Payload.ets` |
| **Bridge / 桥** | 127.0.0.1:4517 回环 TCP，承载 newline-delimited JSON-RPC 2.0；bootstrap 把 socket 伪装成 dsh 的 stdio。**单客户端**：新连接 `replacing previous client` 顶掉旧连接 | `host/bootstrap.cjs`、`entry/.../model/DshClient.ets` |
| **Host 层** | 把 Node 拉进鸿蒙进程的适配层：NAPI dlopen `libnode.so` + `node::Start` | `entry/.../host/NodeHost.ets`、`@fellow99/node-bridge` |
| **Profile SDK / ACP** | dsh 两条程序接口，都是 stdio 上的换行 JSON-RPC、流均可注入。**SDK**：5 个方法，出厂默认、真机验收过，但**是降级路径**（不挂 ohos 插件）。**ACP**：9 个方法 + 流式 update + 服务端发起审批，进程内可跑（spike 已证）、2026-10 起真机闭环；**首次启动会问一次用哪个**（`AppConfig.profilePrompted`，答案决定当次启动，不用重启）。出局的只是「宿主 spawn dsh」，不是 ACP 本身 | `host/bootstrap.cjs`、`docs/SPIKE-ACP.md` |
| **ohos profile / 纯 JS 搜索** | 自定义 profile（`host/profile-ohos/profiles/ohos`，随载荷分发）：bundle `dependencies` 声明插件（路由表按 bundle 依赖闭包构建，漏声明 = 永不 mount）+ bundle patch 顶层 `- insert:` 挂 `@ohos/dsh-tool-fs-search-js`（纯 JS glob/grep，模型工具名不变）并禁 stock `tool-fs-search`；bootstrap 按内容哈希戳幂等安装到 `$DSH_HOME/profiles/ohos` 并把 `acp` 重映射为 `ohos`（缺模板回落 stock acp）。ACP 方法集不变 | `host/bootstrap.cjs`、`docs/GAP-ANALYSIS.md` §7.1 |
| **Session / 会话** | 客户端生成 UUID 作 id；服务端持久日志 `session.v4.jsonl.zstd`（按初始化 cwd 的 slug 存放，id 全局可查）；本地 `SessionStore` 只存 UI 索引与消息缓存（最近 200 条） | `entry/.../model/ChatModel.ets` |
| **Project / 项目** | 对话分类：命名桶 + 独立 workspace；`default` 为默认项目，兼容全部历史会话与旧路径 | `entry/.../model/ProjectModel.ets` |
| **Workspace** | 默认项目 = `filesDir/workspace`（initialize 的 cwd，向后兼容）；其他项目 = `filesDir/workspaces/<projectId>` | `ProjectStore.workspaceDir()` |
| **Plugin patch / 补丁** | 两份 YAML 经双 `--patch` 传入：平台补丁 `ohos.patch.yml` + 用户补丁 `user.patch.yml`（Settings 能力开关生成；后者后传，覆盖前者同名行） | `host/patches/`、`entry/.../common/PluginConfig.ets` |
| **jitless / fetch-shim** | 无 JIT ACL ⇒ `--jitless` ⇒ 无 WebAssembly ⇒ 内置 undici 失效 ⇒ 纯 JS fetch 垫片接管（`install()` 用 defineProperty 把 fetch/Headers/Response/Request/FormData 全家族换成 shim——dsh 启动期会读全局 Headers（account-platform），只换 fetch 会触发惰性物化 WASM undici 而崩溃） | `host/fetch-shim.cjs`、`host/undici-esm.mjs` |
| **link-fallback** | 沙箱禁 hardlink（EACCES）⇒ `copyFile(COPYFILE_EXCL)` 降级，装配期注入 | `bootstrap.cjs` `installLinkFallback()` |
| **840vp 断点** | ≥840vp：会话栏 + 对话双栏；<840vp：单栏，rail 收进 sheet | `entry/.../pages/Index.ets` |
| **dsh-home** | 沙箱内运行时主目录：`bridge.log`、`bridge-status.json`、`sessions/`、`storages/` 等 | `NodeHost.ets` |
| **ptc-runtime-vm / run_code** | in-process PTC 运行时（`@ohos/dsh-ptc-runtime-vm`，worker_threads + `node:vm`，随载荷分发）：**`tools.mode` 在 0.2.2 已被删除**（schema 变 `z.never()`，写它直接启动失败）；改由 `tool-executor-native` 行承担，base 默认挂载、`tool-executor-ptc` 默认禁用（2026-11-15 升级实测）。**native 下模型工具表 26 个直出工具（dsh 自带 25 个 —— glob/grep/read/write/web_search/web_fetch/edit/skill/subagent/todo_write 等 —— 加上我们插的 `git`），`run_code` 不在其中**——dsh-tools 只在非 native 模式把 run_code 注入可见表（`dsh-tools/lib/index.js` view()：`mode !== "native"` 才 `visible.set(RUN_CODE_NAME)`）；`mode: ptc` 则反过来：wire 上**只有 run_code**（wireSchemas 过滤掉其余 schema），其余工具只能经程序内 `tools.*` SDK。boot-report 的 `tools(N)` 用 `ctx.tools.schemas()`（注册表视图），ptc 模式下计 27（全部 + run_code），native 下计 26（含 `git`；0.2.2 时为 25，0.2.1 时是 21）。ptc-runtime-vm 仍挂载（提供 `ctx.ptcRuntime`），未来 preset 可经 `dsh-agent-tool-presentation` 行（`tool-presentation`，preset 级 `presentAs`）opt-in PTC；worker 不可用时优雅 `worker-exit` | `host/profile-ohos/.../@ohos/dsh-ptc-runtime-vm`、`.build/payload/node_modules/@deepseek-ai/dsh-tools/lib/index.js` |
| **credentials-live / 密钥热更新** | `@ohos/dsh-credentials-live`（随载荷分发，ohos profile 专属）：目录级 fs.watch + 1.5s 轮询 `<dsh-home>/.api-key`，变化经 `credentials.set()/unset()` 热发布。dsh 启动期冻结 env 快照（`loadLayeredEnv` 拷 `process.env`），运行中改 env 永远无效——这是唯一热路径；Settings 保存密钥 ~2s 生效无需重启（ACP 路径；SDK profile 无此插件，重启生效） | `host/profile-ohos/.../@ohos/dsh-credentials-live` |
| **time-context / 时间上下文** | `@deepseek-ai/dsh-time-context`（dsh 自带、随载荷分发）：把当前时间作为 durable 注入写进请求历史（默认 10 分钟一次），模型据此知道"今天"。**它不是工具**，桌面/SDK profile 由 `dsh-sdk-app` 挂载，`dsh-acp-app` 不含 → ohos bundle 自己 insert 一行；缺它时模型对相对日期的推理全是猜 | `@ohos/dsh-bundle-ohos/cordis.patch.yml` |
| **tool-git / 纯 JS 仓库** | `@ohos/dsh-tool-git`（ohos profile 专属）：一个工具的六个动作 `clone` / `snapshot` / `pull` / `log` / `diff` / `status`，用 isomorphic-git（纯 JS，packfile 走 pako，**零 WASM**）经 HTTPS 把仓库落到 `repos/<slug>`，之后交给 `glob`/`grep`/`read` 分析——**仓库在手机上 ≠ 推理在手机上**，推理仍在云端。**HTTP 客户端是自己写的**（`http.js`：`node:https` 流式 + 字节计数 + 中途 abort），不用 `isomorphic-git/http/web`：后者经全局 fetch（我们的 shim）会全量缓冲，且进度只报**对象数**不是字节。两条实测硬约束：内存 ≈ 100MB + 11 × pack（92MB 仓峰值 1.1GB）⇒ `maxPackMb` 默认 50、超限中途 abort；shallow 仓**不能 pull**（js-git 抛 `TypeError`）⇒ `snapshot` 标只读、`pull` 按名字拒绝。包从**载荷**的 node_modules 加载（`DSH_PAYLOAD_ROOT`），因为 profile 树在 dsh-home 下解析不到它 | `host/profile-ohos/.../@ohos/dsh-tool-git` |
| **boot-report / 能力自检** | `@ohos/dsh-boot-report`（ohos profile 专属）：启动 5s 后把已注册工具名与 web search/fetch 就绪写进 `bridge.log`。就绪由 provider 注册表推导（该 dsh **没有** `searchReady()/fetchReady()`）：配置 id 优先 → 按 `dsh-web` 的**路由偏好**（DeepSeek 路由 → `deepseek-official`，其它 → `deepseek-search-api`）→ 最后才是「唯一可用」。0.2.2-rc.5 起基础组合不再钉 `searchProvider`，所以**两个 provider 可用不再算歧义**，按偏好判定即可。`web` 用 `ctx.get('web')` 而非 inject 读取，seam 整体缺失时也要报出来 | `host/profile-ohos/.../@ohos/dsh-boot-report` |

### 2.1 英文口径（对外文案用，勿自创）

一句话定位：**A native shell for running DeepSeek Harness locally on HarmonyOS devices.**
（`oh-package.json5` 的 `description` 是另一套同义表述：`native ArkUI client with an in-process Node runtime`。）

展开句：*No WebView, no screen mirroring, no tethering to a computer — the whole runtime lives inside the app process.*

易错译法（每条都是口径错误，不是风格问题）：

- ❌ `native port of dsh` / `dsh rewritten for HarmonyOS` → dsh 未被移植或改写，本仓库只是外壳
- ❌ `spawns a Node subprocess` → 禁 fork/exec，Node 同进程内嵌
- ❌ `offline` → 它要联网调模型 API；本意是「不连电脑」= standalone on-device / no tethering
- ✅ 不套壳浏览器 = `not a WebView wrapper`；不投屏 = `no screen mirroring`

## 3. 架构口径（四层关系）

1. **依赖**：AI 能力 100% 来自 npm dsh；`assemble-payload.mjs` 装配为载荷随 HAP 分发。
2. **运行**：同进程内嵌，不是子进程。出局的只是「宿主 spawn dsh」这一形态（禁 fork/exec）；
   **ACP 服务器本身进程内可跑**（2026-10-26 spike 实测：PassThrough 劫持 stdio + `runCli()`，
   零 spawn，`docs/SPIKE-ACP.md`）。出厂默认仍是 SDK，但**首启引导**会让用户在第一次启动时选一次
   （ACP 有流式/审批/纯 JS 搜索/密钥热更新；SDK 是兼容模式）；答案落 `preferences` 的
   `profile` + `profile_prompted`，只问一次，之后在设置里切。
3. **集成点**：全部集中在 `host/` 适配层（bootstrap / fetch-shim / undici 别名 / 装配期补丁 /
   `profile-ohos` 自定义 profile 模板），不改 dsh 源码。
4. **版本耦合**：协议契约是实测所得（2026-10-25），写死在 `DshClient.ets`；dsh 升级若改协议，此处假设即失效。

## 4. 协议口径（以 `model/Protocol.ets` + `DshClient.ets` 为准）

**两条 profile 并存**：`DSH_PROFILE=sdk`（出厂默认，真机验收过）/ `acp`（首启引导推荐，真机闭环）。
桥本身与 profile 无关——两者都是 newline-delimited JSON-RPC over stdio，差异在方法集。

### 4.1 SDK profile（默认路径）

客户端 → 服务端 **5 个请求**：

| 方法 | 语义 | 超时 |
|---|---|---|
| `initialize` | 固定 cwd/provider/model；**必须等到它的响应后才能发 prompt** | 180s |
| `session/prompt` | 入队回执（不是答案）；未知 id 懒创建 agent | 30s |
| `session/resume` | 从 .zstd 日志恢复服务端上下文；日志按 id 全局查找 | 30s |
| `session/working-directory/set` | 换会话 cwd；目录必须已存在；持久化进日志、resume 后依然生效 | 30s |
| `shutdown` | 排空退出 | 10s |

服务端 → 客户端 **4 个通知**：`session.event`（全运行时会话，客户端按 sessionId 过滤）、
`session.status`（running/idle）、`subagent.started` / `subagent.finished`。

实测契约（勿凭直觉改）：

- 事件信封 `{type, seq, time, data}`，**字段在 `data` 下**（读扁平结构 = 永远空列表）。
- 空 `reasoning` 块很常见，渲染必须跳过。
- 会话打开策略（`Index.ensureSessionOpen`）：先 `resume`（"not found" 静默落新建路径）；
  非默认项目在首次 prompt 前先 `working-directory/set` 指向项目 workspace。

### 4.2 ACP profile（`DSH_PROFILE=acp`，首启引导推荐；设置里切后需重启）

客户端 → 服务端：

| 方法 | 语义 |
|---|---|
| `initialize` | `{protocolVersion:1, clientCapabilities}`；**可重复调用**（重连后再发一次不会报错） |
| `session/new` | `{cwd, mcpServers}` → **服务端生成 sessionId** + `configOptions` |
| `session/list` | 只返回**已关闭/已持久化**的会话；活跃会话不在其中 |
| `session/resume` | `{sessionId, cwd, mcpServers}`；**对活跃会话报 `session is already active`** |
| `session/close` | 关闭后该会话才进入 `session/list`，之后可 resume |
| `session/prompt` | `{sessionId, prompt:[{type:'text',text}]}` → `{stopReason}`（`end_turn` / `cancelled`） |
| `session/set_config_option` | `{sessionId, configId, value}` → 返回**更新后的 configOptions**。`configId` 取 `model` / `reasoning_effort` |
| `session/cancel` | **通知，不是请求**（无 `id`，无响应）。发出后当前轮的 `session/prompt` 响应变为 `{stopReason:"cancelled"}` |

服务端 → 客户端：通知 `session/update`（`agent_message_chunk` / `agent_thought_chunk` /
`tool_call` / `tool_call_update` / `usage_update`），以及**服务端发起的请求**
`session/request_permission`（**snake_case，不是 ACP 规范的 `requestPermission`**）。

ACP 实测契约（勿凭直觉改）：

- 审批选项固定两键：`allow-once` / `reject-once`，应答
  `{outcome:{outcome:'selected', optionId:'allow-once'}}`；答错/空应答 → 工具 `failed`（fail-closed）。
- **方法名全部是 snake_case，不要按 ACP 规范猜 camelCase**：`session/setConfigOption`、
  `session/set_model`、`session/set_mode` 实测均 `Method not found`；`session/cancel` 若作为
  **请求**（带 id）发送同样是 `Method not found`，它是通知。
- `session/set_config_option` 的 `value` 对 `model` 是**JSON 数组字符串**
  （`'["deepseek-official","deepseek-v4-pro"]'`），不是对象；传错会静默不改。
- **set_config_option 后选项集会收缩**（真机实测）：切到 `deepseek-flash` 后
  `deepseek-v4-flash` 从选项中消失，切回被 `-32602 unknown model option` 拒绝。响应里的
  `configOptions` 是**新的权威列表**，选择器不得缓存旧列表；默认模型一旦切走，该会话无法
  切回（唯一途径是新建会话）；`-32602` 是「选项已不可用」，不是传输错误。
- 帧必须带 `"jsonrpc":"2.0"`：缺失时预校验直接回 `-32600 Invalid request`（`id:null`，
  data 回显原帧），到不了方法分发。
- **断线重连**：桥保持流不关闭，重连后 `initialize` 幂等，**直接对旧 sessionId 发 prompt 即可**；
  不要 resume（会撞 `already active`）。
- **断线时正在跑的那一轮**：服务端继续跑，且 `session/update` 会投给新连接；但原 `session/prompt`
  的响应**永久丢失**，且 update 帧里没有 turn/message id，无法关联——**客户端无从判断它何时结束**。
  因此重连应走「重置语义」：`initialize` → `session/close`（掐掉孤儿轮）→ `session/resume` →
  把那条消息标为「已中断」让用户决定是否重发。细节见 `docs/SPIKE-ACP.md` §11。
- `configOptions` 是模型列表的权威来源，客户端不要硬编码模型。
- **权限三档（dsh 具名预设，沙箱+审批捆绑）**：`DSH_PERMISSION_MODE` = `read-only` /
  `workspace-write`（默认）/ `danger-full-access`，审批策略 `=== 'danger-full-access' ?
  'never' : 'ask'`。read-only：裸写先被沙箱拒（无审批请求），agent 带
  `sandbox_permissions`+`justification` 重试才触发审批；workspace-write：工作区内直写、
  越区升级才问；danger-full-access：全放行零审批（三档均真机闭环）。
- **档位随会话创建固化**：会话创建即写 `permission/preset`、`sandbox/mode`、
  `approval/policy`；切档需重启 App（env 启动期）且只影响新会话。
- **完全不答审批 → turn 无限挂起**（failopen 探针实测 10+ 分钟无决定、文件不落盘），
  非工具 failed；服务端无自动放行。
- **跑动中不能发第二条 prompt**：`session/prompt` 在 inflight 时被服务端拒绝
  （`a prompt is already in flight for this session`，`packages/acp/acp/src/session.ts`），
  ACP 没有 steering 通道 ⇒ **「插话」在 ACP 下不可得**，客户端只能排队、回合结束
  （含 `session/cancel` 触发的 `cancelled`）后续发。别按 dsh-go 的 Web API 语义实现插话。
- 该 profile 下 `bash` 工具存在但必然失败（无 exec），属平台限制。

## 5. 平台硬约束（六条，各有对策）

| 约束 | 对策 |
|---|---|
| 禁 fork/exec | 同进程 Node；无 `git`/`rg` 等二进制工具面 |
| `node::Start` 每进程一次 | 崩溃即终态，UI 明示重启应用 |
| jitless ⇒ 无 WebAssembly | `fetch-shim.cjs` + undici ESM 别名 |
| 原生 `.node` 模块不可用 | 装配 `--ignore-scripts`，koffi 等不进载荷 |
| 文件系统禁 hardlink | `installLinkFallback`（copyFile COPYFILE_EXCL） |
| 零受限 ACL 安装 | 默认 `--jitless`，无 JIT 权限也能跑 |

## 6. 环境与版本口径（易混点，统一说法）

- **内嵌运行时 Node = v24.2.0**（libnode.so，设备端 `bridge-status.json` 的 `node` 字段）。
- **本地装配/测试 Node = PATH 上的 `node`**（这台机器是 homebrew 的 **v25.9.0**；DevEco 自带
  `…/tools/node/bin/node` = **v24.14.1**，跑「与设备同大版本」的验证时用它）。**设备内嵌 v24.2.0**。
  三个数字并存不是笔误；`scripts/*.sh` 没有钉 PATH，用的是调用者环境里的 node。
- dsh **0.2.2-rc.5**（钉在 `scripts/assemble-payload.mjs` 的 `PINNED_DSH_VERSION`，**默认不再解析 `latest`**）；载荷 zip ≈**240MB**（剪掉 332MB 外国平台包后）；HAP ≈352MB（unsigned）；桥端口 4517。
- `hdc` 不在 PATH：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`。
- **设备身份**：当前在用的是**平板** —— `const.product.name` = **HUAWEI MatePad Mini 悦读版**、
  `const.product.model` = **MLR-AL00**、`const.product.devicetype` = **tablet**、API 26、2560×1600。
  本文件个别旧记录把它写成「手机」，是笔误（当时没跑 `param get const.product.devicetype`）；
  **凡是「手机」与这台设备同时出现的地方，以本条为准**。含义：它走 ≥840vp 的双栏布局，
  单栏（手机）形态不在它身上验。另：`wm size` 在该设备 shell 里不可用（`inaccessible or not found`），
  分辨率从 `param`/`hidumper` 取。
- **序列号不进本仓库**（§8.5）：需要用序列号定位设备时记在本地记忆或命令行现场查
  （`hdc list targets`），本文件只按「型号 + 形态」识别设备。
- 设备侧文件路径两种视角同目录：hdc shell `/data/app/el2/100/base/<bundle>/haps/entry/files/…`
  ⇄ App 内 `/data/storage/el2/base/haps/entry/files/…`（`context.filesDir`）。

## 7. 当前状态（2026-11-20）

**验收记录与踩坑日志搬到了 `docs/STATUS.md`**——那里按时间倒序逐条记「哪台设备、哪次构建、
验了什么、代价多大、犯了什么错」。本文件只管**口径**与**现在的结论**。新增验收记录写进
`docs/STATUS.md`，并在这里的摘要行补一句；两处同一 commit。

### 7.1 现在真机跑通的东西

| 域 | 状态 |
|---|---|
| 运行时 | 同进程 Node **v24.2.0** + dsh **0.2.2-rc.5** + `ohos` profile：**六个自研插件**，`tools(26)` |
| 双 profile | SDK 5 方法（兼容路径）/ ACP 9 方法（首启引导推荐）；首启问一次，答案决定当次启动 |
| 对话体验 | 流式气泡 + 思考折叠 + 工具轨迹、插话队列、待办条 / 目标条、上下文小环、重新回答、完成摘要 |
| 会话管理 | 列表 / 标题与内容搜索、置顶、归档、多选批量归档、未读标记、每轮用量账本、详情页、导出 |
| 文件与产物 | 预览（网页 / 图片 / 文本）、`@` 引用、图片存相册、分享卡、导出 Markdown |
| 输入与外观 | 语音输入 / 朗读（引擎缺离线语音包，降级已验证）、六套主题色、外观三档、对话字号四档 |
| 沙箱与审批 | 四层沙箱 + 权限三档（只读 / 平衡 / 宽松），三档均真机闭环 |
| 联网与仓库 | `web_search` 走服务端 Messages 搜索；`git` 纯 JS clone + `glob`/`read` 分析（含超时重试） |
| 稳定性 | 断线重连 120s 退避实测夺回客户端槽位；崩溃即终态（`node::Start` 每进程一次） |

### 7.2 没成 / 卡在平台上的

- **系统通知不出卡片**：hilog 给的是 `invalid creatorUserId: 100`（当前用户 101），公开 API 没有
  这个字段可覆盖——设备的用户态问题。换单用户设备、并补 `notificationSlotType` 再验。
- **语音引擎起不来**（`1002200001`）：缺离线中文语音包；降级与复位入口已验证（见 STATUS）。
- **自动化任务（schedule）不可行**：缺宿主 `session-controller` 服务（32 个 peer 依赖，含整套
  HTTP 面），不是补个插件能补的。
- **ACP 无 steering**：跑动中不能插话，只能排队或 `cancel`（§4.2）。
- **首次运行的 `.credentials.yaml` 是 644**：只能在 Node 起来后收紧，靠下一次启动修好。
  其余已知边界见本节末「已知边界」。

签名口径（开源卫生）：

- 仓库内 `build-profile.json5` 的 `signingConfigs` 为空；真实签名在本地
  `build-profile.signing.json5`（gitignored）。
- `scripts/deploy.sh` 自动处理：检出备份或 `devecocli signature generate` → 构建 → 结束时
  还原无签名版本（trap 兜底；新生成的材料自动存回备份）。
- 调试 Profile 用带 ACL 的试用版 `~/key_taharness/taharnessDebug.p7b`（本地
  `build-profile.signing.json5` 指向它，2026-10-31 起）：老自动签名 Profile 的 `acls`
  为空，而 module.json5 自 03a252d 起声明 `FILE_ACCESS_PERSIST`，空 ACL 的包装不上；
  试用 Profile 与老 .p12 同证书（指纹一致，hvigor 签名链不变）、含该 ACL、绑手机/平板 UDID。
  **2026-11-16 更新**：这条老坑在当前 CLI 上**已不成立**——新手机（SGT-AL10）不在旧 profile 的
  3 个 UDID 里，装机报 `code:9568423 device is unauthorized`；跑 `devecocli signature generate --force`
  后自动生成的新 profile **含 4 个 UDID 且带 `FILE_ACCESS_PERSIST` ACL**（CLI 自己打印
  「You are applying for restricted ACL permissions: FILE_ACCESS_PERSIST」），装上了。
  **所以换新设备时不必再手工找 AGC 加 UDID，先跑这条命令。**
  注意它会把签名内联写进受版本控制的 `build-profile.json5`——装完必须 `git checkout build-profile.json5`。
- 发布签名走 `scripts/build-release.sh`（三步，签名在 hvigor 之外）：`--build-mode release
  --assemble-type assembleApp` 一次构建出未签名 HAP 与 .app → DevEco SDK 的
  `hap-sign-tool sign-app` 以明文密码给 HAP 本地签名（签名链自检用，见下）→ `hap-sign-tool
  sign-app -inForm zip` 给 .app **容器整体**签名（= hvigor SignApp 任务的 CLI 等价），
  `verify-app` 对独立 HAP 与 .app 容器各校验一次。绕开 hvigor SignHap/SignApp 的原因：
  它们只收 DevEco 加密密码（≥32 字符 `000000...` 密文），明文报 `00303116`。材料八字段
  （含明文密码）在 `build-profile.release.json5`（gitignored）。
- **AGC 提交（含测试轨道）只收 App Pack（.app），文件选择器过滤 .hap；且校验的是 .app
  容器签名**——2026-10-31 实测：容器未签名的 .app 被测试轨道 991「非法软件包/未检测」
  拒收，与包内 HAP 是否签名无关。**包内 HAP 本来就该是未签名的**（hvigor PackageApp
  源码实证：所有 `getModuleTargetOutputFileName` 调用都传 signed=false；SignApp 只签
  容器；AGC 分发时再拆包重签——官方 FAQ「其中的HAP包没有签名」说的就是这个设计）。
  上传 `build/outputs/default/dshharmony-default-signed.app`（容器已签名）。
- **发布 Profile 签的 HAP 平台禁止 hdc 直装**（2026-10-31 真机实测：`code:9568322
  signature verification failed due to not trusted app source`；官方 FAQ「手动签名失败的
  常见问题」场景六——发布证书签名的应用不能通过 hdc 安装运行）。发布包只走 AGC 分发；
  真机装机一律走 `scripts/deploy.sh` 调试签名路径；独立签名 HAP 仅作签名链自检保留。
- 手动命令行构建的合并/还原配方见 `docs/BUILD.md`。

已知边界（诚实清单）：无 token 级流式；无二进制工具（`rg`/`bash` 仍无，`git` 已由纯 JS 插件替代）；密钥若随 rawfile 分发
仅适合自用/内测（优先级：设置页 > `secrets.json`）；**设备端不做图片降采样**——请求图按原尺寸上传
（`sharp` 桩只能直通），由服务端投影到视觉网格，仅影响上传体积，不影响模型看到的内容。

**密钥不得走 env**：`@fellow99/node-bridge` 在启动时把子进程环境 dump 进 `node.log`
（`[node_bridge] env DEEPSEEK_API_KEY=…`）。因此 `NodeHost` 把 key 写成 `dsh-home/.api-key`（0600），
通过 `DSH_KEY_FILE` 传路径，由 `bootstrap.cjs` 在桥打完日志之后赋给 `process.env.DEEPSEEK_API_KEY`。
新增任何敏感变量时沿用这个模式，别直接放进 `env`。

## 8. Agent 工作流约定

1. **顺序**：改 `.ets` → ArkTS 静态检查 `devecocli check arkts [files...]`（**需 CLI ≥ 1.3.10**，
   一次传全部改动文件；旧版 1.3.0/1.3.4 没有这个子命令，只能退到 `devecocli check lint`）→
   `devecocli build` → `devecocli run --skip-build --device <serial>`。构建成功前任务不算完成。
2. **载荷迭代**（仅当 `host/` 或依赖变化才需要）：`node scripts/assemble-payload.mjs`
   （`--skip-install` 可复用 staging）→ 再 build。
3. **部署**：`bash scripts/deploy.sh [serial]`（查设备 → 登录 → 签名缺失时生成 → 构建 → 装+启动，
   结束自动还原签名口径）。CLI 解析优先级：`DEVECO_CLI` 环境变量 > 仓库内 `.deveco-cli-path`
   钉死的绝对路径（gitignored，本机专用）> PATH。**本机装有多份 devecocli，PATH 顺序会漂**，
   需要时 `echo /path/to/devecocli > .deveco-cli-path` 钉死一份。
4. **验证**：`devecocli log`（支持 `--crash` / `--level` / `--bundle-name` / `--tail` / `--follow`）；
   应用内 设置 → 诊断；无头 UI 断言用 `devecocli ui layout|screenshot|click|swipe|text`
   （封装好过手拼 `hdc shell uitest dumpLayout`，后者参数名跨版本变过）。
   本地三段验证（装机前先过一遍，全绿再部署）。**一条命令即可全跑**：
   `bash scripts/test.sh`（= payload 单测 + ArkTS 检查 + LocalUnit + 设备端 ohosTest；
   子集用 `unit` / `arkts` / `local` / `device` / `ui "<自然语言计划>"`）。
   **同一个 `unit` 也在 CI 上跑**：`.github/workflows/payload.yml` 在 `host/**` / `scripts/**`
   变更时触发，`assemble-payload.mjs --skip-pack` 装好钉死的 dsh 后跑五个插件套件 + 一次
   `--dump-config` 行 id 校验。它**不需要 DevEco、不需要设备、不需要签名**——只证明「我们写的
   那部分在钉死的 dsh 上仍然通过」。载荷 zip 与 HAP 都是**构建产物，不进 git**。
   **两个坑写死在脚本里，手工跑时同样要小心**：
   (1) `hvigorw test` 断言失败时**仍 exit 0**，失败只表现为日志里的
   `ERROR: Error in <用例>` —— 不能靠退出码判断；
   (2) 恢复 `build-profile.json5` **只能用 `git checkout`**，用文件备份会把已注入的
   storePassword/keyPassword 写回受版本控制的文件。
   以下是脚本内部各段的原始命令：
   - **单测**：必须在**载荷树内**跑——插件 `index.js` 依赖 `@deepseek-ai/schemastery` 等包，
     只有载荷根能解析，在仓库源目录直接跑会 `ERR_MODULE_NOT_FOUND`：
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-tool-fs-search-js && node --test test/*.test.mjs`（38/38）；
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-ptc-runtime-vm && node --test test/*.test.mjs`（22/22，
     加 `--jitless` 再跑一遍证明无 WASM 路径）；
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-credentials-live && node --test test/*.test.mjs`（8/8）；
    - **配置层**：`DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos --patch .build/payload/patches/ohos.patch.yml --dump-config`
      → `tool-bash`/`tool-pwsh`/`tool-jobs`/`tool-fs-search`/`ptc-runtime` 均为 `disabled: true`；
      `tools` 行 `config.mode: native`；末尾有 `- id: tool-fs-search-ohos`、`- id: ptc-runtime-vm`、
      `- id: credentials-live-ohos`、`- id: time-context` 与 `- id: boot-report-ohos`。
     **`--profile ohos` 读的是 `$DSH_HOME/profiles/ohos`（不自动安装）**：模板变更后必须先
     `rm -rf .build/ohos-e2e/profiles/ohos && cp -R .build/payload/profile-ohos/profiles/ohos .build/ohos-e2e/profiles/ohos`
     再跑 dump，否则读到旧模板出现假阴性。
     同一条命令对 `sdk` profile 会报 `patch: entry "skill-office" not found`——那是**预期噪音**：
     `skill-office` 只存在于 sdk 树，平台补丁两 profile 共用，不要为消警告删该行。
   - **启动冒烟**：`printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}\n' | DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos`
     → 返回 `agentInfo.name = deepseek-harness-acp`。注意用管道喂帧；用 `spawn` 脚本发帧在本机偶发
     零帧（时序问题，不是启动失败）。
5. **安全红线**：`secrets.json`、签名材料、设备序列号不进公开仓库；公开文档不出现密钥；
   发现泄漏立即提醒轮换。
6. **口径同步**：改了协议/架构/流程，必须同一 commit 更新本文件与相关 docs/。
7. **Token 预算**：**无上限**。仓库所有者正在对 agent 做极限测试——不要吝惜 Token，随意花费：
   详细探索、多轮验证、完整取证永远优先于省 Token；宁可多花，不可省略。

## 9. 文档地图

| 文件 | 内容 |
|---|---|
| `docs/STATUS.md` | **真机验收与状态日志**（`AGENTS.md` §7 的证据侧）：时间倒序逐条记哪台设备、哪次构建、验了什么、代价多大、踩了什么坑；新增验收记录写这里，§7 只留摘要与口径 |
| `docs/API-AND-SEQUENCE.md` | **接口清单 + 时序图**：能力域总览（42 文件 / 15.4k 行）、ACP 9 方法与 SDK 5 方法签名、内部模块导出符号表、6 张 mermaid 时序图（冷启动 / 一轮对话 / 审批 / 断线重连 / LAN 直连 / 语音降级）、文档缺口清单 |
| `docs/ARCHITECTURE.md` | **架构权威文本**（2026-11-20 重写）：进程剖面、运行时五条硬事实、宿主适配层三段（含十个垫片与三份 YAML）、SDK/ACP 双 profile 对照与契约摘要、事件渲染映射、沙箱四层、平台约束十条、已知边界。排版版 `docs/on-device-architecture.html`。逐行走读看 `BOOT.md`，协议矩阵看 `SPIKE-ACP.md` |
| `docs/BREAKTHROUGHS.md` | **突破清单 + 代价**：四条判据（平台说不行/无方案可抄/真机闭环/用户可感知）筛出的六件平台级突破——同进程 Node、进程内 ACP、jitless fetch、自定义 profile、三条降级链、可观测性，每件带证据与代价；另含协议契约、方法论、以及诚实的「什么不算突破」。排版版 `docs/breakthroughs.html`（与 `docs/on-device-architecture.html` 同一套设计，后者讲「现在长什么样」，前者讲「哪些是硬啃下来的」） |
| `docs/BOOT.md` | **启动链路走读**：点开图标 → EntryAbility → NodeHost.boot → dlopen/node::Start → bootstrap.cjs 十个垫片 → runCli/profile 挂载；含「哪些脚本在什么时候跑」的分类表与 6 个文件的阅读顺序 |
| `docs/BUILD.md` | 构建、签名、装机、排障（含受限环境坑） |
| `docs/ROADMAP.md` | 路线图：ACP 切换评估（流式/审批/取消）等 |
| `docs/PLUGIN-MIGRATION.md` | 客户端插件迁移分级（P0/P1/P2/不迁） |
| `docs/INTEROP-PRODUCT.md` | **互联的产品面**：三条真通道各自创造什么需求与心智（LAN 直连=「递手机」的数字化、中继=实时版分享链接、剪贴板=零门槛兜底）、四条暂缓通道及原因、必须守住的四条产品红线（不装账号体系/默认不监听/收到的内容不自动进对话/说清对方能看到什么） |
| `docs/INTEROP-APIS.md` | **与其他应用/用户通信的能力盘点**：已用的 6 条（TCP 桥/HTTP/ShareKit/通知/Want/Web）+ 可加的 15 条（WebSocket、局域网 TCP、分布式数据对象、BLE/SPP、星闪、RPC、DataShare…）+ 4 条权限卡死（短信/设备发现/通知控制器/悬浮窗）+ 三条落地路线与成本 |
| `docs/DSH-GO-PARITY-V2.md` | **现行**对齐矩阵：以 dsh-go **v1.1.0（`1c465301`，2026-11-15）** 为基准，逐域列 A/B/C + 证据；含硬边界 7 条（终端/网页版/自动化/回放链接/桌宠/图标/手机操控）与性价比排序 |
| `docs/DSH-GO-PARITY.md` | **历史版**（基于 dsh-go 旧快照，无远程/桌宠/插件 UI）。保留作演进记录；结论以 V2 为准 |
| `docs/PERSONAL-AGENT.md` | 个人 Agent 与卡片演进方案（Agent Pack / CardSpec / 与 Muse 对比）。**§3–§6 的「垂域卡片做进外壳」方向已停**，文首有 2026-11-12 勘误；保留的是可复用的分析（Muse 对比、度量指标、风险表） |
| 垂域仓（不在本仓） | <https://github.com/QtePP/Harmony-harness-game>（私有）。游戏的三层——裁判引擎 `@ohos/dsh-sanguo`、棋盘 `SanguoBoard*`、五个 agent pack——都在那边。**本仓不引用它们**：外壳只提供会话/文件/审批/设置，不认识任何垂域概念 |
| `.workbuddy-ai/memory/` | 本地会话记忆（gitignored，不提交） |

## 10. Skill 路由（UI 设计）

本仓库的 **UI 设计 / 界面改动**任务，动笔前必须先用 `skill` 工具加载两个精选 skill（**都加载，不问**）：

1. `swiftui-patterns` —— 当 **ArkUI 范式与状态管理参考**读（范式映射，不是让写 SwiftUI）；
2. `make-interfaces-feel-better` —— 间距 / 字级 / 阴影 / 动效 / 命中区等**界面细节打磨**。

其余任务（PDF、TDD、onboarding、ponytail 等）的路由查全局路由 skill `dsh-skill-router`。
