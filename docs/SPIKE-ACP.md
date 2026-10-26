# ACP Spike 报告

> 执行时间：2026-10-25 16:51–16:53。环境：macOS + Node 22.22.2 + 同一份载荷
> （dsh 0.2.1-rc.2，614 包）。方式：**进程内** PassThrough 劫持 stdio，与
> `host/bootstrap.cjs` 完全同构，**零 spawn**。

## 结论：通过。ACP 可作为下一阶段协议，但有三处口径要改。

---

## 1. 验证矩阵

| 项 | 方法（线上实际字符串） | 结果 | 证据 |
|---|---|---|---|
| 进程内可跑，无子进程 | — | ✅ | 脚本只 `import(bin.js)` + `runCli()`，全流程无 spawn |
| 流可注入 | — | ✅ | `PassThrough` 分别接管 `process.stdin/stdout`，dsh 无感知 |
| 握手 | `initialize` | ✅ | `{"protocolVersion":1,"agentInfo":{"name":"deepseek-harness-acp","version":"0.0.1"}}` |
| 建会话 | `session/new` | ✅ | 返回**服务端生成** `sessionId: ecf7fff8-…` + `configOptions` |
| 列会话 | `session/list` | ✅ | `{"sessions":[]}` |
| 恢复会话 | `session/resume` | ✅ | 传 `{sessionId, cwd, mcpServers}` 返回 configOptions |
| 发消息 | `session/prompt` | ✅ | `{"stopReason":"end_turn"}` |
| 流式 | 通知 `session/update` | ✅ | 依次收到 `agent_thought_chunk` → `usage_update` → `tool_call` → `tool_call_update` → `agent_message_chunk`（chunk 文本 `"完成"`） |
| 审批 | **`session/request_permission`** | ✅ | 见 §2 |
| 审批放行后工具继续 | — | ✅ | 答 `allow-once` 后 `tool_call_update: status=completed` |
| 审批答错即失败 | — | ✅ | 回 `{}` 时 `status=failed`（fail-closed，不是 hang） |
| 取消 | `session/cancel`（**通知，无 id**） | ✅ | 发出后 prompt 响应 `{"stopReason":"cancelled"}`，之后 0 条 update；作为**请求**发送则 `Method not found` |
| 切配置 | `session/set_config_option` | ✅ | `setConfigOption` / `set_model` / `set_mode` 均 `Method not found`；`model` 的 value 是 JSON 数组字符串 |
| 真机（arm64/jitless） | — | ✅ | fport 矩阵 2026-10-26（§9）：14 项实机通过，审批放行后文件真实落盘 |

---

## 2. 审批路径（最关键的一条）

线上实际报文：

```json
{"jsonrpc":"2.0","id":3,"method":"session/request_permission","params":{
  "sessionId":"8e606d46-f994-46c5-a380-090a120dbbd5",
  "toolCall":{"toolCallId":"call_00_IiVFphxLZKNghqwVWkpK6215"},
  "options":[
    {"optionId":"allow-once","name":"Allow once","kind":"allow_once"},
    {"optionId":"reject-once","name":"Reject","kind":"reject_once"}
  ]}}
```

应答：

```json
{"jsonrpc":"2.0","id":3,"result":{"outcome":{"outcome":"selected","optionId":"allow-once"}}}
```

**三处需要改口径**：

1. **方法名是 `session/request_permission`（下划线），不是 `requestPermission`**。
   按 ACP 规范写 camelCase 会匹配不上，运行时把空应答当成拒绝 → 工具 `failed`。
   这是本次 spike 实际踩到的坑（第一轮 `permissionAsked=0` 且工具失败）。
2. **选项固定两键**：`allow-once` / `reject-once`（与代码核实一致），没有 always。
3. **不做 UI 的后果是 `failed`，不是 hang**——`user-approval` 的 fail-closed 语义在 ACP 下同样成立，
   所以审批 UI 是主路径的一部分。

---

## 3. `configOptions`（服务端权威，替代自造模型列表）

`session/new` 与 `session/resume` 都返回：

