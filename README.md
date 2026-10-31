<div align="center">

# TA Harness

**在鸿蒙设备上本地运行 DeepSeek Harness 的原生外壳**
**A native shell for running DeepSeek Harness locally on HarmonyOS devices.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/badge/Release-v1.0.0-brightgreen)](https://github.com/QtePP/deepseek-harness-harmony/releases)
[![Platform](https://img.shields.io/badge/Platform-HarmonyOS%20%7C%20API%2026-blue)](https://developer.huawei.com/consumer/cn/)
[![Language](https://img.shields.io/badge/Language-ArkTS-3178C6)](https://developer.huawei.com/consumer/cn/arkts/)
[![Runtime](https://img.shields.io/badge/Node-v24.2.0-339933)](https://nodejs.org/)

不套壳浏览器、不投屏、不连电脑 —— AI 能力全部运行在手机/平板/2in1 的同一应用进程内。

*No WebView, no screen mirroring, no tethering to a computer — the whole runtime lives inside the app process.*

</div>

---

## 这是什么

本仓库是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）的**鸿蒙外壳**：

- **原生 ArkUI 界面**，不是 WebView 包壳
- **同进程内嵌 Node v24.2.0**（NAPI `dlopen libnode.so`），不是子进程或远程调用
- **数据全部留在本机**，会话日志、工作区文件都在应用沙箱内
- **三形态自适应**：手机 / 平板 / 2in1（840vp 断点切换单双栏）

`dsh` 是这个仓库唯一的大脑 —— 会话、工具调用、插件、模型适配、持久化全部来自 npm 包 `@deepseek-ai/dsh`。本仓库不含任何 AI 能力，只有**宿主适配层 + 原生界面**。

> 类比：VS Code 与其进程内扩展引擎；或 Electron 之于 Chromium + Node。

<details>
<summary>English</summary>

This repository is the **HarmonyOS shell** for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`):

- **Native ArkUI interface** — not a WebView wrapper
- **Node v24.2.0 embedded in the same app process** (NAPI `dlopen libnode.so`) — not a subprocess, not a remote call
- **All data stays on the device** — session logs and workspace files live in the app sandbox
- **Three form factors** — phone / tablet / 2in1, switching between single and dual column at the 840vp breakpoint

`dsh` is the only brain here: sessions, tool calls, plugins, model adapters and persistence all come from the npm package `@deepseek-ai/dsh`. This repository contains no AI capability of its own — only the **host adaptation layer + native UI**.

> Analogy: VS Code and its in-process extension engine; or Electron for Chromium + Node.

</details>

## 截图

<p align="center">
  <img src="docs/images/home.png" alt="首页" width="280">
</p>

<table>
<tr>
<td width="33%">

**多模态：看图、算营养、落盘**

<img src="store-assets/screenshots/01-chat.png" alt="多模态对话" width="100%">

</td>
<td width="33%">

**工具轨迹：每一步都摊开**

<img src="store-assets/screenshots/02-trace.png" alt="工具轨迹" width="100%">

</td>
<td width="33%">

**产物就在你自己的目录里**

<img src="store-assets/screenshots/03-files.png" alt="项目文件" width="100%">

</td>
</tr>
<tr>
<td width="33%">

**按项目分开的会话**

<img src="store-assets/screenshots/04-sessions.png" alt="会话与项目" width="100%">

</td>
<td width="33%">

**密钥、模型、权限都归你管**

<img src="store-assets/screenshots/05-settings.png" alt="设置" width="100%">

</td>
<td width="33%">

*截图由 [scripts/make-store-shots.py](scripts/make-store-shots.py) 从真机截图合成*

</td>
</tr>
</table>

## 功能

| 能力 | 说明 |
|---|---|
| **本地运行时** | Node v24.2.0 内嵌在应用进程，无外部依赖 |
| **流式对话** | 思考过程、工具调用、回答实时呈现 |
| **工具轨迹** | 每个工具调用按功能分类（读取/写入/查找/联网/执行），失败节点高亮 |
| **产物面板** | 对话中生成的文件自动归档，支持内嵌预览与全屏查看 |
| **回合回撤** | 长按消息可回撤到该轮之前，**并还原该轮写入的文件** |
| **会话分支** | 从任意消息 fork 出新会话，原会话完整保留 |
| **项目隔离** | 每个项目独立工作区，可绑定外部目录 |
| **图片输入** | 支持相册选择与系统分享 |
| **密钥热更新** | 设置页保存 API Key 后约 2 秒生效，无需重启 |
| **权限三档** | 只读 / 平衡 / 宽松，沙箱与审批捆绑 |

## 架构

```
┌──────────────────────────────────────────┐
│  鸿蒙应用进程                             │
│                                           │
│  ┌────────────┐    TCP 127.0.0.1:4517    │
│  │  ArkUI UI  │◄──── JSON-RPC 2.0 ────┐  │
│  └────────────┘     (newline-delimited)│  │
│                                        │  │
│  ┌─────────────────────────────────┐   │  │
│  │  Node v24.2.0 (libnode.so)      │   │  │
│  │  ├─ bootstrap.cjs  桥接 stdio    │───┘  │
│  │  ├─ fetch-shim.cjs 纯 JS fetch   │      │
│  │  └─ dsh (npm)      唯一大脑      │      │
│  └─────────────────────────────────┘      │
└──────────────────────────────────────────┘
```

**为什么是回环 TCP 而不是 stdio？** 鸿蒙禁止 `fork`/`exec`，无法 spawn 子进程。桥把 socket 伪装成 `dsh` 的 stdio，让官方运行时以为自己在跟终端对话。

详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 快速开始

### 环境要求

- DevEco Studio（含 SDK API 26 / HarmonyOS 7.0.0）
- 鸿蒙设备：**API 26+**（装不上 HarmonyOS 6.x）
- Node 22+（仅本地装配载荷用）

### 构建

```bash
git clone https://github.com/QtePP/deepseek-harness-harmony.git
cd deepseek-harness-harmony

# 1. 装配载荷（把 dsh 及依赖打包进 HAP，约 225MB，首次较慢）
node scripts/assemble-payload.mjs

# 2. 部署到真机（自动处理签名）
bash scripts/deploy.sh
```

`deploy.sh` 会依次：检查设备 → 登录华为账号 → 生成签名（缺失时）→ 构建 → 安装启动，并在结束时**自动还原无签名的仓库状态**。

> **签名说明**：仓库内 `build-profile.json5` 的 `signingConfigs` 为空（密钥不入库）。
> 真实签名在本地 `build-profile.signing.json5`（已 gitignore）。

详细步骤与排障见 [docs/BUILD.md](docs/BUILD.md)。

### 首次启动

解包载荷约 60–90 秒 → 启动内嵌 Node → 连接本地桥 → 进入聊天界面。之后冷启约 3 秒。

**首次使用有两步必做设置：**

1. **填入 DeepSeek API Key**（设置页，保存后约 2 秒生效，无需重启）
2. **切换对话协议到 ACP**（设置 → 对话协议 → ACP → 保存 → **彻底退出并重开应用**）

第 2 步容易漏。默认走 `sdk` profile，此时**纯 JS 搜索、密钥热更新、时间上下文都不会挂载**——
表现为「搜索不好用」或「改了 key 不生效」。切到 ACP 后 profile 落到 `ohos`，这些插件才到位。
协议在启动期读取，`node::Start` 每进程一次，所以**必须重启应用**才生效。

> **只装一个**：桥固定占用 `127.0.0.1:4517`，且为单客户端。如果设备上还留着旧包名
> （如 `com.example.dshharmony`）并正在运行，新包会因 `EADDRINUSE` 启动失败并报
> `initialize: Invalid params [stage=exited]`。先 `hdc uninstall <旧包名>` 或 force-stop 旧应用。

## 技术要点

平台约束决定了实现方式，这里记录几条关键取舍：

| 约束 | 对策 |
|---|---|
| 禁 `fork`/`exec` | 同进程 Node，桥接回环 TCP 伪装 stdio |
| `node::Start` 每进程一次 | 崩溃即终态，UI 明示需重启应用 |
| 无 JIT ⇒ 无 WebAssembly | 纯 JS `fetch` 垫片 + undici 别名替换 |
| 原生 `.node` 模块不可用 | 装配时 `--ignore-scripts`，排除 koffi 等 |
| 文件系统禁 hardlink | `copyFile(COPYFILE_EXCL)` 降级 |
| 零受限 ACL 安装 | 默认 `--jitless` |

### 关于运行 Python / Java

**当前不支持**，这是平台限制而非实现缺失：

- 设备上不存在 `python3` / `java` 解释器
- 鸿蒙只能创建 **ArkTS 子进程**，无法 `exec` 任意二进制
- `run_code` 工具仅执行 **JavaScript**（`node:vm` 沙箱，无 `require`/`process`）

唯一可行路径是把 CPython 交叉编译成 arm64-v8a 的 `.so` 打进 HAP（类比本项目内嵌 Node 的做法），工作量大且生态受限。

## 项目结构

```
entry/src/main/ets/
├── host/          # Node 宿主适配层（NodeHost / Payload / DirGrant）
├── model/         # 协议与数据模型（Protocol / DshClient / AcpClient / ChatModel）
├── view/          # 界面组件（ChatView / SessionRail / Markdown / FileViewer）
├── common/        # 配置与展示文案
└── pages/         # 页面入口

host/
├── bootstrap.cjs      # 桥接 stdio ↔ socket
├── fetch-shim.cjs     # jitless 环境的纯 JS fetch
├── sharp-stub.cjs     # 图片直通（设备无 sharp 原生模块）
├── patches/           # 平台补丁（禁用调用即失败的工具）
└── profile-ohos/      # 自定义 dsh profile（纯 JS 搜索、PTC 运行时等）

docs/                  # 架构、构建、协议、差距分析
scripts/               # 载荷装配、一键部署
```

## 文档

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构图、协议面、事件渲染表 |
| [BUILD.md](docs/BUILD.md) | 构建、签名、装机、排障 |
| [GAP-ANALYSIS.md](docs/GAP-ANALYSIS.md) | 与桌面版的能力差距及根因 |
| [SPIKE-ACP.md](docs/SPIKE-ACP.md) | ACP 协议实测记录 |
| [PERSONAL-AGENT.md](docs/PERSONAL-AGENT.md) | 个人 Agent 与功能卡片演进方案 |
| [NEEDS-ANALYSIS.md](docs/NEEDS-ANALYSIS.md) | 手机形态能力清单与需求评分 |
| [ROADMAP.md](docs/ROADMAP.md) | 路线图 |

## 已知边界

诚实清单：

- **无 token 级流式** —— 按块而非按 token 渲染
- **无二进制工具面** —— 没有 `git` / `rg` / `bash`
- **设备端不做图片降采样** —— 原尺寸上传，由服务端投影到视觉网格
- **`run_code` 仅支持 JavaScript**，且当前默认未启用
- **外部目录授权重启后需重新绑定**
- **发布证书签名的 HAP 不能 `hdc` 直装** —— 平台限制（`not trusted app source`），
  发布包只能经 AGC 分发；真机装机走调试签名（`scripts/deploy.sh`）
- **同一设备只能跑一个实例** —— 桥固定 4517 端口且单客户端，新旧包名不能共存
- **`DeepSeek-V4.1-Flash` 的模型目录被本地覆盖** —— 上游该模型带
  `toolUpdate: addition-only`，会把全部工具标成延迟加载而被 API 拒绝
  （`at least one tool must have defer_loading=false`）。见 `docs/BUILD.md`

## 贡献

欢迎 Issue 与 PR。提交前请确保：

```bash
devecocli check arkts <改动的 .ets 文件>   # ArkTS 静态检查，0 error
devecocli build                            # 构建通过
```

**安全红线**：API Key、签名材料、设备序列号一律不入库。

## 致谢

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) —— 本项目的全部智能
- `@fellow99/node-bridge` —— 进程内嵌 Node 的桥接层
- 所有在鸿蒙上跑通 dsh 的先行者

## 许可证

[MIT](LICENSE) © 2026 QtePP

`dsh` 本体遵循其自身的开源许可，本项目仅提供宿主适配与界面层。
