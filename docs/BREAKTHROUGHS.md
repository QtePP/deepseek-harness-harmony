# 突破清单：我们真正硬啃下来的六件事

> 26 天（2026-10-25 → 11-19）、115 个 commit、223 个文件里，够格叫「突破」的只有六件。
> 判据四条同时成立才算：**平台明确说不行 / 没有现成方案可抄 / 真机闭环过 / 用户能感知**。
> 其余是苦工和补债，§5 照实列。
>
> 本文件是**权威文本**；排版版见 [`breakthroughs.html`](breakthroughs.html)（同一套内容，带版式与明暗主题）。
> 改内容先改这里，再同步 HTML。

---

## 0. 判据

「突破」这个词很容易通货膨胀，所以先定尺子，缺一条就降级成苦工：

| 判据 | 为什么它把大部分工作筛掉 |
|---|---|
| 平台明确说不行 | 不是「麻烦」，是文档或权限模型直接判死：禁 fork、无 WASM、patch 不能加行 |
| 没有现成方案可抄 | 要么逆向机制，要么自己写；照文档做能成的事不算 |
| 真机闭环过 | 「理论上可行」不算，得在设备上跑出结果 |
| 用户能感知 | 模型能搜到文件、能改文件、能流式回答——不是内部重构 |

按这个尺子，六件够格。它们的共同点是：**没有一件是「绕过限制」，每一件都是「换一条实现路径」**——限制还在，只是不再是瓶颈。

---

## 1. 六件平台突破

| # | 突破 | 平台说 | 换的路径 | 代价 |
|---|---|---|---|---|
| 1 | 同进程 Node | 禁 fork/exec，不能 `spawn('node')` | `dlopen libnode.so` + `node::Start`，Node 是本进程一个 detached pthread | 崩溃即终态、无进程隔离、必须劫持 stdio、载荷 240MB |
| 2 | 进程内 ACP | ACP 是「宿主 spawn 子进程 + stdio」 | 回环 TCP → 进程级 `PassThrough` → `defineProperty` 覆盖 `process.stdin/stdout` | 桥是单客户端；断线重连语义得自己扛 |
| 3 | jitless fetch | 无 WebAssembly ⇒ undici 的 llhttp 起不来 ⇒ fetch 全废 | 整族替换 + ESM resolve hook | 无 WASM 连带：TS 擦除不可用、sharp 只能原字节直通 |
| 4 | 自定义 `ohos` profile | patch 只能改或禁已有行，不能新增 | bundle `cordis.patch.yml` 顶层 `- insert:` + bundle `dependencies` 声明 | 装配链复杂；升级要复核行 id |
| 5 | 三条降级链 | 禁硬链接；沙箱只认 app files 根以下；`/storage/Users` 是 FUSE 语义 | `copyFile(COPYFILE_EXCL)` / 只读 open 目录给空壳 handle / mount-aware chmod | 每条都必须「只在该挂载上容忍」，放宽一点就是吞错 |
| 6 | 无终端 → 可观测性 | 手机上没有 shell，出问题只能猜 | boot-report 启动 5s 后写工具表 + web 就绪到 `bridge.log` | 只是诊断，不修复任何东西；它自己也会过时（已经过时过一次，见 §1.6） |

### 1.1 同进程 Node：地基，但不是我们一个人铺的

诚实归属：**引擎入进程是第三方 `@fellow99/node-bridge` 做的**（NAPI 引导件 `dlopen` + `dlsym(node::Start)`）。
我们的突破是「让 dsh 在这个引擎上活下来」：

- `--jitless --expose-internals` 的取舍（无 JIT 权限也能装，代价是 WebAssembly 全废）；
- 九个环境变量的接线（`DSH_HOME` / `DSH_KEY_FILE` / `DSH_BRIDGE_PORT` / `TMPDIR` / `HOME` / `DSH_PATCH_FILE` / `DSH_USER_PATCH_FILE` / `DSH_PROFILE` / `DSH_PERMISSION_MODE`）；
- 密钥不走 env 而走 0600 文件——原生桥启动时会把 env dump 进 `node.log`；
- 「首次连入才 boot dsh」的顺序，保证 dsh 的 stdout 从第一帧起就有接收方。