| id | category | currentValue | 选项 |
|---|---|---|---|
| `model` | `model` | `["deepseek-official","deepseek-v4-flash"]` | deepseek-v4-flash / deepseek-flash（DeepSeek-V4.1-Flash）/ deepseek-v4-pro |
| `reasoning_effort` | `thought_level` | `high` | off / low / … / high |

→ 客户端不要再硬编码模型；直接渲染 `configOptions`，用 **`session/set_config_option`**
（`{sessionId, configId, value}`）改，响应里带回新的 `configOptions`。

**value 的格式是个坑**：`model` 的 `value` 是 **JSON 数组字符串**，不是对象——

```json
{"jsonrpc":"2.0","id":9,"method":"session/set_config_option","params":{
  "sessionId":"…","configId":"model","value":"[\"deepseek-official\",\"deepseek-v4-pro\"]"}}
```

实测把 `value` 传成对象或只传模型名，调用会返回 200 但 `currentValue` 不变（静默失败）。
传上面的字符串后 `currentValue` 确实变为 `["deepseek-official","deepseek-v4-pro"]`。

---

## 4. 审批策略由环境变量决定（影响 bootstrap）

`--dump-config` 显示：

```yaml
- id: sandbox-policy
  config:
    mode: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write'
    workspaceRoot: !!js process.cwd()
- id: approval
  config:
    policy: !!js (process.env.DSH_PERMISSION_MODE ?? 'workspace-write') === ...
```

实测行为（dsh 具名预设表：read-only / workspace-write / danger-full-access）：

- `DSH_PERMISSION_MODE=workspace-write`（默认）→ 工作区内直写**不问**；越区升级触发 `session/request_permission`
- `DSH_PERMISSION_MODE=read-only` → 裸写先被沙箱拒（`file access denied under read-only mode`，
  无审批请求），agent 带 `sandbox_permissions:"workspace-write"`+`justification` 重试才触发审批
- `DSH_PERMISSION_MODE=danger-full-access` → 全放行，审批策略 `never`，零弹窗（平板真机闭环）

→ bootstrap 暴露 `DSH_PERMISSION_MODE` 即可做成「权限档位」设置项，不必自定义协议。
档位随会话创建固化（session log 即写 preset/mode/policy），切档只影响新会话。

---

## 5. 附带发现

- acp profile 里 `bash` 工具存在但**必然失败**（无 exec），表现为 `tool_call → status=failed`。
  这与 SDK 侧一致，属平台限制，不是回归。
- 会话 id 服务端生成 → 客户端 `SessionStore` 要改存服务端 id；`session/list` 支持按 cwd 过滤
  （= 按项目过滤的权威来源）。
- 同一 `DSH_HOME` 下 `session/list` 能跨进程看到历史，`resume` 用 `sameDirectory` 校验 cwd。

---

## 6. 未覆盖，切换前必须补测

> 2026-10-26 更新：下表前四行已在真机矩阵覆盖（见 §9）；本节剩余项为长任务保序与
> ArkTS 客户端接入。

| 项 | 状态 |
|---|---|
| `session/cancel` | ✅ 真机矩阵（§9）：通知形态，`stopReason:"cancelled"`，取消后 0 update |
| `session/set_config_option` | ✅ 真机矩阵 + 追加探测（§9.1）：含选项集收缩契约 |
| `session/close` | ✅ 真机矩阵（§9）：close → list 可见 → resume 成功 |
| 真机 arm64 + `--jitless` | ✅ 真机矩阵（§9）：流式/审批/取消与桌面一致 |
| 长任务下的 update 顺序 | ⚠️ 仍开放：矩阵 prompt 较短，`outputTail` 保序在长任务下未压测 |
| ArkTS 客户端（AcpClient）+ 审批 UI | ⚠️ 仍开放：下一阶段工作 |

---

## 7. 与旧文档的口径冲突（需同 commit 修正）

