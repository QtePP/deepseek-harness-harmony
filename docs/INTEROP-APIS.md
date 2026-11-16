# 与其他应用 / 其他用户通信：能力盘点（2026-11-16）

> 问题：**当前这个 App 具备哪些「与其他应用交互」的 API / SDK，能用来和其他用户双向通信？**
> 结论都基于本机 SDK（API 26 / HarmonyOS 7.0.0）里真实存在的 `.d.ts` 与 `PermissionDefinitions.json`，
> 以及本仓代码里**已经在用**的导入。每条都标了权限级别——这是能不能落地的主要分水岭。

---

## 0. 一句话结论

**双向通信的底层我们已经有了**：`@ohos.net.socket` 的 TCP 长连接（现在连的是 `127.0.0.1:4517` 本地桥）+ `@ohos.net.http`。
缺的**不是 API，是对端**：

- 想「同 WiFi 两个人直连」→ 换一个地址就行，零服务端；
- 想「跨网络/跨账号」→ 必须有一个中继服务，鸿蒙自带的分布式能力**只在同一华为账号的可信设备之间**。

---

## 1. 已经在用的（代码里就在跑）

| API | 用途 | 方向 | 作用域 |
|---|---|---|---|
| `@ohos.net.socket`（TCPSocket） | 本地桥 `127.0.0.1:4517`，承载 ACP 的 JSON-RPC | **双向** | 本机 |
| `@ohos.net.http` | 模型 API、本地模型探测 | 请求-响应 | 公网 |
| `@kit.ShareKit` | 分享卡 / 文件给任意 App | 单向 | 本机 → 任意 |
| `@kit.NotificationKit` | 回合完成 / 待审批提醒 | 单向 | 本机 |
| Want / `startAbility` | 唤起其他 App、桌面快捷方式、文件预览 | 单向 | 本机 |
| `@kit.ArkWeb`（Web 组件） | 预览 HTML、内嵌网页 | 双向（页面内） | 本机 |

**关键点**：第一行就是「用户↔用户」缺的那块砖，只是目标地址写死成了 loopback。

---

## 2. SDK 里有、我们还没用、可用于双向通信

| API / Kit | 方向 | 作用域 | 权限（级别） | 限制 |
|---|---|---|---|---|
| `@ohos.net.webSocket` | **双向** | 公网（需自建服务） | `INTERNET`（normal） | **最省事的中继方案**；`connect/send/on('message')` 齐全 |
| `@ohos.net.socket`（TCPSocketServer + TCPSocket） | **双向** | 局域网 / 公网 | `INTERNET`（normal） | 局域网直连：一方 listen，另一方 connect |
| `@ohos.net.socket`（TLSSocket） | 双向加密 | 公网 | `INTERNET` | 自签证书要额外处理 |
| `@ohos.net.socket`（UDPSocket） | 双向（无连接） | 局域网 | `INTERNET` | 适合发现/广播，不适合传大包 |
| `@ohos.data.distributedDataObject` | **双向同步** | **同一华为账号的可信设备** | `DISTRIBUTED_DATASYNC`（user_grant / **normal**） | 解决「我自己的手机↔平板」，**不解决「和别的用户」** |
| `@ohos.data.distributedKVStore` | 双向同步 | 同上 | 同上 | 同上 |
| `@ohos.distributedDeviceManager` | 设备发现/认证 | 同账号 | `DISTRIBUTED_SOFTBUS_CENTER`（**system_basic**） | **三方应用拿不到**，只能被动读列表 |
| `@ohos.bluetooth.ble` | 双向 | 近场（十米级） | `ACCESS_BLUETOOTH`（user_grant / **normal**） | 双方都要装 App；带宽小，适合配对/握手 |
| `@ohos.bluetooth.socket`（SPP） | 双向流 | 近场 | 同上 | 经典蓝牙串口，比 BLE 带宽大 |
| `@hms.nearlink.*`（星闪） | 双向 | 近场 | 视机型 | 新机型才有；API 在本 SDK 里存在 |
| `@ohos.nfc.tag` | 单向触发 | 贴一贴 | `NFC_TAG`（normal） | 只能传很短的标识，传不了数据流 |
| `@ohos.rpc`（IPCKit） | **双向** | **同一设备跨进程** | 无 | 对方必须提供 Service/Extension |
| `@ohos.data.dataShare` | 共享数据 | 同一设备跨应用 | 无 | 对方必须是 DataShare 提供方 |
| `@ohos.pasteboard` | 双向（人工） | 同一设备 | 无 | 用户手动复制粘贴，谈不上自动化 |
| `@ohos.commonEventManager` | 广播 | 同一设备 | 无 | 主要是系统事件，不是应用间消息总线 |
| `@hms.core.push`（PushKit） | 服务端 → 设备 | 公网 | 需华为推送资质 + 服务端 | 单向为主；要回信得配 HTTP 接口 |
| CallKit / CallServiceKit | 音视频通话 | 公网 | **需华为审批** | 不是拿来传消息的 |
| ServiceCollaborationKit | 跨设备协同 | 同账号 | **需华为审批** | 应用接续/协同场景 |
| `@hms.ai.AgentFramework`（IntentsKit） | 系统意图（"打电话给…"） | 本机 | 视意图 | 唤起系统能力，不是点对点通道 |