真正难的不是启动，是**它只能启动一次**：`node::Start` 每进程一次，所以整套设计里没有「重启运行时」这个动作，只有「重启应用」——这条约束反过来决定了每一条错误文案。

### 1.2 进程内 ACP：官方文档没给的路

官方 ACP 是「宿主 spawn 一个子进程，用 stdio 说话」。这条路在鸿蒙上直接死。我们做的不是找替代协议，而是**把「stdio」这个概念本身换掉**。

三个细节全是踩出来的（`host/bootstrap.cjs`）：

1. Node 24 里 `process.stdin` 是 getter-only，直接赋值会抛 → 必须 `Object.defineProperty`；
2. 流必须是**进程级**的（`ensureBridgeStreams`）——每次连接重建会让重连后的运行时读一根孤儿管道；
3. socket 断开只能 pause 不能 end——stdin EOF 会被 dsh 当成 shutdown。

结果：9 个方法 + 流式 + 服务端发起审批全部在应用进程内跑通，还顺带获得「用 `hdc fport` 从电脑直接驱动设备端运行时」的调试能力——这是子进程方案反而没有的。

### 1.3 fetch-shim：一次「为什么必须这样」的推导

表面需求是「jitless 没有 WebAssembly，写个纯 JS fetch」。真正的坑是：**只换 `fetch` 会崩**。

dsh 启动期会读全局 `Headers`，一读就触发 undici 的惰性物化，而它的 llhttp 是 WASM——崩在启动阶段，日志里只留一条看起来「良性」的 unhandled rejection。

所以修法是整族替换 `fetch / Headers / Response / Request / FormData`，再加一个 ESM resolve hook 拦 `await import('undici')`（那条路绕过 CJS 的 `Module._resolveFilename`）。
「必须跑在任何 ESM import 之前」不是代码风格：ESM 的具名导入会在首次 import 时快照模块导出。

**这是本项目技术含量最高的单点。**

### 1.4 自定义 profile：把「不能加行」逆向成一套机制

四条路都试过，前两条明确报错（`patch: entry "新id" not found` / `patch insert: entry ... is not a group`）。逆向出的机制是：

- 新行只能来自 **bundle 的 `cordis.patch.yml`** 顶层 `- insert:`；
- 插件包必须写进 **bundle 的 `dependencies`**——profile 路由表按 bundle 依赖闭包构建，文件在 `node_modules` 里也没用；
- 载荷里残留的同名 `@ohos/*` 测试包会**遮蔽** profile 内的新版（曾制造「patch not found」假象）。

价值不在「我们装上了插件」，而在**「不 fork dsh 也能给平台加能力」这条路被证明了**。现在五个插件都挂在这条路上：纯 JS 搜索、in-process PTC、密钥热更新、时间上下文、boot 自检。

### 1.5 三条降级链：每条都只在真机上暴露

| 现象 | 根因 | 修法 |
|---|---|---|
| 会话写不进去 | 禁硬链接，`link tmp→final` 失败 | `copyFile(COPYFILE_EXCL)` 保住排他创建语义 |
| 内联图片报「unable to persist」 | 沙箱只认 app files 根以下，祖先 `/data` 只读 open 被拒 | 只读 open 目录给空壳 handle |
| 绑定用户目录后写文件必死 | `/storage/Users` 是 FUSE 语义，chmod/chown/FICLONE 全 EPERM | 三条 mount-aware 降级 |

共同点：**都不是功能缺失，而是某个底层 syscall 的语义在这个文件系统上不成立**。纸面推不出来，只能真机撞。

### 1.6 无终端 → 可观测性

`@ohos/dsh-boot-report` 在启动 5 秒后把**已注册工具名 + web search/fetch 就绪状态**写进 `bridge.log`。
看起来是小工具，实际是把「设备是黑盒」变成了「设备可诊断」。它当场结掉两个悬案：