| 旧说法 | 实际 | 出处 |
|---|---|---|
| `session/set_model` | `session/set_config_option`（model 是其中一个 config） | §3 |
| `session/setConfigOption`（camelCase） | `session/set_config_option`（snake_case）；camelCase 报 `Method not found` | §3 |
| `session/load` | `session/resume` | §1 |
| `session/requestPermission` | `session/request_permission` | §2 |
| `session/cancel` 当请求发 | 它是**通知**（无 id）；当请求发报 `Method not found` | §1 |
| 「ACP 出局（需子进程）」 | 仅「宿主 spawn dsh」出局；ACP 服务器进程内可跑 | 本 spike 全程无 spawn |

> 教训：**这个实现的线上方法名全是 snake_case**，凡按 ACP 规范猜 camelCase 的都会 `Method not found`。
> 后续接任何新方法，先发一枪再写进客户端。

---

## 8. 桥集成：现有 bootstrap 不改也能承载 ACP

用**真实的 `host/bootstrap.cjs`**（未改一行）以 `DSH_PROFILE=acp` 启动，TCP 客户端按 ACP 说话：

```
status before connect: {"state":"listening",...}
initialize      → {"protocolVersion":1,"agentInfo":{"name":"deepseek-harness-acp",...}}
session/new     → sessionId=0eb2f9dc-… configOptions=2
agent_message_chunk: "桥通"
session/prompt  → {"stopReason":"end_turn"}
status after    → {"state":"running",...}
```

补丁（`ohos.patch.yml`）在 acp profile 下**无 "did not activate" 警告**，`boot: … runtime mounted`
正常写入。启动期同样有一条良性 `WebAssembly is not defined`（与 sdk 侧同源）。

### 8.1 断线重连契约（手机端必踩）

App 切后台会断 socket。实测（同进程、两次连接）：

| 行为 | 结果 | 客户端应怎么做 |
|---|---|---|
| 重连后再次 `initialize` | ✅ 幂等，正常返回 | 可以无条件重发 |
| 重连后对旧 `sessionId` 直接 `session/prompt` | ✅ `stopReason: end_turn` | **首选路径：直接续用，不 resume** |
| 重连后 `session/resume` 活跃会话 | ❌ `Invalid params: session is already active` | 把这条错误当成「已加载」，不要当失败 |
| `session/list` | 只列**已关闭/已持久化**会话；刚 `session/new` 的不在其中 | 活跃会话自己维护，列表只用于历史 |
| `session/close` | 返回 `{}`；之后该会话出现在 `session/list`，且可 `resume` | 退出项目/清理时调用 |

> 这一条直接决定 ArkTS 侧的重连逻辑：**先 prompt，失败再 resume**；而不是先 resume。
> 反过来写会在每次切后台回来后弹一个 `already active` 错误。

---

## 9. 真机矩阵（fport，2026-10-26）

设备 arm64 + `--jitless`（内嵌 Node 24.2.0），测试构建以 `DSH_PROFILE=acp` +
`DSH_PERMISSION_MODE=read-only` 停靠（App 客户端不 connectBridge），Mac 经
`hdc fport tcp:14517 tcp:4517` 直连桥驱动。14 项：13 过 + 1 项（3b flip-back）
判为新契约（§9.1），无客户端侧失败。

| # | 项 | 结果 |
|---|---|---|
| 1 | initialize | ✅ `deepseek-harness-acp v0.0.1` |
| 2 | session/new | ✅ 服务端生成 sessionId + configOptions |
| 3a | set_config_option 翻转 model | ✅ currentValue 随之更新 |
| 3b | set_config_option 翻回 | 见 §9.1：`-32602 unknown model option`（选项集收缩，非 bug） |
| 4a | prompt → end_turn | ✅ 含工具调用 |
| 4b | request_permission | ✅ read-only 下触发；答 `allow-once` 后工具真实写盘（25B 文件落 workspace，时间戳吻合） |
| 4c | 流式 update | ✅ 节奏与桌面一致（审批前 9 条；取消轮共 2 条） |
| 5a | cancel（通知） | ✅ `stopReason:"cancelled"` |
| 5b | 取消后 update 静默 | ✅ 0 条新增 |
| 6a | 断线重连 + initialize | ✅ 幂等 |
| 6b | 重连后对活跃会话直接 prompt | ✅ `end_turn`（不 resume） |
| 7 | session/close | ✅ `{}` |
| 8 | session/list 含已关会话 | ✅（4 个） |
| 9 | session/resume 已关会话 | ✅ |

