# AGENTS.md — dshharmony 多智能体协作公约与统一语言

> 本文件面向在本仓库工作的所有 AI 代理（deveco code、workbuddy、GitHub Copilot 等）与人类协作者。
> 它是**统一语言（ubiquitous language）与口径的唯一权威**：与 docs/、历史对话或任何 agent 的
> 会话记忆冲突时，以本文件与当前代码为准；口径变更必须同一 commit 修订本文件。
> 最后对齐：2026-10-26。

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
| **dsh** | 唯一的「大脑」：npm 包 `@deepseek-ai/dsh`（0.2.1-rc.4，依赖树 618 包，npm install 实测 added 计数）。会话、工具调用、插件、模型适配、持久化全部来自它；本仓库不含任何 AI 能力 | 载荷内 node_modules |
| **Harness / 外壳** | 本仓库自身：ArkUI 界面 + 宿主适配层 | 本仓库 |
| **Payload / 载荷** | `dsh-payload.zip`（≈156MB）：dsh 及其依赖打进 HAP rawfile，首启解包到沙箱 | `scripts/assemble-payload.mjs`、`entry/.../host/Payload.ets` |
| **Bridge / 桥** | 127.0.0.1:4517 回环 TCP，承载 newline-delimited JSON-RPC 2.0；bootstrap 把 socket 伪装成 dsh 的 stdio。**单客户端**：新连接 `replacing previous client` 顶掉旧连接 | `host/bootstrap.cjs`、`entry/.../model/DshClient.ets` |
| **Host 层** | 把 Node 拉进鸿蒙进程的适配层：NAPI dlopen `libnode.so` + `node::Start` | `entry/.../host/NodeHost.ets`、`@fellow99/node-bridge` |
| **Profile SDK / ACP** | dsh 两条程序接口，都是 stdio 上的换行 JSON-RPC、流均可注入。**SDK**：5 个方法，默认路径，真机验收过。**ACP**：9 个方法 + 流式 update + 服务端发起审批，进程内可跑（spike 已证），`DSH_PROFILE=acp` opt-in、尚未真机验收。出局的只是「宿主 spawn dsh」，不是 ACP 本身 | `host/bootstrap.cjs`、`docs/SPIKE-ACP.md` |
| **ohos profile / 纯 JS 搜索** | 自定义 profile（`host/profile-ohos/profiles/ohos`，随载荷分发）：bundle `dependencies` 声明插件（路由表按 bundle 依赖闭包构建，漏声明 = 永不 mount）+ bundle patch 顶层 `- insert:` 挂 `@ohos/dsh-tool-fs-search-js`（纯 JS glob/grep，模型工具名不变）并禁 stock `tool-fs-search`；bootstrap 按内容哈希戳幂等安装到 `$DSH_HOME/profiles/ohos` 并把 `acp` 重映射为 `ohos`（缺模板回落 stock acp）。ACP 方法集不变 | `host/bootstrap.cjs`、`docs/GAP-ANALYSIS.md` §7.1 |
| **Session / 会话** | 客户端生成 UUID 作 id；服务端持久日志 `session.v4.jsonl.zstd`（按初始化 cwd 的 slug 存放，id 全局可查）；本地 `SessionStore` 只存 UI 索引与消息缓存（最近 200 条） | `entry/.../model/ChatModel.ets` |
| **Project / 项目** | 对话分类：命名桶 + 独立 workspace；`default` 为默认项目，兼容全部历史会话与旧路径 | `entry/.../model/ProjectModel.ets` |
| **Workspace** | 默认项目 = `filesDir/workspace`（initialize 的 cwd，向后兼容）；其他项目 = `filesDir/workspaces/<projectId>` | `ProjectStore.workspaceDir()` |
| **Plugin patch / 补丁** | 两份 YAML 经双 `--patch` 传入：平台补丁 `ohos.patch.yml` + 用户补丁 `user.patch.yml`（Settings 能力开关生成；后者后传，覆盖前者同名行） | `host/patches/`、`entry/.../common/PluginConfig.ets` |
| **jitless / fetch-shim** | 无 JIT ACL ⇒ `--jitless` ⇒ 无 WebAssembly ⇒ 内置 undici 失效 ⇒ 纯 JS fetch 垫片接管（`install()` 用 defineProperty 把 fetch/Headers/Response/Request/FormData 全家族换成 shim——dsh 启动期会读全局 Headers（account-platform），只换 fetch 会触发惰性物化 WASM undici 而崩溃） | `host/fetch-shim.cjs`、`host/undici-esm.mjs` |
| **link-fallback** | 沙箱禁 hardlink（EACCES）⇒ `copyFile(COPYFILE_EXCL)` 降级，装配期注入 | `bootstrap.cjs` `installLinkFallback()` |
| **840vp 断点** | ≥840vp：会话栏 + 对话双栏；<840vp：单栏，rail 收进 sheet | `entry/.../pages/Index.ets` |
| **dsh-home** | 沙箱内运行时主目录：`bridge.log`、`bridge-status.json`、`sessions/`、`storages/` 等 | `NodeHost.ets` |
| **ptc-runtime-vm / run_code** | in-process PTC 运行时（`@ohos/dsh-ptc-runtime-vm`，worker_threads + `node:vm`，随载荷分发）：`tools` 行 `mode: native`（2026-10-29 起，此前短暂为 `mode: ptc`；dsh-base 默认即 native——`tools` 行省略 mode 时的 schema 默认值）。**native 下模型工具表 21 个直出工具（glob/grep/read/write/web_search/web_fetch/edit/skill/subagent/todo_write 等），`run_code` 不在其中**——dsh-tools 只在非 native 模式把 run_code 注入可见表（`dsh-tools/lib/index.js` view()：`mode !== "native"` 才 `visible.set(RUN_CODE_NAME)`）；`mode: ptc` 则反过来：wire 上**只有 run_code**（wireSchemas 过滤掉其余 schema），其余工具只能经程序内 `tools.*` SDK。boot-report 的 `tools(N)` 用 `ctx.tools.schemas()`（注册表视图），ptc 模式下计 22（全部 + run_code），native 下计 21。ptc-runtime-vm 仍挂载（提供 `ctx.ptcRuntime`），未来 preset 可经 `dsh-agent-tool-presentation` 行（`tool-presentation`，preset 级 `presentAs`）opt-in PTC；worker 不可用时优雅 `worker-exit` | `host/profile-ohos/.../@ohos/dsh-ptc-runtime-vm`、`.build/payload/node_modules/@deepseek-ai/dsh-tools/lib/index.js` |
| **credentials-live / 密钥热更新** | `@ohos/dsh-credentials-live`（随载荷分发，ohos profile 专属）：目录级 fs.watch + 1.5s 轮询 `<dsh-home>/.api-key`，变化经 `credentials.set()/unset()` 热发布。dsh 启动期冻结 env 快照（`loadLayeredEnv` 拷 `process.env`），运行中改 env 永远无效——这是唯一热路径；Settings 保存密钥 ~2s 生效无需重启（ACP 路径；SDK profile 无此插件，重启生效） | `host/profile-ohos/.../@ohos/dsh-credentials-live` |
| **time-context / 时间上下文** | `@deepseek-ai/dsh-time-context`（dsh 自带、随载荷分发）：把当前时间作为 durable 注入写进请求历史（默认 10 分钟一次），模型据此知道"今天"。**它不是工具**，桌面/SDK profile 由 `dsh-sdk-app` 挂载，`dsh-acp-app` 不含 → ohos bundle 自己 insert 一行；缺它时模型对相对日期的推理全是猜 | `@ohos/dsh-bundle-ohos/cordis.patch.yml` |
| **boot-report / 能力自检** | `@ohos/dsh-boot-report`（ohos profile 专属）：启动 5s 后把已注册工具名与 `ctx.web.searchReady()/fetchReady()` 写进 `bridge.log`。手机没有终端，`web` 用 `ctx.get('web')` 而非 inject 读取，seam 整体缺失时也要报出来 | `host/profile-ohos/.../@ohos/dsh-boot-report` |

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
   零 spawn，`docs/SPIKE-ACP.md`）。当前**默认仍是 SDK**，`DSH_PROFILE=acp` 为 opt-in，
   ACP 尚未真机验收。
