# 与 dsh 桌面端的能力差距 + shell/bash/pwsh 替代方案

> 基线：2026-10-26，设备 `profile=acp`、`node v24.2.0`、`arm64`、`wasm:false`。
> 判定依据是**源码调用链**，不是"插件有没有 mount 上"——设备上 0 个未激活行，
> 但 mount 成功不等于能用。

---

## 1. 一条容易误判的前提

手机上的限制不是"没有 bash 这个工具"，而是**整个 `ctx.subprocess` 面不存在**（禁 fork/exec）。
凡是经过这个 seam 的能力，调用时必然失败：

```
tool-bash ─┐
tool-pwsh ─┤
glob      ─┼─→ ctx.subprocess ─→ spawn(2) ─→ ✘ EPERM
grep      ─┤
jobs      ─┤
ptc-runtime-node ─┘
```

`glob` / `grep` 的源码写得很明确：

> "Execution spawns the packaged ripgrep binary (`@vscode/ripgrep`) directly through the
> subprocess seam with a plain argv vector" — `packages/fs/tool-fs-search/src/{glob,grep}.ts`

所以**搜索能力和 shell 一起没了**，这是最容易被忽略的一处：不是"命令跑不了"，是"agent 找不到文件"。

---

## 2. 工具面逐项对照

| 能力 | 桌面实现 | 手机状态 | 原因 |
|---|---|---|---|
| 读文件 / 读图 | `tool-fs` read / read_image | ✅ 可用 | 纯 JS（`ctx.fs` → `fs-local`） |
| 写文件 / 编辑 | `tool-fs` write / edit | ✅ 可用 | 纯 JS |
| 列目录 / glob | `tool-fs-search` glob | ❌ 调用即失败 | spawn `rg` |
| 内容搜索 grep | `tool-fs-search` grep | ❌ 调用即失败 | spawn `rg` |
| bash（一次性） | `tool-bash` | ❌ | spawn shell |
| bash（持久） | `tool-bash-persistent` | ❌ | 需要 PTY/长驻进程 |
| pwsh / pwsh 持久 | `tool-pwsh*` | ❌ | Windows 专用 + spawn |
| 后台任务 | `tool-jobs` | ❌ | 依赖 subprocess |
| 程序化工具调用（PTC） | `tool-executor-ptc` + `ptc-runtime-node` | ❌ | 运行时**起新 Node 进程**跑模型写的程序 |
| 子智能体 / fork | `tool-subagent*` | ✅ | 进程内会话 |
| 技能 | `tool-skill` | ✅ | 读 SKILL.md |
| 交付物 | `tool-present` | ✅ | 纯 JS |
| 终端面板（PTY） | `ui-sidebar-terminal` | ❌ | 无 `/dev/ptmx` |
| 插件市场 | `plugin-manager` | ❌ | 依赖 pnpm 子进程 |
| Office 转换 | `skill-office`（libreoffice-kit） | ❌ | koffi 原生 FFI |
| 浏览器自动化 | `browser-use-chrome-devtools-mcp` | ❌ | 需 Chrome + CDP |
| 桌面操控 | `computer-use` | ❌ | 平台不符 |

---

## 3. shell / bash / pwsh 怎么替代

先说结论：**不要试图在手机上模拟 shell，要把"脚本能力"换成 JS。**

分三层，成本和收益差别很大。

### L0 — 已可用，不需要写代码

`tool-fs` 的 read / write / edit 覆盖了「看文件、改文件」的绝大部分需求。真机上已经用它
产出过 `index.html`、`stardust.html`。缺的不是读写，是**发现**（glob/grep）。

### L1 — 纯 JS 补齐搜索（P0，性价比最高）

把 `tool-fs-search` 的 ripgrep 后端换掉，用 Node 自己走目录：

- **glob**：`fs.readdir({withFileTypes:true})` 递归 + 通配符匹配（`minimatch` 或自写 30 行），
  按 mtime 排序，尊重 `.gitignore` 可选
- **grep**：遍历候选文件 → `readFile` → 按行 `RegExp` 匹配 → 输出 `{file,line,text}`，
  二进制/超大文件跳过，行预览截断（沿用现有 `grepMaxLineBytes` 语义）

工作量：**200 行左右 JS**，接口与现有 `glob`/`grep` 工具的 schema 保持一致，
模型侧零感知。性能：手机工作区通常 < 5000 文件，纯 JS 遍历在百毫秒级，够用。

落地方式二选一：
1. 打包成 dsh 插件，用 profile patch 替换掉 `tool-fs-search` 那一行（最干净，模型直接拿到新工具）
2. 挂在桥的 side-channel 上（`ohos/fs.search`），由客户端工具卡调用（改动小，但模型看不见）

推荐 1——因为**模型必须能自己调用**，否则它会一直尝试 bash 然后失败。

