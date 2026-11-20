# 架构

> 目标：**在 HarmonyOS 设备上自足运行 dsh**——不连电脑、不投屏、不套壳浏览器。前端是原生
> ArkUI，后端是**同一应用进程内**的真 dsh 运行时。
>
> *Goal: run `dsh` self-sufficiently on a HarmonyOS device — no computer tethering, no screen
> mirroring, no WebView shell. The front end is native ArkUI; the back end is the real dsh
> runtime inside the same app process. Not a port of dsh, not a subprocess: `dsh` stays the
> single brain, this repository is only the host adaptation layer.*
>
> 本文件是**权威文本**，排版版见 [`on-device-architecture.html`](on-device-architecture.html)。
> 逐行启动走读见 [`BOOT.md`](BOOT.md)；协议实测矩阵见 [`SPIKE-ACP.md`](SPIKE-ACP.md)；
> 能力差距与根因见 [`GAP-ANALYSIS.md`](GAP-ANALYSIS.md)；「哪些地方是硬啃下来的、代价是什么」
> 见 [`BREAKTHROUGHS.md`](BREAKTHROUGHS.md)。

## 0. 四个数字

| | 值 | 出处 |
|---|---|---|
| 大脑 | **dsh 0.2.2-rc.5**，676 包 | `scripts/assemble-payload.mjs` 的 `PINNED_DSH_VERSION` |
| 引擎 | **Node v24.2.0**（`libnode.so`，同进程） | 设备端 `dsh-home/bridge-status.json` 的 `node` |
| 桥 | **127.0.0.1:4517**，换行 JSON-RPC 2.0，**单客户端** | `host/bootstrap.cjs` |
| 载荷 | `dsh-payload.zip` ≈240MB（十进制），解包后 1.0G | `entry/src/main/resources/rawfile/` |

## 1. 进程剖面

```
┌─ 一个 HAP · 一个进程 ──────────────────────────────────────────────┐
│                                                                   │
│  ArkTS / ArkUI                    entry/src/main/ets/**           │
│    界面 · 会话 · 审批弹窗 · 设置   42 个 .ets / 15.4k 行            │
│         │                                                         │
│         │  换行 JSON-RPC 2.0 over 127.0.0.1:4517（单客户端）        │
│         ▼                                                         │
│  Node v24.2.0（同进程 detached pthread，--jitless）                 │
│    host/bootstrap.cjs   回环桥 + stdio 劫持 + 十个垫片              │
│    host/fetch-shim.cjs  jitless 下的纯 JS fetch                    │
│         │                                                         │
│         ▼                                                         │
│  dsh 0.2.2-rc.5         会话 · 工具 · 插件 · 模型适配 · 持久化      │
│    node_modules/        676 包，随载荷分发                         │
└───────────────────────────────────────────────────────────────────┘
```

三层语言、一个进程：界面是 ArkTS（编译成 `.abc`），干活的是 JavaScript，跑 JavaScript 的引擎是
C++（V8 + libuv）。**唯一的跨语言边界是那条 TCP**——ArkTS 与 JS 之间没有绑定调用，只有帧。

## 2. 运行时：同进程，不是子进程

| 事实 | 后果 | 锚点 |
|---|---|---|
| 鸿蒙禁 fork/exec | 不能 `spawn('node')`，也没有 `git` / `rg` / `bash` 可跑 | [`GAP-ANALYSIS.md`](GAP-ANALYSIS.md) §1 |
| `node::Start` **每进程一次** | 崩溃即终态；连接阶段失败只能重连，不能重新投递 | `NodeHost.ets` `runtime.isRunning()` 守卫 |
| UI 线程不能起 Node | 投递到 detached pthread（32MB 栈），再 `waitUntilRunning(30s)` | `NodeHost.ets:151` |
| `--jitless --expose-internals` | 无 WebAssembly；内部模块访问走纯 JS 垫片 | `NodeHost.ets:132` |
| 引擎落在 ABI 目录 `libs/arm64/` | HAP 内是 `arm64-v8a`，引导件按候选链逐个试 | `@fellow99/node-bridge` |

**怪癖（别凭直觉用）**：`process.cwd()` 是 `/`，`process.execPath` 是 `/system/bin/appspawn`，
`os.cpus()` 长度为 0。所以 `HOME` / `TMPDIR` 由宿主显式注入，沙箱根用**会话 cwd** 而不是进程 cwd。

**诊断三件套**：`node.log`（原生桥写的，含 env dump）、`dsh-home/bridge-status.json`
（`state / profile / port / pid / node / wasm`）、`dsh-home/bridge.log`（bootstrap 自己的日志）。
手机上没终端，这三份文件就是全部证据；设置 → 诊断面板把三样都读出来。