3. **集成点**：全部集中在 `host/` 适配层（bootstrap / fetch-shim / undici 别名 / 装配期补丁 /
   `profile-ohos` 自定义 profile 模板），不改 dsh 源码。
4. **版本耦合**：协议契约是实测所得（2026-10-25），写死在 `DshClient.ets`；dsh 升级若改协议，此处假设即失效。

## 4. 协议口径（以 `model/Protocol.ets` + `DshClient.ets` 为准）

**两条 profile 并存**：`DSH_PROFILE=sdk`（默认，真机验收过）/ `acp`（opt-in，仅本地桥验证）。
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

### 4.2 ACP profile（`DSH_PROFILE=acp`，opt-in）

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
- **本地装配/同构测试 Node = 22.22.2**（macOS 侧，见 `scripts/deploy.sh` 的 PATH）。两个数字并存，不是笔误。
- dsh 0.2.1-rc.4；载荷 zip ≈225MB；HAP ≈335MB（signed）；桥端口 4517。
- `hdc` 不在 PATH：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`。
- 设备侧文件路径两种视角同目录：hdc shell `/data/app/el2/100/base/<bundle>/haps/entry/files/…`
  ⇄ App 内 `/data/storage/el2/base/haps/entry/files/…`（`context.filesDir`）。

## 7. 当前状态（2026-10-27）

- 已交付并真机验证：冷启动恢复、会话 resume、文件预览（网页/图片/文本）、能力开关、
  项目分类（创建/切换真机验证，每项目独立 workspace）。
- **in-process PTC 运行时已交付并真机闭环（2026-10-27，P1①）**：
  `@ohos/dsh-ptc-runtime-vm`（worker_threads + `node:vm`）挂进 `ohos` profile，
  `dsh-bundle-ohos` patch 禁 stock `ptc-runtime`；`tools` 行现为 `mode: native`
  （2026-10-29 起，此前短暂为 `mode: ptc`）——native 下 21 个工具直出（glob/grep/read/web
  等），run_code 不在模型工具表（源码契约：仅非 native 注入）；ptc 模式则 wire 上只有
  run_code，其余经程序内 `tools.*` SDK。
  真机（手机 2026-10-27）全绿：worker_threads 在 arm64/`--jitless` 可用；模型一个 run_code
  程序内 `tools.write`×3 + `tools.glob` 计数正确答 "4"；contain-probe 回归——程序内
  `grep` path=`..` 仍被收口拒绝（`grep path escapes the session workspace`）。本地：
  单测 22/22（含 `--jitless`）+ dump-config + 冒烟 + 真实模型 E2E（`tools.glob` → "3"）。
  三条实测契约写死在 `docs/GAP-ANALYSIS.md` §L2：dsh-tools binding 是 resolve=值/reject=错误
  （不是 settle 对象）；cordis traceable 下 service 类禁 `#private` 字段（方法 `this` 是
  Proxy，品牌检查必炸，用普通属性）；amaro TS 擦除依赖 WASM ⇒ jitless 下设备不能跑 TS，
  executionInstructions 明示写纯 JS。