### L2 — 用 JS 代替 shell 脚本（真正的替代）

关键洞察：手机不能"跑命令"，但**能跑 JS**（我们本来就在 Node 里）。
所以 bash 的替代物不是"模拟 shell 语法"，而是"让模型写程序调工具"。

dsh 已经有这条 seam：

```
tool-executor-ptc   ← 模型写程序，程序里调工具
   └─ ptc-runtime   ← 抽象接口（ctx.ptcRuntime）
        └─ ptc-runtime-node  ← 现状：spawn 新 Node 进程 ✘
```

**要做的只是实现一个 in-process 的 `ptc-runtime`**：用 `node:vm` 在同一进程里执行模型写的
程序，把 `ctx.fs` / 搜索 / web 等能力注入成绑定对象。`--jitless` 下 `vm` 仍可用（不是 JIT）。

于是：

```js
// 模型不再写：for f in $(ls *.html); do grep -l "TODO" $f; done
const hits = []
for (const f of await glob('**/*.html')) {
  const text = await read(f)
  if (text.includes('TODO')) hits.push(f)
}
return hits
```

等价于 shell 的循环 + 管道 + 重定向，而且**没有进程、没有权限逃逸**。

工作量：**300 行左右**（vm 上下文 + 绑定 + 超时/输出上限）。风险：无隔离，模型代码跑在
主进程里——需要 `vm` 的 timeout + 输出截断兜底；内存泄漏要防（每次跑完丢弃 context）。

### L3 — 不可替代，认了

| 能力 | 为什么不行 | 折中 |
|---|---|---|
| 交互式 PTY（vim/top/ssh） | 无 `/dev/ptmx`，无 exec | 不做；手机上没有这个场景 |
| 编译工具链（gcc/rustc/node-gyp） | 需要 exec 外部二进制 | 不做 |
| 系统包管理（apt/brew/pnpm） | 同上 | 插件市场在手机上不可用 |
| 依赖外部二进制的工具 | 同上 | `git` 可用 **isomorphic-git**（纯 JS）替代 80% 场景：status/add/commit/log/diff |
| WASM 方案（如 wasm 版 bash） | `--jitless` 下 `WebAssembly` 不存在 | 直接排除，别浪费时间 |

---

## 4. 建议优先级

| 优先级 | 事项 | 理由 | 工作量 |
|---|---|---|---|
| **P0** | 纯 JS 的 glob/grep | agent 的"探索"全靠它，缺了会显著降智（它会反复试 bash） | 0.5–1 天 |
| **P0** | 从 profile 里禁用 `tool-bash` / `tool-pwsh` / `tool-jobs` | 现在模型会调用它们、失败、再重试，纯浪费轮次和 token | 10 分钟（改 patch） |
| **P1** | in-process PTC runtime | 真正的"脚本能力"，替代 shell 的主力 | 1–2 天 |
| **P2** | isomorphic-git 工具 | 手机上看 diff / 提交有实际价值 | 1–2 天 |
| — | 终端、编译、包管理 | 平台决定，不做 | — |

> P0 的第二项值得单独强调：**让工具"不存在"比让它"失败"更好**。模型看到 bash 工具在
> 工具表里，就会尝试；失败三次后才改用 fs 工具。禁用后它第一轮就走对路。
>
> 安全性已复测（2026-10-26）：**单独禁 `tool-bash` 是安全的**——只禁它时 0 个未激活，
> `permission-presets` 正常激活。此前"禁 tool-bash 会打掉权限门"的结论是被同时禁用的
> `bash-sandbox` / `subprocess` 混淆了。真正不能动的是 `subprocess`（会带走 fs-search / ptc / workflow）。

---

## 5. 怎么验证替代是否生效

1. 发一条「列出 workspace 里所有 .html 文件，并找出含 "star" 的那个」：
   - 现在：会先调 `glob`/`grep` → 失败 → 可能退回 `bash` → 再失败 → 最后手动 read
   - 替代后：一次 `glob` 调用拿到列表，一次 `grep` 拿到命中
2. 看 `session/update` 的 `tool_call` 序列：失败的工具调用次数应降到 0
3. 用 `hdc fport` + `docs/SPIKE-ACP.md` 的探针脚本复现，不依赖 UI

---

## 6. 附：本文结论的来源

- `packages/fs/tool-fs-search/src/{glob,grep}.ts` 头注释：明确走 `ctx.subprocess` spawn `rg`
- `packages/ptc-runtime/ptc-runtime-node/README.md`：`Run TypeScript programs in fresh Node processes`
- 设备侧 `bridge-status.json`（`profile: acp`, `wasm: false`）与 `bridge.log`（0 未激活）
- 真机 `tool_call` 观测：`bash → status=failed`（见 `docs/SPIKE-ACP.md` §2）
