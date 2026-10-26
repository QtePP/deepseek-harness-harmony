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
| 列目录 / glob | `tool-fs-search` glob | ✅ **已替换**（2026-10-26） | 原版 spawn `rg`；现由 `@ohos/dsh-tool-fs-search-js` 纯 JS 实现接管（`ohos` profile 整行替换） |
| 内容搜索 grep | `tool-fs-search` grep | ✅ **已替换**（2026-10-26） | 同上 |
| bash（一次性） | `tool-bash` | 🚫 已从工具表移除 | spawn shell；patch 禁用（P0a），模型不可见 |
| bash（持久） | `tool-bash-persistent` | ❌ | 需要 PTY/长驻进程 |
| pwsh / pwsh 持久 | `tool-pwsh*` | 🚫 已从工具表移除 | Windows 专用 + spawn；patch 禁用 |
| 后台任务 | `tool-jobs` | 🚫 已从工具表移除 | 依赖 subprocess；patch 禁用（P0a） |
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

### L1 — 纯 JS 补齐搜索（P0，性价比最高）✅ **已交付（2026-10-26，真机验证）**

> 实现：`host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-tool-fs-search-js/index.js`。
> 走自定义 `ohos` profile（bootstrap 在模板在位时把 `DSH_PROFILE=acp` 重映射为 `ohos`），
> bundle patch 顶层 `- insert:` 加新行 + `- id: tool-fs-search / disabled: true` 关旧行，
> 模型侧工具名不变（仍是 `glob`/`grep`），schema/文案与 stock 对齐（`Found X of Y matches`、
> mtime 升序、行截断、二进制跳过）。真机模型轮实测：`glob **` 命中、`grep TODO` 空结果正确、
> 模型工具表无 bash/job_*。机制细节见 §7。

原方案（保留作背景）：

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

| 优先级 | 事项 | 理由 | 状态 |
|---|---|---|---|
| **P0** | 纯 JS 的 glob/grep | agent 的"探索"全靠它，缺了会显著降智（它会反复试 bash） | ✅ 2026-10-26 交付并真机验证 |
| **P0** | 从 profile 里禁用 `tool-bash` / `tool-pwsh` / `tool-jobs` | 现在模型会调用它们、失败、再重试，纯浪费轮次和 token | ✅ 2026-10-26 交付（ohos.patch.yml，模型工具表已无这些行） |
| **P1** | in-process PTC runtime | 真正的"脚本能力"，替代 shell 的主力 | 待做（1–2 天） |
| **P2** | isomorphic-git 工具 | 手机上看 diff / 提交有实际价值 | 待做（1–2 天） |
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

---

## 7. 附录：插件落地机制（实测，含未通过的一步）

要把纯 JS 搜索插件塞进运行时，必须先解决"怎么加一行"。四条路都试过：

| 做法 | 结果 |
|---|---|
| `--patch` 里写 `- id: 新id` + `name` | ❌ `patch: entry "新id" not found`——**patch 只能改/禁已有行，不能新增** |
| patch 用 `insert:` | ❌ `patch insert: entry "tool-fs-search" is not a group`——只能插进 group，acp profile 里没有 group |
| 自定义 profile（`package.json` 的 `dsh.profile.bundles` 加自建 bundle 包） | ✅ **行能进组合配置**：`--dump-config` 能看到新行，`boot: --profile ohos` 正常挂载 |
| 同上，并让插件真正注册 | ✅ **已通过（2026-10-26）**：根因是插件包没有声明为 **bundle 的 `dependencies`**——profile 路由表（`collectProfileScopePackages`）按 bundle 依赖闭包构建，未声明的包即使文件在 `node_modules` 里也永远不解析、不 mount |

自定义 profile 的形状（`--from-default-profile acp` 生成后改）：

```
$DSH_HOME/profiles/ohos/
├── package.json      # dsh.profile.bundles: [dsh-base, dsh-acp-app, @ohos/dsh-bundle-x]
├── cordis.patch.yml  # 本 profile 的 patch 层（可禁已有行）
├── cordis.yml        # 根，保持 []
└── pnpm-workspace.yaml
```

bundle 包只需 `package.json` 里声明 `dsh.bundle.patch: './cordis.patch.yml'`，
该 patch 文件里写的行会作为**新行**进入组合树（bundle 层不是 overlay，所以不受"只能改已有行"限制）。

