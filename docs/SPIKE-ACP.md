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
| 取消 | `session/cancel` | ⚠️ 未测 | 本轮没构造长任务 |
| 切配置 | `session/setConfigOption` | ⚠️ 未测 | 但 `configOptions` 已确认存在（见 §3），方法名按 ACP 规范 |
| 真机（arm64/jitless） | — | ⚠️ 未测 | 本 spike 只在桌面 Node 22 上跑 |

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

→ 客户端不要再硬编码模型；直接渲染 `configOptions`，用 `session/setConfigOption` 改。

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

实测行为：

- `DSH_PERMISSION_MODE=workspace-write`（默认）→ 写文件**不问**，直接完成（连写 `/tmp/outside-spike.txt` 也放行）
- `DSH_PERMISSION_MODE=read-only` → 写文件**触发** `session/request_permission`

→ bootstrap 暴露 `DSH_PERMISSION_MODE` 即可做成「权限档位」设置项，不必自定义协议。

---

## 5. 附带发现

- acp profile 里 `bash` 工具存在但**必然失败**（无 exec），表现为 `tool_call → status=failed`。
  这与 SDK 侧一致，属平台限制，不是回归。
- 会话 id 服务端生成 → 客户端 `SessionStore` 要改存服务端 id；`session/list` 支持按 cwd 过滤
  （= 按项目过滤的权威来源）。
- 同一 `DSH_HOME` 下 `session/list` 能跨进程看到历史，`resume` 用 `sameDirectory` 校验 cwd。

---

## 6. 未覆盖，切换前必须补测

| 项 | 为什么要补 |
|---|---|
| `session/cancel` | 手机端「停止」按钮的唯一手段 |
| `session/setConfigOption` | 模型/推理强度切换 |
| `session/close` | 会话生命周期收尾 |
| 真机 arm64 + `--jitless` | 本 spike 是桌面 Node；jitless 下流式与审批是否同样正常未验证 |
| 长任务下的 update 顺序 | `outputTail` 保序在真机高延迟下是否成立 |

---

## 7. 与旧文档的口径冲突（需同 commit 修正）

| 旧说法 | 实际 | 出处 |
|---|---|---|
| `session/set_model` | `session/setConfigOption`（model 是其中一个 config） | §3 |
| `session/load` | `session/resume` | §1 |
| `session/requestPermission` | `session/request_permission` | §2 |
| 「ACP 出局（需子进程）」 | 仅「宿主 spawn dsh」出局；ACP 服务器进程内可跑 | 本 spike 全程无 spawn |

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