- **API 密钥热更新已交付并真机闭环（2026-10-27）**：`@ohos/dsh-credentials-live`
  挂进 `ohos` profile（bundle `dependencies` + `cordis.patch.yml` insert 双登记），真机
  bridge.log 实证 `[credentials-live] watching <dsh-home>/.api-key (dir-watch + poll every
  1500ms)` + `boot: ohos runtime mounted`——目录级 fs.watch（inotify）在应用沙箱可用。
  根因链：dsh 启动期 `loadLayeredEnv` 冻结 env 快照 ⇒ 运行中改 `process.env` 无效；外部改
  `.credentials.yaml` 需 0600/锁配合（`assertOwnerOnly`）且有竞态——都不如暂存文件轮询 +
  `credentials.set()`（provider 自身 set/unset 直更内存快照 + notifyUpdated，不经 watcher）。
  ArkTS 侧：`AppConfig.save` 以 temp+rename 原子写 `.api-key`（清 key 删文件）；`NodeHost`
  启动对空 key 删陈旧暂存（修跨重启清 key 失效 bug）；Settings 保存 toast 按 `host.isAcp()`
  分「即将生效」/「重启生效」。单测 8/8（载荷树内）+ 回归 fs-search 38/38、ptc 22/22
  （含 `--jitless`）+ dump-config（`credentials-live-ohos` 挂载、五处 disabled、`mode: native`）
  + 冒烟。