- 工具表 21 还是 25（是 25，某台机器关了 `tool-fs` 开关）；
- 「模型说不能搜网」到底是工具没注册、注册了没凭据、还是根本没调用。

**它也真的过时过一次**：升到 dsh 0.2.2-rc.5 后，`dsh-web` 把「搜索提供方」从固定配置改成按模型路由
偏好（DeepSeek 路由 → `deepseek-official`，其它 → `deepseek-search-api`），而 boot-report 仍按
「配置优先 / 唯一可用」判定，于是把两个可用 provider 报成 `search=ambiguous` —— 功能其实是好的，
是诊断在说谎。修法不是加判断，而是**把 seam 的规则抄对**：`preferredSearchProvider(route)` +
路由取自 `ctx.get('agentDefaultModel').currentSelection().provider`，单测 11 → 20。

---

## 2. 证据索引

| 突破 | 主要证据 | 位置 |
|---|---|---|
| 1 同进程 Node | `bridge-status.json` 的 `node=24.2.0` / `wasm=false`；真机 0 个未激活行 | `host/bootstrap.cjs`、`entry/src/main/ets/host/NodeHost.ets` |
| 2 进程内 ACP | 真机矩阵 9 方法全绿（initialize/new/set_config_option/prompt/cancel/close/list/resume + 重连） | `docs/SPIKE-ACP.md` §9、`host/bootstrap.cjs` |
| 3 jitless fetch | 启动即 `boot: sdk runtime mounted`，0 fatal | `host/fetch-shim.cjs`、`host/undici-hooks.mjs` |
| 4 自定义 profile | `--dump-config` 行命中；真机工具表含 `glob`/`grep` 且无 `bash` | `host/profile-ohos/…/@ohos/dsh-bundle-ohos/cordis.patch.yml` |
| 5 三条降级链 | 会话写得进、图片不再报错、用户目录可写 | `host/bootstrap.cjs` 的 `install*Fallback` |
| 6 可观测性 | `[boot-report] tools(25): …` / `web: search=…` | `host/profile-ohos/…/@ohos/dsh-boot-report` |

---

## 3. 把黑盒写成契约

这一层不算「平台突破」，但它是**别人抄不走的部分**——每条都是真机实测，写进注释就是契约。

| 契约 | 按直觉做会怎样 |
|---|---|
| `session/cancel` 是**通知** | 带 id 发（当请求）→ `Method not found` |
| `set_config_option` 的 model value 是 **JSON 数组字符串** | 传对象 → 静默不改，没有报错 |
| 选项集会**收缩** | 缓存旧列表 → 切走默认模型后切不回来，`-32602` |
| 不答审批 = **无限挂起** | 以为会超时失败 → 实际整轮卡死，服务端不自动放行 |

**最有价值的一条：协议缺陷 → 产品设计。**
断线时正在跑的那一轮，客户端无从判断它何时结束——原 `session/prompt` 的响应随 socket 一起丢了，而 `session/update` 帧里没有 turn id。
协议给不出答案，只能在产品层解决：`session/close` 掐掉孤儿轮 → `session/resume` → 把消息标成「已中断」让用户决定重发。
这条转化比任何一条协议实现都难写。

---

## 4. 用「官方没提供」当设计依据

官方 ACP README 明确写 *intentionally exposes only the standard ACP v1 surface*，并点名 cards / plans / titles / todos / terminal views **不在协议里**。
这句话别人看是限制，我们看是**唯一路径的证明**：

- **待办条 / 目标条 / 上下文小环 / 每轮用量 / 子代理计数**——全部从 `tool_call` 参数反推，零协议改动，冷启动还能从持久化轨迹重建。
- **密钥热更新**——dsh 启动期冻结 env 快照（`loadLayeredEnv` 拷 `process.env`），改 env 永远无效；所以不碰 env，改成监听暂存文件 → `credentials.set()`，2 秒生效。
- **图片存相册**——用 `SaveButton` 安全组件换临时媒体权限，而不是申请受限权限（那要过 AGC 审批，还会把普通应用变成受限应用）。
- **语音**——先勘误旧结论（「SDK 不含 CoreSpeechKit」是错的，只看了 `openharmony/ets/kits`，没看 `hms/ets/kits`），再做「引擎起不来也不烂」的降级 + 复位入口。