---

## 3. 明确用不了的（权限级别卡死）

| 能力 | 卡在哪 |
|---|---|
| 收发短信（`SEND_MESSAGES` / `RECEIVE_SMS`） | **system_basic**，三方应用申请不到（即使 ACL 也要 AGC 特批） |
| 系统级设备发现（`DISTRIBUTED_SOFTBUS_CENTER`） | **system_basic** |
| 通知控制器（`NOTIFICATION_CONTROLLER`） | **system_core** |
| 悬浮窗（`SYSTEM_FLOAT_WINDOW`） | **system_basic**（前文已记为桌宠的硬边界） |

---

## 4. 三条可落地路线（按成本从低到高）

### A. 局域网直连（零服务端，1 天量级）
一方 `TCPSocketServer.listen(4518)`，另一方 `TCPSocket.connect(对方IP, 4518)`。
- 优点：不依赖任何服务器，两个装了 App 的人在同一 WiFi 就能互通。
- 缺点：要解决「怎么知道对方 IP」——手动输入、或 UDP 广播 / mDNS 发现；跨网络完全不行。
- 现成基础：我们已经有 TCP 长连接 + 换行 JSON-RPC 的整套读写代码（`DshClient.ets`）。

### B. WebSocket 中继（要一个服务端，几天量级）
`webSocket.createWebSocket()` 连自建服务，服务端按房间/用户转发。
- 优点：跨网络、跨账号、能离线消息（服务端存）。
- 缺点：**要维护一个服务端**；和 dsh-go 的「回放链接」一样，这属于服务端能力，不是客户端能变出来的。

### C. 同账号多设备（`distributedDataObject`，半天量级）
- 只解决「我的手机和我平板共享同一段对话」。
- 权限是 `normal`，能申请；但**不是「和别的用户」**，别拿它当跨用户方案。

---

## 5. 架构上必须同时改的两件事

1. **桥是单客户端**：`bootstrap.cjs` 新连接会顶掉旧连接（`replacing previous client`）。
   要做多用户/多端，必须先按 `sessionId` 或 `userId` 分流——这正是
   `docs/CARD-AGENT.md` 里「单连接网关按 sessionId 分流」的设计动机。
2. **后台长连接会被冻结**：鸿蒙会挂起后台进程。要保持连接需要
   `KEEP_BACKGROUND_RUNNING`（normal）+ 申请长时任务，且系统仍可能回收。

---

## 6. 建议

如果目标是「两个用户互相发消息」：**先做 B 的最小版**（一个几十行的 WebSocket 转发服务），
因为 A 的「找对方 IP」体验在手机上很难做好，而 C 根本不是跨用户。
如果目标是「同一用户的手机/平板/电脑接着聊」：**做 C**，成本最低且权限够。

两条路都不需要改 dsh 协议——外壳侧加一条独立通道即可，与 ACP 桥并行。