- **纯 JS 搜索插件已交付并真机闭环（2026-10-26，P0）**：自定义 `ohos` profile + bootstrap
  模板安装/acp→ohos 重映射；真机模型轮 `glob`/`grep` 真实命中（`danger-tablet-test.txt`），
  模型工具表无 bash/job_kill/job_list/job_output（P0a），权限三档快照不受影响；插件纯函数
  单测 37/37。根因（bundle 依赖声明）与机制：`docs/GAP-ANALYSIS.md` §7.1。
- fetch-shim 全家族替换修复已真机闭环（Gate 0，2026-10-26）：启动即 `boot: sdk runtime
  mounted`，0 fatal / 0 CRASH，桥 running，UI「dsh 已就绪」；启动期仍有一条良性
  `WebAssembly is not defined` unhandled rejection（与旧可用版本同类，不致命）。
- ACP 切换（Stage 1）已过 spike（`docs/SPIKE-ACP.md`，workbuddy）：进程内 PassThrough 劫持
  stdio + `runCli()` 零 spawn 可行；审批线上方法名 `session/request_permission`（snake_case）。
- `feature/acp` 分支（workbuddy，2026-10-26）：`host/bootstrap.cjs` 引入 `DSH_PROFILE`
  开关（默认 `sdk`，未改动 SDK 路径），`bridge-status.json` 增加 `profile` 字段；两个 profile
  均通过本地桥 smoke（sdk `initialize → serverInfo`；acp `initialize + session/new → sessionId`）。
  断线重连契约已实测并写入 §4.2。
- ACP 协议矩阵已在真机闭环（2026-10-26，fport 外部驱动 + `DSH_PERMISSION_MODE=read-only`
  测试构建）：initialize / session/new / set_config_option / prompt（审批 `allow-once` 放行
  后工具真实落盘）/ cancel（通知）/ 断线重连 / close / list / resume 全部实机通过；新发现
  set_config_option 选项集收缩契约（§4.2）。详见 `docs/SPIKE-ACP.md` §9。
- ArkTS ACP 客户端已交付（2026-10-26，手机+平板真机验证）：AcpProtocol/AcpClient + 审批
  弹窗 + 流式气泡 + usage + 停止（cancel 通知）+ 模型选择器（选项集收缩适配）+ resume
  降级 + **权限三档选择器**（只读/平衡/宽松；danger-full-access 平板端到端零审批落盘，
  三档快照写入 session log）。审批弹窗为根 Stack 固定覆盖层（不在 transcript 流内，
  早期「渲染进滚动流」记录是未提交中间态，已勘误）。
- **AcpClient 断线重连已交付并真机闭环（2026-10-27）**：客户端只报掉线（`onDisconnect`
  单发，error/close 同一掉线只报一次），恢复编排在 `Index.ets`——首退避 120s、×2、
  cap 300s、6 次尝试；无在跑轮次直接复附（对旧 sessionId prompt），孤儿轮走重置语义
  （`session/close` 掐孤儿轮 → `session/resume` → 标记「已中断」由用户决定重发，见 §4.2
  与 `docs/SPIKE-ACP.md` §11）。真机验证（手机）：断连 06:38:59.044 → 重连 06:40:59.076，
  **精确 120.03s** 按设计夺回客户端槽位，断连/复附消息均落 `dsh_sessions` 缓存。
  探针窗口注意：桥为**单客户端**（新连接 `replacing previous client` 顶掉旧连接），
  App 会在 2 分钟内自动回连抢回槽位——外部 fport 探针单轮（≤2min）不受影响，更长的
  外部实验须先 force-stop App，否则探针会被 App 的自动重连顶掉。
- 真机序列号等本地信息只记在本地记忆（`.workbuddy-ai/memory/`，gitignored），**不写进公开仓库**。
- **图片识别已修（2026-10-29）**：根因是**请求期投影**而非网络——dsh 把每张请求图投影到 DeepSeek 视觉网格
  （14px patch、3:1 下采样、1024 token），源图超预算就要 sharp 重编码；设备上 sharp 只有 darwin-arm64 +
  wasm32（jitless 无 WASM），`host/sharp-stub.cjs` 的编码阶梯 fail-closed，抛出的普通 Error 被
  `dsh-llm-deepseek` 统一包成 `DeepSeek Messages transport failed`/`TRANSPORT`（重试 5 次全白跑，请求未发出）。
  修法：桩的 `.jpeg()` 改为**原字节直通**并回报**源尺寸**（`toBuffer({resolveWithObject})` 契约），投影退化为
  no-op、由服务端自己下采样，代价只是上传变大；WebP/PNG/TIFF/GIF 仍 fail-closed（其字节不能冒充 JPEG）。
  本地验证：同一张 1320×2848 图 `readRequestImageFile` 从 `SharpStubError` 变为直通；ACP 端到端（无效 key）
  已到达服务端并返回 401 鉴权错误，不再是 TRANSPORT。单测 17/17。