## 3. 宿主适配层：三段，职责不重叠

### 3.1 ArkTS 侧编排（`entry/.../host/NodeHost.ets`）

六步固定顺序，**顺序不能乱**：

1. 没有 key 直接失败（不在没有凭据的情况下白跑一遍解包）；
2. 解包载荷（`Payload.ensure`）；
3. 备目录：`workspace/`、`dsh-home/`、`tmp/`；
4. 写 key 文件（`dsh-home/.api-key`，只传路径 `DSH_KEY_FILE`）；
5. 投递 Node（九个环境变量，见 `BOOT.md` §2）；
6. 连桥 + 握手（SDK 走 `initialize(cwd, provider, model)`；ACP 走 `initialize`）。

失败信息带 `stage=`（原生引导件卡在 dlopen / dlsym / stdio / start 哪一步）。

### 3.2 载荷物化（`entry/.../host/Payload.ets`）

rawfile 里的 zip 不可寻址，Node 无法从中 `require`。所以分 1MiB 块复制进沙箱再
`zlib.decompressFile`；**归档长度当幂等戳**（`payload.stamp`），载荷一更新自动重解，没变就零成本跳过。

### 3.3 bootstrap 的十个垫片（`host/bootstrap.cjs`）

顺序不能乱——ESM 的具名导入是首次 import 时的**快照**，晚一步补丁就落不到
`import { link } from 'node:fs/promises'` 上。

| # | 垫片 | 治什么 |
|---|---|---|
| 1 | `rerouteConsole` | stdout 只留给 JSON-RPC，console 全部改道日志文件 |
| 2 | `installRequireBuiltinAlias` | 原生 addon 无 ohos 构建 → 别名到纯 JS 垫片（需 `--expose-internals`） |
| 3 | `installSharpStub` | sharp 只有 darwin-arm64 / wasm32 → 原字节直通桩 |
| 4 | `installLinkFallback` | 禁硬链接（EACCES）→ `copyFile(COPYFILE_EXCL)` |
| 5 | `installDirSyncFallback` | 祖先 `/data` 只读 open 被拒 → 空壳 handle（否则内联图片每轮报「unable to persist」） |
| 6–8 | userfile 挂载三件套 | `/storage/Users/` 不支持 chmod/chown、FICLONE EPERM |
| 9 | `installProfileTemplate` | 按内容哈希把 `ohos` profile 装进 `$DSH_HOME/profiles` |
| 10 | `acp → ohos` 重映射 | 只有自定义 profile 能 insert 新行（patch 只能改/禁已有行） |

另有 `installJitlessShims()`（在 `boot()` 开头才跑）：探 `typeof WebAssembly`，缺失才装
`fetch-shim` 并注册 ESM 的 `undici` 别名。**整族替换** `fetch / Headers / Response / Request /
FormData` 是必须的——dsh 启动期会读全局 `Headers`，只换 `fetch` 会触发 undici 的 WASM 惰性物化而崩。

### 3.4 补丁是三份 YAML，不是一个开关

| 文件 | 位置 | 能做什么 |
|---|---|---|
| bundle patch | `@ohos/dsh-bundle-ohos/cordis.patch.yml` | **加行**（`- insert:`）+ 禁用 stock 行；插件包还必须在 bundle 的 `dependencies` 里声明，否则永不 mount |
| 平台 patch | `host/patches/ohos.patch.yml` | 只禁用「调用即失败」的行：pwsh / plugin-manager / office / bash / jobs |
| 用户 patch | `filesDir/patches/user.patch.yml` | 设置页能力开关 + 本地模型路由；**后传覆盖前者** |

## 4. 协议层：一条桥，两个 profile

### 4.1 传输

- `127.0.0.1:4517` TCP，**一行一帧** JSON-RPC 2.0。
- bootstrap 把 socket 管进**进程级** `PassThrough`，再用 `Object.defineProperty` 覆盖
  `process.stdin/stdout`（Node 24 里这俩是 getter-only，直接赋值会抛）。
- **首次连入才 boot dsh**：保证 stdout 从第一帧起就有接收方。
- **socket 断开只 pause 不 end**：stdin EOF 会被 dsh 当成 shutdown，UI 掉线不能杀运行时。
- **单客户端**：新连接 `replacing previous client` 顶掉旧连接（所以外部 `hdc fport` 探针
  只能单轮，更长的实验要先 force-stop App）。

### 4.2 两个 profile

