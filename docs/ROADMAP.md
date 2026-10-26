# dsh on HarmonyOS — 落地与演进方案

> 基线时间：2026-10-25 16:10。以下判断全部来自真机实测，不是推演。

---

## 0. 实测基线

| 项 | 实测值 |
|---|---|
| 设备 | `9CY0226920012881`（HarmonyOS 7 / API 26） |
| 应用 | `com.example.dshharmony`，已签名安装并运行 |
| 后端 | `node v24.2.0` / `platform: openharmony` / `arch: arm64` / `wasm: false`（jitless） |
| 桥 | `127.0.0.1:4517`，`state: running`，`error: null` |
| 协议 | SDK JSON-RPC（`--profile sdk`） |

**已在真机上跑通的能力**（有实物证据）：

- 会话持久化：`dsh-home/sessions/<workspace>/<uuid>/session.v4.jsonl.zstd`，多个会话目录
- 文件工具真实写盘：`files/workspace/index.html`（4.1 KB）、`stardust.html`（23.7 KB）——agent 在手机上真的产出了文件
- 载荷解包幂等：`payload.stamp` + 156 MB `dsh-payload.zip`
- 崩溃兜底：`node-bridge` 的 SIGSYS 自检、`last-crash.json` 通道可用

**本轮修掉的两个真实缺陷**：

1. **补丁打过头**：早期 `ohos.patch.yml` 同时禁用了 `subprocess`、`bash-sandbox`、`tool-bash`，
   导致 `permission`（权限门）、`tool-fs-search`、`ptc-runtime`、`workflow` 共 5 个插件未激活。
   本地对比实验：不加补丁 0 未激活，加旧补丁 5 未激活。收窄补丁后**真机日志确认 0 未激活**。
   → 原则：**只禁用户级工具，不动服务级行**。
   → 2026-10-26 补测：单独禁 `tool-bash` 是安全的（0 未激活，permission 正常）；罪魁是
   `subprocess`（带走 fs-search/ptc/workflow）与 `bash-sandbox`（带走 `shell` 服务）。
2. **fetch shim 自触发内置 undici**：`install()` 里 `typeof globalThis.fetch` 和给
   `Headers/Response/Request` 赋值会materialize Node 的惰性 web 全局，进而初始化内置 undici
   （llhttp 是 WASM）→ `ReferenceError: WebAssembly is not defined`。
   改为**只用 `defineProperty` 接管 `fetch`**，实测 `fetch` 可用（`ECONNREFUSED` = 真网络栈），
   且不再自触发。

**仍存在**：启动期偶发一条 `unhandled rejection: WebAssembly is not defined`（来自 Node 内置
undici 的某条内部路径，已被 `bootstrap.cjs` 的 handler 捕获，不影响运行）。下一轮用
`Module._load` 追踪定位，或直接把触发它的那条 dsh 行禁掉。

---

## 1. 阶段 0：立刻可做的落地动作

### 1.1 真机验收清单（每次发版都跑一遍）

| # | 操作 | 期望 | 失败时看 |
|---|---|---|---|
| 1 | 冷启（先 `aa force-stop`） | ≤ 8 s 进入聊天界面（已解包时） | `node.log` 尾部、诊断页 `stage=` |
| 2 | 首次安装后首启 | 60–75 s 内完成解包并 ready | `payload.stamp`、`payload.zip` 大小 |
| 3 | 发一条纯文本 | 收到 assistant 回复 | `session.event` 是否有 `assistant/message` |
| 4 | 让它建一个文件 | `workspace/` 出现新文件 | `tool/call` / `tool/result` 事件 |
| 5 | 杀进程再进 | 历史会话可回看 | `SessionStore` 的 preferences |
| 6 | 断网发消息 | 明确报错，不静默卡死 | `session/prompt` 是否超时 |
| 7 | 后台 10 分钟再回来 | 桥仍 `running`，可继续对话 | `bridge-status.json` 时间戳 |
| 8 | 反复切会话 | 不串消息（按 sessionId 过滤生效） | 事件是否带错 sessionId |
| 9 | 大图/长文输入 | 不 OOM（jitless 下内存更紧） | `node.log` 是否 `heap out of memory` |
| 10 | 升级 dsh 版本 | 只换载荷，App 代码不动 | `payload.stamp` 变化后是否重新解包 |

### 1.2 日常开发循环

```bash
# 1) 改代码（host/ 或 entry/src/main/ets/）
# 2) 只重打包载荷（约 30 s）
node scripts/assemble-payload.mjs --skip-install --staging .build/payload-b

# 3) 构建（约 35 s，含 273 MB 打包）
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"
hvigorw --mode module -p product=default assembleHap --no-daemon

# 4) 安装并拉起
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa force-stop com.example.dshharmony
hdc shell aa start -a EntryAbility -b com.example.dshharmony
```