签名口径（开源卫生）：

- 仓库内 `build-profile.json5` 的 `signingConfigs` 为空；真实签名在本地
  `build-profile.signing.json5`（gitignored）。
- `scripts/deploy.sh` 自动处理：检出备份或 `devecocli signature generate` → 构建 → 结束时
  还原无签名版本（trap 兜底；新生成的材料自动存回备份）。
- 发布签名走 `scripts/build-release.sh`（三步，签名在 hvigor 之外）：`--build-mode release
  --assemble-type assembleApp` 一次构建出未签名 HAP 与 .app → DevEco SDK 的
  `hap-sign-tool sign-app` 以明文密码给 HAP 本地签名（hdc 直装用）→ `hap-sign-tool
  sign-app -inForm zip` 给 .app **容器整体**签名（= hvigor SignApp 任务的 CLI 等价），
  `verify-app` 对独立 HAP 与 .app 容器各校验一次。绕开 hvigor SignHap/SignApp 的原因：
  它们只收 DevEco 加密密码（≥32 字符 `000000...` 密文），明文报 `00303116`。材料八字段
  （含明文密码）在 `build-profile.release.json5`（gitignored）。
- **AGC 提交（含测试轨道）只收 App Pack（.app），文件选择器过滤 .hap；且校验的是 .app
  容器签名**——2026-10-31 实测：容器未签名的 .app 被测试轨道 991「非法软件包/未检测」
  拒收，与包内 HAP 是否签名无关。**包内 HAP 本来就该是未签名的**（hvigor PackageApp
  源码实证：所有 `getModuleTargetOutputFileName` 调用都传 signed=false；SignApp 只签
  容器；AGC 分发时再拆包重签——官方 FAQ「其中的HAP包没有签名」说的就是这个设计）。
  上传 `build/outputs/default/dshharmony-default-signed.app`（容器已签名）。已签 .hap
  仅用于 hdc 直连安装分发。
- 手动命令行构建的合并/还原配方见 `docs/BUILD.md`。

已知边界（诚实清单）：无 token 级流式；无二进制工具（git/rg/bash）；密钥若随 rawfile 分发
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
   本地三段验证（装机前先过一遍，全绿再部署）：
   - **单测**：必须在**载荷树内**跑——插件 `index.js` 依赖 `@deepseek-ai/schemastery` 等包，
     只有载荷根能解析，在仓库源目录直接跑会 `ERR_MODULE_NOT_FOUND`：
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-tool-fs-search-js && node --test test/*.test.mjs`（38/38）；
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-ptc-runtime-vm && node --test test/*.test.mjs`（22/22，
     加 `--jitless` 再跑一遍证明无 WASM 路径）；
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-credentials-live && node --test test/*.test.mjs`（8/8）。
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
| `docs/ARCHITECTURE.md` | 架构图、协议面、事件渲染表、平台约束 |
| `docs/BUILD.md` | 构建、签名、装机、排障（含受限环境坑） |
| `docs/ROADMAP.md` | 路线图：ACP 切换评估（流式/审批/取消）等 |
| `docs/PLUGIN-MIGRATION.md` | 客户端插件迁移分级（P0/P1/P2/不迁） |
| `docs/PERSONAL-AGENT.md` | 个人 Agent 与功能卡片演进方案（Agent Pack / CardSpec / 与 Muse 对比） |
| `.workbuddy-ai/memory/` | 本地会话记忆（gitignored，不提交） |

## 10. Skill 路由（UI 设计）

本仓库的 **UI 设计 / 界面改动**任务，动笔前必须先用 `skill` 工具加载两个精选 skill（**都加载，不问**）：

1. `swiftui-patterns` —— 当 **ArkUI 范式与状态管理参考**读（范式映射，不是让写 SwiftUI）；
2. `make-interfaces-feel-better` —— 间距 / 字级 / 阴影 / 动效 / 命中区等**界面细节打磨**。

其余任务（PDF、TDD、onboarding、ponytail 等）的路由查全局路由 skill `dsh-skill-router`。