---

## 5. 什么不算突破

清单的另一半同样重要——这四类工作占了大部分时间，但按判据一条都不够格。

| 类别 | 内容 | 为什么不算 |
|---|---|---|
| 苦工 | UI 对齐 dsh-go 的十几条：流式、排队、引用、重答、搜索、置顶、归档、多选、分享卡、导出 | 量很大（15k 行 ArkTS），但没有一条是「平台说不行」 |
| 补债 | 真机缺陷：父手势吞子手势、顶栏落进状态栏、重启丢回复、通知授权时机 | 是我们自己写出来的 bug，修好只是回到基线 |
| 流程债 | 三次口径漂移：默认 profile、工具数 21/25、`ARCHITECTURE.md` 过时 | 还没还；默认 profile 那条现在是产品缺陷 |
| 未突破 | 默认 profile 仍是 `sdk`，全新安装跑的是降级路径 | 这是「还没做成」，不是「做到了」 |

---

## 6. 方法论：把「能不能上设备」变成可本地预演

如果只能带走一件，选这个。以前「设备上跑不起来」是个黑洞，只能反复刷机猜；现在真机被降级成**最后一道闸**。

1. **改 `host/`** —— 只动 `bootstrap.cjs`、垫片、profile 模板或补丁 YAML。
2. **`--dump-config`** —— 看行 id 是否命中、禁用行是否生效、`tools` 行的 mode 对不对。
3. **本地起一次 runtime** —— `--profile ohos` + 等 boot-report。零警告才算过。
4. **三段验证** —— 载荷单测 + ArkTS 检查 + LocalUnit，一条 `scripts/test.sh` 跑完。
5. **最后才装机** —— 重打载荷 → build → 签名 → 装。真机只用来确认，不用来发现。

这套顺序救过一次典型的坑：`schedule` 插件插进去后，本地日志直接给出
`pending (waiting for service: sessionController)`——当场判定「缺的是宿主服务，不是插件」，回滚，没浪费一次装机。

配套的是**证据纪律**：先取证再下结论。语音那条结论错了四天，错在只看了一个目录；工具数 21 的争论，错在把「用户关了开关」当成「升级回归」。

---

## 7. 只留三件

按「换来的能力 ÷ 付出的代价」排序：

1. **进程内 ACP** —— 它让「协议层」这件事在鸿蒙上重新存在。没有它，后面所有流式、审批、取消、重连都无从谈起。
2. **fetch-shim 的整族替换** —— 它不是补丁，是一次对「为什么必须这样」的完整推导；推导错一步，应用就崩在启动阶段。
3. **自定义 profile 的 route-table 机制** —— 它把「不能 fork dsh」从限制变成了可扩展性：平台差异不再需要改上游源码。

第 4 名留给 **boot-report**：技术含量不高，但它把整个项目的可调试性抬了一个台阶——而可调试性，是这 26 天里唯一让「猜」变成「看」的东西。

---

## 8. 维护口径

- 本文件是权威文本，[`breakthroughs.html`](breakthroughs.html) 是排版版；改内容先改这里。
- 新增一条「突破」必须过 §0 的四条判据，并附**证据**（`文件:行` / 日志行 / 真机日期 + 机型），不许只写结论。
- `boot-report` 的 search 判定**曾经**是已知会过时的地方（0.2.2-rc.5 的按路由偏好规则），2026-11-20 已修并补到 20 个用例；**教训**：诊断插件复刻上游判定逻辑时，必须把「规则」而不是「现象」抄过来，否则升级后它会开始说谎。
- 与 [`on-device-architecture.html`](on-device-architecture.html) 互补：那一页讲**现在长什么样**，这一页讲**哪些地方是硬啃下来的、代价是什么**。