只改 ArkTS（不动载荷）时可跳过第 2 步，构建约 35 s。
`.hvigor/.build-lock` 每次失败会残留，导致下次 `EEXIST`，清掉即可。

### 1.3 故障处置速查

| 现象 | 最可能原因 | 处置 |
|---|---|---|
| 卡「等待 Node 主循环就绪」 | `dlopen`/`dlsym` 失败 | 看 `node.log` 的 `stage=`；确认 `libnode.so` 在 `libs/arm64` |
| 卡「与 dsh 会话服务握手」 | 某插件行 mount 失败 | 看 `did not activate` 行；收窄/扩展补丁 |
| 发消息后无回复 | `session/prompt` 未被处理 | 确认 `initialize` 已返回（必须先 initialize） |
| 网络类工具失败 | fetch 被内置 undici 抢走 | 确认日志有 `esm: undici resolve hook registered` |
| 装不上 | 签名 profile 没含设备 UDID | 连设备后 `devecocli signature generate --force` |
| 装完闪退 | 未申请必要权限 | `module.json5` 的 `requestPermissions` |

---

## 2. 阶段 1：让工具真正可用（1–2 天，收益最大）

当前 SDK 协议**没有审批通道**，而 `user-approval` 的语义是「无 answerer → `unavailable` →
动作 fail closed」。也就是说现在需要人工确认的工具会直接失败，不是等人点。

### 2.1 后端切到 ACP profile

- **改哪里**：`host/bootstrap.cjs` 的 `--profile sdk` → `acp`；新建 `model/AcpClient.ets`（**不删** `DshClient.ets`，保留 SDK 回退）
- **协议差异**（方法名已由 spike 实测校正，详见 `docs/SPIKE-ACP.md`）：
  | 用途 | ACP 方法（线上实际字符串） |
  |---|---|
  | 建会话 | `session/new`（sessionId **服务端生成**） |
  | 发消息 | `session/prompt` |
  | 取消 | `session/cancel` |
  | 列/恢复会话 | `session/list`、`session/resume` |
  | 切模型/推理强度 | `session/setConfigOption`（`model`、`reasoning_effort`） |
  | 流式更新 | 通知 `session/update`（`agent_message_chunk` / `agent_thought_chunk` / `tool_call` / `tool_call_update` / `usage_update`） |
  | 权限 | 服务端请求 **`session/request_permission`**，选项固定 `allow-once` / `reject-once` |
- **验收**：能收到 `agent_message_chunk`（流式）、能弹出并回答权限请求、能取消
- **风险**：ACP 明确不提供 plan / goal / todo / elicitation / 终端视图——这些功能要另做

### 2.2 审批 UI

- 新增 `view/ApprovalSheet.ets`：展示工具名、参数摘要、三个按钮（允许 / 本次会话允许 / 拒绝）
- `DshClient` 增加「服务端反向请求」处理分支（当前只处理 `id` 响应与通知）
- **验收**：让 agent 做一个需要确认的动作，能弹窗并据此放行/拒绝

### 2.3 流式渲染

- `ChatMessage` 增加 `streaming: boolean`；收到 `agent_message_chunk` 追加到当前气泡，`turn/end` 置 false
- 注意 ArkUI 高频 setState：用 50–80 ms 节流合并增量，否则掉帧
- **验收**：文字逐字出现，滚动跟随

### 2.4 取消

- 输入区旁加「停止」按钮 → `session/cancel`
- **验收**：长任务中途可停，`session.status` 回到 idle

---

## 3. 阶段 2：体验补齐（3–5 天）

| 项 | 做法 | 依赖 | 验收 |
|---|---|---|---|
| 会话列表/恢复 | `session/list` 填 `SessionRail`；点击 `session/load` | ACP | 冷启后能看到并恢复历史 |
| 工具卡 | `tool_call` 渲染成卡片，`tool_call_update` 更新状态（运行中/成功/失败） | ACP | 一次多工具调用可读 |
| 拍照/附件 | `picker` 选图 → base64 → ACP prompt 的 image block | ACP | 发一张图模型能描述 |
| 文件树 | 直接读沙箱 `workspace/`（**不用协议**） | ArkTS fs | 能看到 agent 新建的文件 |
| 文档预览 | Markdown/代码/图片用 ArkUI 渲染 | ArkTS | 点开 `.md`/`.html` 可读 |
| 模型切换 | `session/set_model` + `session/set_mode` | ACP | 中途切模型不影响会话 |
| 权限预设 | 写 host 配置或用 side-channel | 自定义 RPC | 能在 read-only/workspace-write 间切 |

---

## 4. 阶段 3：差异化（1–2 周）

1. **定时任务 + 系统通知**：`ui-schedule` 的 host 服务不在任何协议里，需要 side-channel；
   配 `notificationManager` 做「跑完提醒」，这是手机上真正的杀手功能。
