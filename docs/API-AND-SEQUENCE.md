# API 与时序（2026-11-19）

> 回答两个问题：**这个项目现在实现了什么**、**有没有 API 文档和时序图**。
> 结论先说：**功能有，内部模块 API 有，但从来没有一份集中写的 API 文档；时序图只有
> `ARCHITECTURE.md` 里那段 ASCII 的启动步骤，没有可渲染的图。本文补齐这两样。**
>
> 现有文档的分工：`ARCHITECTURE.md`（分层与协议面）、`BOOT.md`（启动链路到函数级）、
> `SPIKE-ACP.md`（ACP 实测矩阵）、`DSH-GO-PARITY-V2.md`（对外能力对照）。
> 本文是**接口清单 + 时序图**，不重复它们的叙述。

---

## 一、实现了什么（按能力域）

| 域 | 已实现 | 代码位置 |
|---|---|---|
| **运行时** | 载荷解包 → dlopen `libnode.so` → 同进程 Node v24.2.0 → 回环 TCP 桥 → dsh | `host/NodeHost.ets`、`host/Payload.ets`、`host/bootstrap.cjs` |
| **协议** | ACP（9 方法，默认路径）+ SDK（5 方法，legacy）双 profile，可在设置里切 | `model/AcpClient.ets`、`model/DshClient.ets` |
| **对话** | 流式回答/思考、工具轨迹（6 类 + 子代理）、排队插话、引用、重答、停止 | `pages/Index.ets`、`view/ChatView.ets` |
| **投影** | 待办、目标、上下文占用、每轮 token、子代理计数（全部从 `tool_call` 反推，无协议改动） | `model/TodoModel.ets`、`GoalModel.ets`、`Usage.ets` |
| **会话** | 新建/切换/删除/重命名、项目分桶、搜索（标题 + 缓存转录）、置顶/归档/多选/未读 | `model/ChatModel.ets`、`view/SessionRail.ets` |
| **产物** | 文件 chip、产物面板、内嵌预览、全屏查看、存相册、分享卡、Markdown 导出 | `view/FileViewer.ets`、`common/Gallery.ets`、`ShareCard.ets`、`model/Export.ets` |
| **回撤** | 每轮文件快照 → 恢复到该轮之前（含删除该轮新建的文件） | `model/Rollback.ets` |
| **外观** | 明暗三档（启动期应用）、字号四档、六套强调色 | `common/Theme.ets`、`Typography.ets`、`common/AppConfig.ets` |
| **系统** | 通知、桌面快捷方式、语音输入/朗读（引擎缺包时降级）、本地模型扫描、密钥热更新 | `common/Notify.ets`、`Speech.ets`、`ReadAloud.ets`、`LocalModel.ets` |
| **互联** | 同一 WiFi 直连（TCP）、WebSocket 中继、剪贴板、星闪/数据代理探针 | `common/Interop.ets`、`view/InteropSheet.ets` |

代码量：`entry/src/main/ets` 下 **42 个 `.ets`，15,447 行**。

---

## 二、对外 API（协议面）

### 2.1 ACP（默认路径，`DSH_PROFILE=acp`）

客户端 → 运行时：

| 方法 | 入参 | 出参 | 备注 |
|---|---|---|---|
| `initialize` | `{protocolVersion:1, clientCapabilities}` | `{protocolVersion, agentInfo, agentCapabilities, authMethods}` | 可重复调用（重连后再发一次不报错） |
| `session/new` | `{cwd, mcpServers}` | `{sessionId, configOptions}` | 服务端生成 id |
| `session/resume` | `{sessionId, cwd, mcpServers}` | 同上 | 对活跃会话报 `session is already active` |
| `session/list` | — | 已关闭/已持久化会话 | 活跃会话不在其中 |
| `session/close` | `{sessionId}` | — | 关闭后才进 list |
| `session/prompt` | `{sessionId, prompt:[{type:'text',text}]}` | `{stopReason}` | 一次只允许一轮；inflight 时拒绝 |
| `session/set_config_option` | `{sessionId, configId, value}` | `{configOptions}` | `model` 的 value 是 **JSON 数组字符串** |
| `session/cancel` | `{sessionId}` | **无响应（通知）** | 当请求发会 `Method not found` |

服务端 → 客户端：

| 通知/请求 | 载荷 | 客户端处理 |
|---|---|---|
| `session/update` | `agent_message_chunk` / `agent_thought_chunk` / `tool_call` / `tool_call_update` / `usage_update` | `Index.handleAcpUpdate` |
| `session/request_permission` | 两选项 `allow-once` / `reject-once` | 审批弹窗；不答 → 工具 fail-closed |

