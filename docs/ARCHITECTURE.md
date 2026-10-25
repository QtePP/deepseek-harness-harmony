# 架构

目标：**在 HarmonyOS 设备上自足运行 dsh**——不连电脑、不投屏、不套壳浏览器。前端是原生
ArkUI，后端是同一应用进程内的真 dsh 运行时。

```
┌─ 一个 HAP ─────────────────────────────────────────────────────────────┐
│                                                                        │
│  ArkTS / ArkUI 前端                                                     │
│    pages/Index.ets          三形态断点（<840vp 单栏 / ≥840vp 双栏）       │
│    view/ChatView.ets        消息流 + 输入区（自绘气泡、代码块分段）        │
│    view/SessionRail.ets     会话列表                                     │
│    view/SettingsSheet.ets   API Key / 模型 / 诊断                        │
│         │                                                              │
│         │  newline-delimited JSON-RPC 2.0 over 127.0.0.1:4517          │
│         ▼                                                              │
│  model/DshClient.ets        请求/响应配对、事件分发、分帧解码              │
│         │                                                              │
│         ▼  TCP                                                        │
│  host/NodeHost.ets          载荷物化 → NodeRuntime.start → 握手         │
│         │                                                              │
│         ▼  @fellow99/node-bridge（dlopen libnode.so, node::Start）      │
│  Node v24.2.0（同进程线程）                                              │
│    host/bootstrap.cjs       TCP 桥 + stdio 劫持 + 启动 dsh               │
│    host/fetch-shim.cjs      jitless 下的纯 JS fetch                     │
│         │                                                              │
│         ▼                                                              │
│  dsh --profile sdk          会话、工具、插件、模型适配、持久化            │
│    node_modules/            随包分发（@deepseek-ai/dsh 及其依赖）        │
└────────────────────────────────────────────────────────────────────────┘
```

## 为什么不是「子进程 + ACP」

dsh 有两条面向程序的协议：

| 协议 | 传输 | 能否用于鸿蒙 |
|---|---|---|
| `dsh --profile acp`（ACP） | **stdio 子进程** | ❌ 沙箱禁止 fork/exec，`startArkChildProcess` 真机返回 `801` |
| `dsh --profile sdk`（SDK JSON-RPC） | stdio，但 **`JsonRpcConfig.input/output` 可注入流** | ✅ 同进程挂载，把 socket 当 stdio |

所以选 SDK 协议：它本来就把 stdio 当作可替换的字节流，而我们恰好需要一个「不是 stdio 的 stdio」。
`bootstrap.cjs` 在 `node::Start` 之后把 `process.stdin`/`process.stdout` 换成 socket 支撑的
`PassThrough`，dsh 对此无感知。

## 启动时序

```
EntryAbility → Index.aboutToAppear
  1. AppConfig.load            偏好设置 → 无则读 rawfile/secrets.json
  2. Payload.ensure            rawfile zip → 分块复制到沙箱 → zlib 解包（按归档长度做幂等标记）
  3. NodeRuntime.start         投递到 detached pthread（UI 线程不可调用 node::Start）
  4. waitUntilRunning(30s)     轮询原生探针，等 Node 主循环起来
  5. DshClient.connect         连 127.0.0.1:4517 —— 首次连接才触发 bootstrap 引导 dsh
  6. client.initialize         {cwd, provider, model} → 之后 session/prompt 可发
  7. phase = READY             切到聊天界面
```

第 5 步的顺序是刻意的：`bootstrap.cjs` **只在有客户端连入时才启动 dsh**，这样 dsh 的
stdout 从第一帧起就有接收方，不会丢初始化输出。

## 协议面（只有 5 个方法）

客户端 → 服务端：

- `initialize` `{cwd, provider, model, reasoningEffort?, maxTokens?}` → `{serverInfo}`
- `session/prompt` `{sessionId, contentBlocks:[{type:'text',text}]}` → `{messageId}`（入队回执，不是答案）
- `shutdown`

服务端 → 客户端通知：

- `session.event` — 每条会话日志事件（**全运行时的会话**，客户端自行按 sessionId 过滤）
- `session.status` — `running` / `idle`
- `subagent.started` / `subagent.finished`