| | SDK（`DSH_PROFILE=sdk`，默认） | ACP（`DSH_PROFILE=acp`，运行时重映射为 `ohos`） |
|---|---|---|
| 方法 | 5 请求 + 4 通知 | 9 方法 + `session/update` + `session/request_permission` |
| 流式 | **无**（一步结束才发 `assistant/message`） | 有（`agent_message_chunk` / `agent_thought_chunk`） |
| 审批 | **无通道** | 服务端发起，两键 `allow-once` / `reject-once`，fail-closed |
| sessionId | 客户端生成，未知 id 懒创建 | **服务端生成** |
| 取消 | 无 | `session/cancel`（**通知**，带 id 发会 `Method not found`） |
| 平台插件 | **不挂**（`installProfileTemplate` 只在 acp/ohos 时生效） | 纯 JS 搜索 / PTC / 密钥热更 / 时间上下文 / boot 自检 |

> **这是当前最重要的一条架构事实**：默认 `sdk` 是**兼容历史的降级路径**——它不挂 ohos 插件，
> 所以 `glob`/`grep` 会走 spawn ripgrep（必失败）、改密钥要重启、没有工具表自检、模型不知道「今天」。
> 完整能力必须切 ACP 并重启。见 §7。

### 4.3 契约摘要（细节见 [`SPIKE-ACP.md`](SPIKE-ACP.md) 与 AGENTS.md §4）

| 契约 | 按直觉做会怎样 |
|---|---|
| 事件信封 `{type, seq, time, data}` | **字段在 `data` 下**；读扁平结构 = 对话永远空 |
| `session/cancel` 是通知 | 当请求发（带 id）→ `Method not found` |
| `set_config_option` 的 model value 是 **JSON 数组字符串** | 传对象 → 静默不改 |
| 选项集会**收缩** | 缓存旧列表 → 切走默认模型后切不回来，`-32602` |
| 帧必须带 `"jsonrpc":"2.0"` | 缺失 → 预校验 `-32600`，到不了方法分发 |
| 不答审批 = **无限挂起** | 以为会超时失败 → 实际整轮卡死，服务端不自动放行 |
| inflight 时不能发第二条 prompt | 想「插话」→ 被拒；ACP 没有 steering 通道 |

**断线时正在跑的那一轮**：服务端继续跑，`session/update` 也会投给新连接，但原
`session/prompt` 的响应**永久丢失**，且 update 帧里没有 turn id——客户端无从判断它何时结束。
所以恢复走「重置语义」：`initialize` → `session/close` 掐孤儿轮 → `session/resume` → 标记「已中断」。

### 4.4 客户端渲染映射

| SDK 事件（`session.event`） | ACP 通知（`session/update`） | 渲染 |
|---|---|---|
| `assistant/message` | `agent_message_chunk` / `agent_thought_chunk` | 气泡正文 / 「思考」块（空块必须跳过） |
| `tool/call` | `tool_call` | 工具轨迹一行（名字 + 参数摘要） |
| `tool/result` | `tool_call_update` | 结果卡（失败/中断分别转红与标注） |
| `session/title` | ——（ACP 无） | 运行时生成的标题；ACP 下由首轮文本推断 |
| `turn/end` | `session/prompt` 的 `{stopReason}` | 结束 running，落盘 |
| —— | `usage_update` | 上下文小环 + 每轮用量 |

## 5. 沙箱：四层，而且没有一层是内核级进程沙箱

| 层 | 强度 | 是什么 |
|---|---|---|
| **L0 系统应用沙箱** | 内核级 | 每个 App 一个 uid，只能碰 `/data/storage/el2/base/haps/entry/files/…`。唯一真正的安全边界 |
| **L1 目录授权** | 系统授权 | 系统选择器 + `FILE_ACCESS_PERSIST` + `fileShare.activatePermission()`，暴露真实路径 `/storage/Users/currentUser/…`；父目录与兄弟目录仍 EPERM |
| **L2 dsh 文件沙箱** | 进程内策略 | `dsh-fs-sandbox` **只栅变更**（write/edit/patch/delete/move），读一律放行 |
| **L3 审批** | 策略 | `ask` / `never` 两档，由权限预设捆绑；ACP 上是 `session/request_permission` |

> The fence is a policy check in TRUSTED code over a MODEL-CONTROLLED path, **NOT a kernel
> boundary**. This is containment, not a security boundary. —— `dsh-fs-sandbox/src/index.ts`

`ctx.sandbox`（进程沙箱）在设备上必然 `SANDBOX_UNAVAILABLE`：它的后端是 bwrap / landlock-run /
Seatbelt / Windows ACL，**每一个都要 spawn**。这也和「bash 整族被禁」自洽——没有 shell，
就没有需要内核沙箱去关的东西。

| 档位 | 文件变更 | 审批 | 真机表现 |
|---|---|---|---|
| `read-only` | 全部拒绝 | ask | 裸写先被沙箱拒（无审批请求）；带 `sandbox_permissions` 重试才触发审批 |
| `workspace-write`（默认） | 工作区内直写 | ask | 越区才问 |
| `danger-full-access` | 不栅 | never | 全放行、零审批 |