**客户端封装**（`model/AcpClient.ets`）：

```ts
connect(port) / initialize() / sessionNew(cwd) / sessionResume(id, cwd)
sessionPrompt(id, text) / sessionPromptBlocks(id, blocks) / sessionCancel(id)
sessionClose(id) / setConfigOption(id, configId, value) / respondPermission(id, optionId)
getState() / getServerInfo() / getImagePrompts() / close()
// 回调：onUpdate / onPermission / onDisconnect
```

### 2.2 SDK（legacy，`DSH_PROFILE=sdk`）

5 个请求 + 4 个通知，见 `ARCHITECTURE.md` §协议面。差异：`session.event` 是**全运行时**事件流（客户端按
`sessionId` 过滤），且没有审批通道。

---

## 三、内部模块 API（导出符号）

纯函数为主的模块（都有单测覆盖）：

| 模块 | 主要导出 |
|---|---|
| `model/Protocol.ets` | `encodeRequest`、`decodeFrame`（SDK 帧编解码） |
| `model/AcpProtocol.ets` | 34 个：`encodeNotification`、`findConfigOption`、`flattenChoices`、`textOfUpdateContent`、`toolTextOfUpdateContent`… |
| `model/TodoModel.ets` | `isTodoTool`、`todosFromJson`、`todosFromRaw`、`completedCount`、`activeTodo`、`todoSummary` |
| `model/GoalModel.ets` | `isGoalTool`、`goalFromJson`、`goalStatusLabel`、`goalSettled` |
| `model/Usage.ets` | `dayKey`、`mergeUsage`、`usageTotal`、`compactCount` |
| `model/Rollback.ets` | `isWriteTool`、`writePathsOf`、`SnapshotStore`、`FileChange`、`FileTouch`、`RollbackReport` |
| `model/Export.ets` | `exportFileName`、`transcriptMarkdown` |
| `common/SecretMask.ets` | `hasSecret`、`maskSecrets`、`secretCount` |
| `common/Typography.ets` | `fontScaleOf`、`fontIdOf`、`scaled`、`FONT_LEVELS` |
| `common/Theme.ets` | `accentOf`、`themeIdOf`、`themeLabelOf`、`ACCENTS` |
| `common/TimelineNode.ets` | `toolKindOf`、`kindVerb`、`kindAccent`、`kindGlyph`、`statusLabel`、`NodeKind` |
| `common/Interop.ets` | `makeEnvelope`、`encodeEnvelope`、`decodeEnvelope`、`takeLines`、`keepRemainder`、`probeChannels`、`LanChannel`、`WebSocketChannel`、`ClipboardChannel`、`probeNearLink`、`probeDataShare` |
| `common/WorkspaceFiles.ets` | `listWorkspaceFiles`、`matchWorkspaceFiles` |
| `common/AppConfig.ets` | `load`、`save`、`saveAccent`、`saveAppearance`、`saveFontLevel`、`applyAppearanceAtBoot` |
| `view/ChatView.ets` | `refsFromText`、`segmentsOf`、`renderBlocks` |

---

## 四、时序图

### 4.1 冷启动

```mermaid
sequenceDiagram
    participant U as 用户
    participant A as EntryAbility
    participant I as Index.ets
    participant P as Payload
    participant N as NodeHost
    participant B as bootstrap.cjs
    participant D as dsh (ACP)

    U->>A: 点图标
    A->>A: AppConfig.applyAppearanceAtBoot()（读 preferences，决定明暗）
    A->>I: loadContent('pages/Index')
    I->>P: ensure()
    P->>P: rawfile zip → 沙箱 → zlib 解包（按归档长度幂等）
    P-->>I: 载荷就绪
    I->>N: boot()
    N->>N: 投递 detached pthread（UI 线程不能调 node::Start）
    N->>B: node::Start(bootstrap.cjs)
    B->>B: 十个垫片（fetch-shim / link-fallback / chmod …）
    B->>B: 监听 127.0.0.1:4517，**等客户端连入才启动 dsh**
    I->>B: TCP connect(4517)
    B->>D: runCli(--profile ohos)
    I->>D: initialize
    D-->>I: agentInfo
    I->>I: phase = READY
```

### 4.2 一轮对话（ACP）