`sessionId` 由客户端生成；运行时不认识就**懒创建** agent+session，所以「新会话」不需要额外请求。

## 渲染的事件

事件信封是 `{type, seq, time, data}`——**字段在 `data` 里，不在顶层**。这一点已用真机同构的
Node 22 环境实测确认（读错层级会导致对话永远是空的）。

| 事件 | `data` 关键字段 | 处理 |
|---|---|---|
| `assistant/message` | `message.content[]` | 逐块展开：`text` → 气泡正文，`reasoning` → 「思考」标记，`tool_use` → 工具名 |
| `tool/call` | `name`, `arguments` | 一张工具卡：名字 + 参数前 160 字符 |
| `tool/result` | `reason.kind` | 一张结果卡 |
| `session/title` | `title` | 用运行时生成的标题替换本地推断 |
| `turn/end` | `reason.kind` | 结束 running，落盘 |

## 验证记录（2026-10-25）

在 macOS + Node 22.22.2 上用同一份载荷跑通了完整一轮：

```
initialize          → {"serverInfo":{"name":"deepseek-harness-sdk-runtime","version":"0.0.1"}}
session/prompt      → {"messageId":"4f308206-…"}
session.event × 18  → permission/preset, sandbox/mode, approval/policy, agent/inbox/spliced,
                      turn/start, step/start, system/message, user/message, request/header,
                      request/context, session/title, assistant/message, step/end, turn/end
assistant/message   → content: [{type:"reasoning",text:""}, {type:"text",text:"1+1等于2。"}]
session.status      → running → idle
```

两条从实测里得到的结论：

1. **`session/prompt` 必须等 `initialize` 的响应返回后再发**，否则回
   `-32603 "SDK server is not initialized"`。`DshClient.initialize()` 是 `await` 的，UI 也是
   `READY` 之后才允许发送，符合要求。
2. **空 `reasoning` 块很常见**（`text: ""`），渲染层必须跳过，否则每条消息都会多一个「思考」标记。

## 平台硬约束与对策

| 约束 | 后果 | 本项目的对策 |
|---|---|---|
| 禁止 fork/exec | 不能 `spawn('node')`、不能跑 `git`/`ripgrep` 二进制 | 同进程 Node + SDK 协议；工具面受限于纯 JS 实现 |
| `node::Start()` 每进程一次 | Node 崩了不能原地重启 | `failed` 视为终态，UI 明示「需重启应用」；诊断面板给 stage/日志/崩溃记录 |
| JIT 需 `ALLOW_WRITABLE_CODE_MEMORY`（受限 ACL） | 无权限则 JIT 直接 SIGTRAP | 默认 `--jitless`，零受限权限安装 |
| jitless ⇒ `WebAssembly === undefined` | undici 的 llhttp(WASM) 失效，`fetch` 全挂 | `fetch-shim.cjs`：纯 JS fetch + `undici` 模块别名 + Agent 桩 |
| 原生二进制须在自身签名域 | `.node` 原生模块、node-pty、koffi 不可用 | 装配时 `npm install --omit=optional`，从源头不打包 |
| 单 HAP 多形态 | 手机/平板/2in1 共用 | 840vp 断点：窄屏单栏，宽屏「会话栏 + 对话」 |

## 已知边界（诚实清单）

- **没有 token 级流式**：SDK 协议只在一步结束时发 `assistant/message`，不发增量。UI 用
  `session.status` 显示「正在执行」。想要逐字流式，得改走 dsh 的 Web WS 协议（那是另一套、且面向浏览器信任域）。
- **工具面取决于载荷**：没有 `git`/`rg` 二进制，`bash` 类工具在纯 JS 兜底前不可用。
- **会话续接是本地账本**：运行时侧 `sessionId` 懒创建，本项目用自己的本地索引做「历史会话」列表与回放，
  不复用 dsh 的会话存储格式。
- **密钥在 HAP 内**：`rawfile/secrets.json` 会被打进安装包，只适合自用/内测；正式分发应改为首次启动手填
  或服务端换发短期凭证。