**卡住的一步**：行进了配置，但插件没 mount。已排除的：profile 能正常 boot、`--dump-config` 无报错、
把插件软链进 `profiles/ohos/node_modules/@ohos/` 之后仍然没有。模型侧实测工具列表为：

```
bash, create_goal, edit, exit_plan_mode, get_goal, glob, grep, interrupt_agent,
job_kill, job_list, job_output, list_agents, read, read_image, send_message,
skill, subagent, subagent_fork, todo_write, update_goal, web_fetch, web_search,
workflow, working_directory
```

没有我们加的 `ping`。下一步要试的方向（按可能性排序）：

1. profile 的 `package.json` **dependencies 里声明插件**，再跑 profile 自己的 pnpm install
   （profile 目录里有 `pnpm-workspace.yaml`，说明依赖是按 profile 装的，不是从载荷根解析）
2. bundle 的 `cordis.patch.yml` 里用**相对路径**引用插件（文档提到 "Inserted relative plugin
   paths are anchored beside their patch file"）
3. 把插件直接放进 bundle 包内，由 bundle 的 patch 用相对路径加载

### 7.1 闭环记录（2026-10-26）

**根因确认**：方向 1 命中一半——**要声明的是 bundle 的 `dependencies`，不是 profile 的**，且
不需要 pnpm install（dsh 只查包存在性）。路由表构建链：

```
loadProfileDirectory → 各 bundle package.json 的 dependencies 闭包
  （dsh-app-boot `collectProfileScopePackages`）→ entries 路由表
  → ESM resolve hook 对 profiles 树内的 import 按 importee 裸名查表
```

未声明的包：文件在 `node_modules` 里也存在、`--dump-config` 也看到行，但 import 解析时
路由表里没有条目 → 插件加载失败 → 工具不注册。**验证手段**：在插件 `apply()` 里写 marker
文件——声明依赖后 `ping-mounted.marker` 落盘，`apply()` 真实执行。

**另外两个实测细节**：

- bundle patch 的新行写法是**顶层单条 `- insert:` 嵌套行列表**（dsh-base 自己就是这么加
  全部核心行的）；裸 `- id:` 行只能改/禁已有行。
- `resolveBundleDir` 先查 installAnchor（载荷 `node_modules`）再查 profile 目录——
  **载荷里残留的同名 `@ohos/*` 测试包会遮蔽 profile 内的新版**（旧包+旧语法会制造
  "patch not found" 假象，排查时先清残留）。

**交付物**（`host/profile-ohos/profiles/ohos/`）：

```
package.json                  # dsh.profile.bundles: [dsh-base, dsh-acp-app, @ohos/dsh-bundle-ohos]
cordis.yml / cordis.patch.yml / pnpm-workspace.yaml
node_modules/@ohos/
├── dsh-bundle-ohos/          # bundle：dependencies 声明插件 + dsh.bundle.patch
│   ├── package.json          #   （insert 新行 + disable 旧行）
│   └── cordis.patch.yml
└── dsh-tool-fs-search-js/    # 纯 JS glob/grep 插件（~370 行）
    └── index.js
```

宿主接线：`scripts/assemble-payload.mjs` 把模板打进载荷 `profile-ohos/profiles/`；
`host/bootstrap.cjs` 启动时按**内容哈希戳**（`.ohos-template-stamp`）幂等安装到
`$DSH_HOME/profiles/ohos`，并在模板在位时把 `acp` 重映射为 `ohos`（缺模板回落 stock acp）。
真机验证：`bridge-status.json` 的 `profile: "ohos"`、模型轮 `glob/grep` 真实命中、
工具表无 bash/job_*、权限三档快照正常。

> 工具定义的正确形状（从 `tool-fs/src/read.ts` 取，供实现时对齐）：
> ```js
> defineTool({
>   name, description,
>   parameters: { p: { type: 'string', required: true, description } },
>   output: {
>     schema: { type: 'object', additionalProperties: false, properties: { ... } },
>     render: (args, value) => [{ type: 'text', text: '...' }]
>   },
>   execute: async (args) => ({ ... })   // 返回值必须满足 output.schema
> })
> ```