### 9.1 set_config_option 选项集收缩（矩阵 3b 的解释）

连续两次 `session/set_config_option(model)`：翻转（`deepseek-v4-flash` → `deepseek-flash`）
成功后，**响应里的选项集少了一项**——`deepseek-v4-flash` 从菜单消失，只剩 flash /
v4-pro；再切回 v4-flash 被 `-32602 Invalid params: unknown model option` 拒绝。即：

- 响应的 `configOptions` 是**新的权威列表**，选择器不得缓存旧列表；
- 默认模型一旦切走，该会话无法切回（唯一途径是新建会话）；
- 客户端把 `-32602` 当「选项已不可用」处理（刷新列表），不是传输错误。

已同步至 `AGENTS.md` §4.2。

### 9.2 审批流客户端闭环与权限三档（2026-10-26）

App 客户端真机验证（手机 read-only 多轮 + 平板 danger-full-access 端到端），新契约：

- **升级审批流**：read-only 会话裸写 → 沙箱即时拒绝（附 escalation 提示，无审批请求）→
  agent 重试带 `sandbox_permissions`+`justification` → `session/request_permission`
  （reason=`escalate sandbox to workspace-write: ...`）→ 客户端应答 → 落盘。
- **档位快照**：会话创建即写 `permission/preset`/`sandbox/mode`/`approval/policy`，
  旧会话不随 env 变化；切档需重启 App 且仅新会话生效。
- **不答 = turn 无限挂起**：failopen 探针（外部连桥、故意不答）100s+ / 10+ 分钟无决定、
  文件不落盘；服务端无自动放行。
- **桥是单客户端**：新连接 `replacing previous client` 顶掉旧连接——外部探针实验后必须
  重启 App 恢复客户端连接（AcpClient 暂无重连）。
- 已知 UI 缺陷：审批弹窗渲染进 transcript 滚动流，自动滚动可将其推出视口（应改固定覆盖层）。

---

## 11. 断线时正在进行的一轮（决定重连怎么做）

问题：App 切后台断 socket 时如果正有一轮在跑，服务端会怎样？重连后能不能接着看？

实测（本地 Node 22 + 同载荷，`--jitless`）：

| 观察 | 结果 |
|---|---|
| 断线后该轮是否继续 | ✅ 继续跑（服务端不感知客户端消失） |
| 重连后的新连接能否收到它的 `session/update` | ✅ 能（15s 内收到 3 条：`agent_thought_chunk` / `agent_message_chunk` / `usage_update`） |
| 原连接的 `session/prompt` 响应 | ❌ **永久丢失**，客户端 promise 只能超时 |
| `session/update` 里能否区分轮次 | ❌ `{sessionId, update}`，**没有 turn/step/message id** |
| `session/close` 能否终止孤儿轮 | ✅ 能（close 后 0 条 update），之后 `session/resume` + `session/prompt` 均正常 |

结论：**重连后无法判断孤儿轮何时结束**——没有 turn/end 通知，也没有 id 可关联，`stopReason`
随响应帧一起丢了。因此「接着听」是伪方案。

### 推荐做法（重置语义）

断线重连后：

1. `initialize`（幂等）
2. `session/close`（把孤儿轮掐掉，避免幽灵输出）
3. `session/resume`（拿回 `configOptions`）
4. 把断线时那条用户消息标记为「已中断」，由用户决定是否重发

理由：确定性。代价是丢掉半截回答，但这比「界面永远转圈、且新回答可能被孤儿轮的 chunk 污染」
要好。观测式重连（保留流、等结束）不可行，因为结束信号不存在。

> 未测：对孤儿轮发 `session/cancel`（通知）是否也能终止。若可行，可做「保留半截 + 显式中断」，
> 但结束检测仍需客户端自己超时兜底。