```mermaid
sequenceDiagram
    participant U as 用户
    participant I as Index.ets
    participant C as AcpClient
    participant D as dsh
    participant V as ChatView

    U->>I: 输入并发送
    alt 有回合在跑
        I->>I: enqueue()（排队，不打断）
    else 空闲
        I->>I: beginTurn()：建 assistant 行
        I->>C: sessionPrompt(sessionId, text)
        loop 流式
            D-->>C: session/update: agent_thought_chunk
            C-->>I: onUpdate
            I->>I: queueAcpUpdate()（60ms 批量）
            I->>V: 刷新「思考」行
            D-->>C: session/update: tool_call / tool_call_update
            C-->>I: onUpdate
            I->>I: refreshTodos() / refreshGoal()（从 rawInput 反推）
            D-->>C: session/update: usage_update
            I->>I: 注记「上下文 X/Y · 本轮 +N」，写 Usage 账本
            D-->>C: session/update: agent_message_chunk
            I->>V: 正文增量
        end
        D-->>C: session/prompt 响应 {stopReason}
        I->>I: turnInFlight = false
        I->>I: settlePersist()：先 drainAcpUpdates() 再 persist()
        Note over I: 顺序是刻意的——先存会把「还没有回复行」的状态写进去（曾导致重启丢回复）
        I->>I: flushQueue()（若有排队）
    end
```

### 4.3 审批

```mermaid
sequenceDiagram
    participant D as dsh
    participant C as AcpClient
    participant I as Index.ets
    participant U as 用户

    D-->>C: session/request_permission {id, options[allow-once, reject-once]}
    C-->>I: onPermission(request)
    I->>U: 弹审批层（选项来自服务端，不硬编码）
    alt 用户点允许
        U->>I: allow-once
    else 用户点拒绝
        U->>I: reject-once
    else 用户不管
        Note over D: 工具 fail-closed（不会自动放行）
    end
    I->>C: respondPermission(id, optionId)
    C->>D: 响应
```

### 4.4 断线重连

```mermaid
sequenceDiagram
    participant C as AcpClient
    participant I as Index.ets
    participant D as dsh

    C-->>I: onDisconnect(reason)（error/close 只报一次）
    I->>I: 退避 120s ×2，cap 300s，最多 6 次
    I->>C: connect(4517)
    I->>C: initialize（幂等）
    alt 断线时没有在跑的回合
        I->>D: 直接对旧 sessionId 继续 prompt
    else 有孤儿回合
        I->>D: session/close（掐掉孤儿轮）
        I->>D: session/resume
        I->>I: 把那条消息标「已中断」，由用户决定是否重发
    end
```

### 4.5 互联：同一 WiFi 直连

```mermaid
sequenceDiagram
    participant A as 设备 A（房主）
    participant B as 设备 B（客人）

    A->>A: LanChannel.host()：TCPSocketServer.listen(0.0.0.0:4518)
    A->>A: localLanAddress() → 显示「192.168.x.y:4518」
    A-->>B: 口头/剪贴板告诉对方地址
    B->>B: LanChannel.join(地址)：TCPSocket.connect
    A->>A: on('connect') → 记下连接
    B->>A: {"v":1,"id":…,"from":"…","at":…,"text":"…"}\n
    A->>A: takeLines() 切帧 → decodeEnvelope() → 入日志
    A->>B: 回一条（同信封）
    Note over A,B: 一对一；明文；退出面板即 close()
```

### 4.6 语音输入（含降级）

```mermaid
sequenceDiagram
    participant U as 用户
    participant V as ChatView
    participant S as Speech.ets
    participant K as CoreSpeechKit

    V->>V: canIUse('SystemCapability.AI.SpeechRecognizer')?
    alt 没有 syscap
        Note over V: 不渲染麦克风按钮
    else 有
        V->>V: 渲染麦克风
        U->>V: 点麦克风
        V->>S: startListening()
        S->>K: createEngine()
        alt 引擎可用
            K-->>S: 识别结果
            S-->>V: 填入输入框
        else createEngine 失败（1002200001，缺离线语音包）
            S->>S: 写 speech_asr_usable=false
            V->>V: 隐藏麦克风
            V->>U: toast「语音引擎启动失败：可能缺少离线中文语音包」
            Note over U: 设置页出现「重试」入口，装好语音包后不用重装 App
        end
    end
```

---

## 五、文档缺口（诚实清单）

| 缺什么 | 现状 |
|---|---|
| **可渲染的时序图** | 本文首次提供（mermaid）。此前只有 `ARCHITECTURE.md` 的 ASCII 步骤 |
| **集中的 API 参考** | 本文首次提供模块级清单；此前只有 `ARCHITECTURE.md` 的协议表和 `.d.ts` 级的类型 |
| **`ARCHITECTURE.md` 已过时** | 它把 SDK 写成主路径（2026-10 口径），现在默认是 ACP。**读协议请看 §2.1 与 `SPIKE-ACP.md`** |
| **无 OpenAPI / 无代码内 TSDoc 生成** | ArkTS 没有成熟 doc 生成链，接口说明只能手写（即本文） |