档位由 `DSH_PERMISSION_MODE` 在**启动期**固化，会话创建时写进 `permission/preset`、`sandbox/mode`、
`approval/policy` 三条事件 ⇒ **切档要重启 App，且只影响新会话**。

## 6. 平台约束（十条）

| 约束 | 后果 | 对策 |
|---|---|---|
| 禁 fork/exec | 无 git / rg / bash、无 PTY、无包管理 | 同进程 Node；纯 JS 搜索 + in-process PTC |
| `node::Start` 一次 | 崩溃即终态 | UI 明示重启；`bridge-status` + 崩溃记录 |
| JIT 需受限 ACL | 不申请就 SIGTRAP | 默认 `--jitless`，零受限权限可装 |
| jitless ⇒ 无 WASM | undici/llhttp、TS 擦除、sharp 全废 | fetch-shim + undici 别名 + sharp 桩 + 明示写纯 JS |
| 原生 `.node` 须自身签名域 | koffi 等不可用 | `npm install --ignore-scripts`，源头不打进载荷 |
| 禁 hardlink | `link tmp→final` 原子发布失败 | `copyFile(COPYFILE_EXCL)` 降级 |
| 沙箱只认 app files 根以下 | 祖先目录 open EACCES ⇒ 内联图片报错 | 只读 open 目录给空壳 handle |
| userfile 挂载非 POSIX | chmod / chown / FICLONE 全 EPERM | 三条 mount-aware 降级 |
| `cwd`=`/`、`execPath`=appspawn | 依赖这两者的库静默出错 | 宿主注入 `HOME` / `TMPDIR`；沙箱根用会话 cwd |
| 单 HAP 三形态 | 手机 / 平板 / 2in1 | 840vp 断点：窄屏单栏，宽屏「会话栏 + 对话」 |

## 7. 已知边界（诚实清单）

- **默认 profile 是 `sdk`，而它是降级路径**：不挂 ohos 插件 ⇒ `glob`/`grep` 走 spawn ripgrep（失败）、
  密钥改动要重启、无 boot-report、无 `time-context`（模型不知道「今天」）、无流式、无审批通道。
  切到 ACP 才有完整能力，代价是重启 App。**这是一个待决策的产品问题，不是 bug**。
- **无 token 级流式（SDK 路径）**：SDK 只在一步结束时发 `assistant/message`；ACP 有 chunk 级流式。
- **工具面受平台限制**：没有 `git` / `rg` / `bash` 二进制；`bash`、`job_*`、`pwsh` 整族已从模型工具表移除
  （让工具「不存在」比让它「失败」更好）。
- **设备端不做图片降采样**：`sharp` 桩只直通原字节，由服务端投影到视觉网格；只影响上传体积。
- **Node 24.2 vs `engines >=24.9`**：dsh 的 `package.json` 声明 ≥24.9，设备上是 24.2，运行期不校验，
  目前可用——但这是运气，换 Node 要换 `@fellow99/node-runtime`，是另一个工程。
- **密钥若随 rawfile 分发只适合自用/内测**（优先级：设置页 > `secrets.json`）。
- **会话续接是双层账本**：服务端 `.zstd` 日志是唯一权威；本地 `SessionStore` 只存 UI 索引与消息缓存
  （最近 200 条），两者以 sessionId 关联。

## 8. 读哪里

| 想知道 | 读 |
|---|---|
| 启动链路逐行走读、每个垫片为什么存在 | [`BOOT.md`](BOOT.md) |
| 协议实测矩阵、断线重连的取证 | [`SPIKE-ACP.md`](SPIKE-ACP.md) |
| 接口清单 + 6 张时序图 | [`API-AND-SEQUENCE.md`](API-AND-SEQUENCE.md) |
| 与桌面端的能力差距、根因、替代方案分级 | [`GAP-ANALYSIS.md`](GAP-ANALYSIS.md) |
| 哪些是硬啃下来的、代价是什么 | [`BREAKTHROUGHS.md`](BREAKTHROUGHS.md) |
| 构建 / 签名 / 装机 / 排障 | [`BUILD.md`](BUILD.md) |
| 统一语言与口径（最高权威） | [`../AGENTS.md`](../AGENTS.md) |

关键代码：`entry/src/main/ets/host/NodeHost.ets`（编排）、`host/bootstrap.cjs`（桥 + 垫片）、
`entry/src/main/ets/model/{DshClient,AcpClient}.ets`（两个协议客户端）、
`host/profile-ohos/profiles/ohos/`（平台插件模板）、`scripts/assemble-payload.mjs`（载荷装配）。
