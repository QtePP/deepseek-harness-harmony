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
| **dsh** | 唯一的「大脑」：npm 包 `@deepseek-ai/dsh`（0.2.1-rc.3，依赖树 566 包，node_modules package.json 实测计数）。会话、工具调用、插件、模型适配、持久化全部来自它；本仓库不含任何 AI 能力 | 载荷内 node_modules |
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
- dsh 0.2.1-rc.3；载荷 zip ≈224MB；HAP ≈335MB（signed）；桥端口 4517。
- `hdc` 不在 PATH：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`。
- 设备侧文件路径两种视角同目录：hdc shell `/data/app/el2/100/base/<bundle>/haps/entry/files/…`
  ⇄ App 内 `/data/storage/el2/base/haps/entry/files/…`（`context.filesDir`）。

## 7. 当前状态（2026-10-26）

- 已交付并真机验证：冷启动恢复、会话 resume、文件预览（网页/图片/文本）、能力开关、
  项目分类（创建/切换真机验证，每项目独立 workspace）。
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
  三档快照写入 session log）。已知待修：审批弹窗渲染进滚动流（应改固定覆盖层）、
  AcpClient 无断线重连；桥为**单客户端**（新连接 `replacing previous client` 顶掉旧连接，
  外部探针实验后须重启 App 恢复客户端）。
- 真机序列号等本地信息只记在本地记忆（`.workbuddy-ai/memory/`，gitignored），**不写进公开仓库**。

签名口径（开源卫生）：

- 仓库内 `build-profile.json5` 的 `signingConfigs` 为空；真实签名在本地
  `build-profile.signing.json5`（gitignored）。
- `scripts/deploy.sh` 自动处理：检出备份或 `devecocli signature generate` → 构建 → 结束时
  还原无签名版本（trap 兜底；新生成的材料自动存回备份）。
- 手动命令行构建的合并/还原配方见 `docs/BUILD.md`。

已知边界（诚实清单）：无 token 级流式；无二进制工具（git/rg/bash）；密钥若随 rawfile 分发
仅适合自用/内测（优先级：设置页 > `secrets.json`）。

**密钥不得走 env**：`@fellow99/node-bridge` 在启动时把子进程环境 dump 进 `node.log`
（`[node_bridge] env DEEPSEEK_API_KEY=…`）。因此 `NodeHost` 把 key 写成 `dsh-home/.api-key`（0600），
通过 `DSH_KEY_FILE` 传路径，由 `bootstrap.cjs` 在桥打完日志之后赋给 `process.env.DEEPSEEK_API_KEY`。
新增任何敏感变量时沿用这个模式，别直接放进 `env`。

## 8. Agent 工作流约定

1. **顺序**：改 `.ets` → ArkTS 静态检查（deveco 侧为 `arkts_check`，一次跑全部改动文件）→
   `devecocli build` → `devecocli run --skip-build --device <serial>`。构建成功前任务不算完成。
2. **载荷迭代**（仅当 `host/` 或依赖变化才需要）：`node scripts/assemble-payload.mjs`
   （`--skip-install` 可复用 staging）→ 再 build。
3. **部署**：`bash scripts/deploy.sh [serial]`（查设备 → 登录 → 签名缺失时生成 → 构建 → 装+启动，
   结束自动还原签名口径）。
4. **验证**：`devecocli log`；应用内 设置 → 诊断；`uitest dumpLayout` + `hdc file recv` 做无头 UI 断言。
   纯 JS 搜索插件的本地三段验证（装机前先过一遍，全绿再部署）：
   - **单测**：必须在**载荷树内**跑——插件 `index.js` 依赖 `@deepseek-ai/schemastery`，
     只有载荷根能解析，在仓库源目录直接跑会 `ERR_MODULE_NOT_FOUND`：
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-tool-fs-search-js && node --test test/*.test.mjs`（38/38）。
   - **配置层**：`DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos --patch .build/payload/patches/ohos.patch.yml --dump-config`
     → `tool-bash`/`tool-pwsh`/`tool-jobs`/`tool-fs-search` 均为 `disabled: true`，末行有
     `- id: tool-fs-search-ohos`（`name: '@ohos/dsh-tool-fs-search-js'`）。
     同一条命令对 `sdk` profile 会报 `patch: entry "skill-office" not found`——那是**预期噪音**：
     `skill-office` 只存在于 sdk 树，平台补丁两 profile 共用，不要为消警告删该行。
   - **启动冒烟**：`printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}\n' | DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos`
     → 返回 `agentInfo.name = deepseek-harness-acp`。注意用管道喂帧；用 `spawn` 脚本发帧在本机偶发
     零帧（时序问题，不是启动失败）。
5. **安全红线**：`secrets.json`、签名材料、设备序列号不进公开仓库；公开文档不出现密钥；
   发现泄漏立即提醒轮换。
6. **口径同步**：改了协议/架构/流程，必须同一 commit 更新本文件与相关 docs/。

## 9. 文档地图

| 文件 | 内容 |
|---|---|
| `docs/ARCHITECTURE.md` | 架构图、协议面、事件渲染表、平台约束 |
| `docs/BUILD.md` | 构建、签名、装机、排障（含受限环境坑） |
| `docs/ROADMAP.md` | 路线图：ACP 切换评估（流式/审批/取消）等 |
| `docs/PLUGIN-MIGRATION.md` | 客户端插件迁移分级（P0/P1/P2/不迁） |
| `.workbuddy-ai/memory/` | 本地会话记忆（gitignored，不提交） |