2. **side-channel**：在 `bootstrap.cjs` 的同一条 TCP 连接上加 `ohos/` 前缀方法
   （`ohos/fs.list`、`ohos/fs.read`、`ohos/settings.write`、`ohos/schedule.*`），
   帧格式仍是 JSON-RPC，与 dsh 协议帧并存——**不用等上游**。
3. **包体**：当前 273 MB（156 MB 载荷 + 122 MB `libnode.so`）。上架需 < 200 MB，可选：
   裁剪 `node_modules` 里用不到的平台二进制、按 ABI 拆包、或首启下载载荷。
4. **上架合规**：`secrets.json` 内置密钥不可上架；改为首启手填或服务端换发短期凭证。

---

## 5. 上下文指导

### 5.1 协议决策树

```
需要 DSH 特有卡片（plan/goal/todo/终端）？
├─ 是 → 只能用 Web API（浏览器信任域），代价是要实现整套 /api + WS
└─ 否 → 用 ACP
        ├─ 需要流式 + 审批 + 会话列表 → ACP（推荐）
        └─ 只要最简问答 → SDK（当前，但缺审批）
协议没覆盖的（文件树/定时/设置写入）→ 走自己的 side-channel
```

### 5.2 平台约束速查

| 约束 | 影响 | 现有对策 |
|---|---|---|
| 禁 fork/exec | 无 bash/PTY/pnpm/git | 纯 JS 工具 + 补丁禁用 spawn 类行 |
| `node::Start` 每进程一次 | 崩了只能重启 App | 状态机 `failed` 即终态，UI 明示 |
| JIT 需 ACL | 默认 `--jitless` | `wasm:false`，fetch 走纯 JS 垫片 |
| 只执行签名域内代码 | `.node` 原生模块不可用 | 不打包原生依赖，`--ignore-scripts` 装配 |
| 禁硬链接 | dsh 原子发布失败 | `bootstrap.cjs` 的 `installLinkFallback`（link→copyFile+EXCL） |
| 无 `ps`（部分环境） | devecocli 探内存崩 | 桩脚本或跳过 CLI 构建 |

### 5.3 调试三件套

```bash
# 1) 后端日志（最有信息量）
hdc shell tail -50 /data/app/el2/100/base/com.example.dshharmony/haps/entry/files/node.log

# 2) 桥状态
hdc shell cat /data/app/el2/100/base/com.example.dshharmony/haps/entry/files/dsh-home/bridge-status.json

# 3) 应用内 设置 → 诊断（phase / stage / node.log 尾 120 行 / 崩溃记录）
```

应用沙箱根：`/data/app/el2/100/base/com.example.dshharmony/haps/entry/files/`

### 5.4 性能预算

| 指标 | 当前 | 目标 |
|---|---|---|
| 首启（需解包） | 60–75 s | ≤ 30 s（流式解包 / 预置） |
| 冷启（已解包） | ~3 s | ≤ 2 s |
| HAP | 273 MB | ≤ 200 MB（上架） |
| 空闲内存 | 未测 | 建议实测，jitless 下堆更紧 |

### 5.5 代码地图

| 路径 | 职责 |
|---|---|
| `host/bootstrap.cjs` | TCP 桥、stdio 劫持、启动 dsh、状态落盘 |
| `host/fetch-shim.cjs` | jitless 下的纯 JS fetch（只接管 `fetch`） |
| `host/undici-esm.mjs` / `undici-hooks.mjs` | ESM 侧 `undici` 别名 |
| `host/require-builtin-shim.cjs` | `node-addon-require-builtin` 替代（`--expose-internals`） |
| `host/patches/ohos.patch.yml` | 平台补丁（当前最小集） |
| `ets/host/NodeHost.ets` | 载荷物化 → 起 Node → 连接 → 握手 |
| `ets/host/Payload.ets` | rawfile 分块解包 + 幂等标记 |
| `ets/model/DshClient.ets` | JSON-RPC 分帧、请求配对、事件分发 |
| `ets/model/Protocol.ets` | 协议类型（信封 `{type,seq,time,data}`） |
| `ets/model/ChatModel.ets` | 消息模型 + 会话持久化 |
| `ets/pages/Index.ets` | 三形态断点 + 事件→UI 映射 |
| `scripts/assemble-payload.mjs` | 装配载荷（npm → zip） |
| `scripts/deploy.sh` | 登录 → 签名 → 构建 → 装机 |

### 5.6 升级 dsh 版本

```bash
node scripts/assemble-payload.mjs --dsh-version <ver>   # 重新装配（会重装依赖，约 15 min）
# 检查 --dump-config 的行 id 是否变化（补丁依赖 id）
node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile sdk --dump-config | grep '^- id:'
```

App 代码不需要改：载荷版本与 App 解耦，`payload.stamp` 变化会自动重新解包。
