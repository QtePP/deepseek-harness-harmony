# 启动链路：从点开图标到 dsh 挂载

> 这份文档只回答一个问题：**这个 App 是怎么把 dsh「拉起来」的**。
> 仓库里那些 `.cjs` / `.mjs` / `.yml` 不是一条脚本流水线，而是三层东西：
> 构建期装配、启动期引导、运行期垫片。真正「拉起」的只有一条链，读完后半段即可。

## 0. 一句话

```
EntryAbility → Index.init → NodeHost.boot → NodeRuntime.start(dlopen libnode.so + node::Start)
            → bootstrap.cjs → runCli() → 挂载 profile → dsh 在应用进程内跑起来
            → ArkTS 客户端连 127.0.0.1:4517 说话
```

没有子进程、没有 spawn、没有 WebView。Node 是**本进程里的一个线程**（detached pthread，32MB 栈），
`libnode.so` 由 `@fellow99/node-bridge` 用 `dlopen` + `dlsym(node::Start)` 拉进同一个进程。
这就是「为什么不能 fork/exec」的直接后果：所有适配都只能发生在**进程内部**。

### 0.1 三种语言，一个进程

| 层 | 语言 | 在哪 | 干什么 |
|---|---|---|---|
| 界面 | ArkTS（TypeScript 的鸿蒙子集，编译成 `.abc` 字节码） | `entry/src/main/ets/**` | 按钮、气泡、设置页、审批弹窗 |
| 大脑 | JavaScript（ESM） | 载荷里的 `@deepseek-ai/dsh` | agent loop、工具调用、会话持久化、模型适配 |
| 引擎 | C / C++（V8 + libuv + llhttp） | `libnode.so`（≈122MB，随 HAP 分发） | 执行上面那层 JS |
| 胶水 | JavaScript（CommonJS） | `host/*.cjs` | 在 Node 里把 dsh 拉起来、打平台垫片 |

一句话：**界面是 ArkTS，干活的是 JavaScript，跑 JavaScript 的引擎是 C++。** 三者不是三个进程，
是同一个进程里的三层——ArkTS 和 JS 之间只隔一条 `127.0.0.1:4517` 的 TCP，说的是换行分隔的 JSON-RPC。


## 1. 启动时序（带行号）

| # | 阶段 | 代码 | 干什么 / 为什么 |
|---|---|---|---|
| 1 | 应用创建 | `entry/src/main/ets/entryability/EntryAbility.ets:11` | `onCreate` 先定外观（运行中 `setColorMode` 会重建窗口黑屏，必须启动期定），抓快捷方式与分享 intent |
| 2 | 加载页面 | `EntryAbility.ets:55` | `loadContent('pages/Index')` |
| 3 | 页面初始化 | `entry/src/main/ets/pages/Index.ets:223` → `:260` | `aboutToAppear` 里 `void this.init()`：读偏好、插件开关、项目、会话缓存，挂好回调，最后 `await this.boot()`（`:300`） |
| 4 | 引导 | `entry/src/main/ets/host/NodeHost.ets:58` | `boot()` 是全链路的编排者，见 §2 |
| 5 | 解包载荷 | `entry/src/main/ets/host/Payload.ets:21` | rawfile 里 ≈211MB 的 `dsh-payload.zip` 分 1MiB 块复制到沙箱再 `zlib.decompressFile`；归档长度当幂等戳（`payload.stamp`） |
| 6 | 投递 Node | `NodeHost.ets:151` | `runtime.start()` 只表示「已投递到后台线程」，不代表起来了 |
| 7 | 等主循环 | `NodeHost.ets:158` | `waitUntilRunning(30000)` 轮询原生探针；探针误报不算数，真正判据是下一步连上桥 |
| 8 | 连桥 | `NodeHost.ets:169` → `model/DshClient.ets:59` | 连 `127.0.0.1:4517`，8 次 × 2s（真机上有几秒「Node 起了但还没 listen」的窗口） |
| 9 | **首次连接触发 dsh** | `host/bootstrap.cjs:820` | 服务端 accept 到第一个 socket 才 `void boot()` —— 刻意如此：dsh 的 stdout 从第一帧起就有接收方 |
| 10 | 握手上层 | `NodeHost.ets:174` / `:179` | ACP 走 `initialize`；SDK 走 `initialize(cwd, provider, model)`（180s 超时），成功后 `phase = READY` |

## 2. NodeHost.boot 的六件事

`entry/src/main/ets/host/NodeHost.ets:58-191`，顺序不能乱：

1. **没有 key 就直接失败**（`:70`）—— 不在没有凭据的情况下白跑一遍解包。
2. **解包载荷**（`:75`）→ `payloadRoot`。
3. **备目录**：`workspace/`、`dsh-home/`、`tmp/`（`:77-88`）。
4. **写 key 文件**（`:106-120`）：key 绝不能进 env —— `node-bridge` 启动时会把子进程环境 dump 进
   `node.log`（`[node_bridge] env DEEPSEEK_API_KEY=…`）。所以写成 `dsh-home/.api-key`，只传路径
   `DSH_KEY_FILE`，由 `bootstrap.cjs` 在日志写完**之后**才赋给 `process.env`。
5. **投递 Node**（`:124-154`）：`scriptPath = <payload>/bootstrap.cjs`，flags `--jitless --expose-internals`，
   env 九个变量（`DSH_HOME` / `DSH_KEY_FILE` / `DSH_BRIDGE_PORT` / `TMPDIR` / `HOME` /
   `DSH_PATCH_FILE` / `DSH_USER_PATCH_FILE` / `DSH_PROFILE` / `DSH_PERMISSION_MODE`）。
   `--jitless` 是因为没申请受限 ACL；代价是 WebAssembly 全废，于是有了 `fetch-shim`。
6. **连桥 + 握手**（`:169-182`）。失败信息带 `stage=`（原生引导件卡在 dlopen/dlsym/stdio/start 哪一步）。

`node::Start` **每进程只能一次**，所以 `:92` 用 `runtime.isRunning()` 守卫：连接阶段失败后重试时
不能再投递一次，只能重连。

## 3. bootstrap.cjs 做了什么（835 行，按块读）

`host/bootstrap.cjs` 是唯一在 Node 里跑的第一段代码，`main()` 在 `:789`。它按固定顺序铺好垫片，
**然后才**去加载 dsh —— 顺序错了就白搭（见每个函数注释里的「Must run before …」）。
下表 1–9 是垫片，10 是启动前的最后一次改写：

| 顺序 | 函数 | 行 | 解决什么 |
|---|---|---|---|
| 1 | `rerouteConsole` | `:174` | stdout 要留给 JSON-RPC，console 全部改写进 `bridge.log` |
| 2 | `installRequireBuiltinAlias` | `:659` | `node-addon-require-builtin` 没有 openharmony 构建，别名到纯 JS 垫片（要 `--expose-internals`） |
| 3 | `installSharpStub` | `:771` | `sharp` 只有 darwin-arm64 / wasm32 绑定，设备上必炸；重定向到纯 JS 桩（图片原字节直通） |
| 4 | `installLinkFallback` | `:357` | 沙箱禁 hardlink（EACCES）→ 降级 `copyFile(COPYFILE_EXCL)` |
| 5 | `installDirSyncFallback` | `:400` | 祖先目录 `/data` 只读打开被拒 → 给个空壳 handle（否则内联图片每轮都报「unable to persist」） |
| 6 | `installUserStorageChmodFallback` | `:530` | `/storage/Users/` 这个 userfile 挂载不支持 chmod/chown，EPERM 一律吞掉 |
| 7 | `installUserStorageCopyFallback` | `:573` | 同一挂载上 libuv 的 FICLONE 回落到用户态循环 |
| 8 | `installFileHandleFallbacks` | `:444` | 目录 fsync 被拒、挂载不支持 mode 变更 → 只在目录/该挂载上容忍 |
| 9 | `installProfileTemplate` | `:728` | 把 `payload/profile-ohos/profiles/ohos` 按内容哈希装进 `$DSH_HOME/profiles/ohos` |
| 10 | **acp → ohos 重映射** | `:800` | 模板装好了就把 `DSH_PROFILE=acp` 改成 `ohos`：自定义 profile 才能 insert 新行 |

另有一处不在 `main()` 里：`installJitlessShims()`（`:188`）在 `boot()` 开头（`:299`）才跑，
先探 `typeof WebAssembly`，缺失才装 `fetch-shim` 并注册 ESM 的 `undici` 别名 —— 有 JIT 的桌面
环境自然跳过这一层。

然后是 `net.createServer`（`:811`）：

- **单客户端**：新连接 `replacing previous client` 顶掉旧的（`:812-815`）。
- `adoptSocket`（`:249`）把 socket 管道接进**进程级**的 `PassThrough`（`:240`），并用
  `Object.defineProperty` 覆盖 `process.stdin/stdout`（`:217`）——Node 24 里这俩是 getter-only 的访问器，
  直接赋值会抛。
- socket 断开只 pause 不 end（`:256-262`）：stdin EOF 会被 dsh 当成 shutdown，UI 掉线不能杀运行时。

`boot()`（`:268`）里真正拉起 dsh 的只有三行：

```js
const argv = [process.execPath, bin, '--profile', PROFILE, '--patch', …]  // :312
process.argv = argv                                                       // :325
const entry = await import(pathToFileURL(bin).href)                       // :329
await entry.runCli()                                                      // :335
```

两个坑写在这里：`bin.js` 只在 `import.meta.main` 为真时自执行，动态 import 永远为假，所以必须
显式调 `runCli()`；`runCli` 从 `process.argv` 解析，所以 `argv` 要先伪装成一条正常的命令行。

## 4. dsh 侧：runCli → runProfile → 挂载

载荷里 `node_modules/@deepseek-ai/dsh/lib/`（0.2.1-rc.4）：

- `bin.js:207` `runCli()`：commander 解析 → `profile` 模式 → `runProfile()`（`:215`）。
  它只认自己的旗标（`--profile` / `--patch` / `--dump-config`），其余原样交给被挂载的 app 插件。
- `profile-boot-*.js:255` `runProfile()`：`composeProfile()`（`:272`）把**补丁层**叠起来 ——
  `package.json` 的 `dsh.profile.bundles` 顺序、profile 自己的 `cordis.patch.yml`、
  `$DSH_HOME/cordis.patch.yml`、每个 `--patch` 覆盖层 —— 然后在 `:302` 用 cordis loader `boot()`
  把插件树挂起来。`runProfile` 的 promise 在树挂载后 resolve（dsh 自己的循环继续跑）。

profile 是 `host/profile-ohos/profiles/ohos/package.json`：

```json
"bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-acp-app", "@ohos/dsh-bundle-ohos"]
```

`@ohos/dsh-bundle-ohos/cordis.patch.yml` 才是鸿蒙适配的「插件表」：5 行 insert（纯 JS 搜索、
进程内 PTC、密钥热更新、时间上下文、boot 自检）、2 行 disable（ripgrep 搜索、stock ptc）、
`tools.mode = native`、以及 DeepSeek 模型目录覆写。

而 `host/patches/ohos.patch.yml` 是**平台禁用清单**（pwsh / plugin-manager / office / bash / jobs），
`entry/.../common/PluginConfig.ets:62` 生成的 `user.patch.yml` 是设置页开关，两者都作为 `--patch`
传入，后者在后、覆盖前者。

## 5. 「很多脚本」的分类表

| 什么时候跑 | 文件 | 角色 |
|---|---|---|
| 构建期（你敲命令时） | `scripts/assemble-payload.mjs` | npm 装 dsh → 拷 host/*.cjs → 拷 profile 模板与 patches → 打桩 flock → 压成 rawfile zip |
| 构建期 | `scripts/deploy.sh` / `build-release.sh` / `test.sh` | 签名、装机、三段验证；**不参与运行时** |
| 启动期（设备上，Node 里） | `host/bootstrap.cjs` | 桥 + stdio 劫持 + 9 个垫片 + profile 重映射 + 拉起 dsh |
| 运行期（被 dsh require 时） | `fetch-shim.cjs`、`undici-esm.mjs`/`undici-hooks.mjs`、`require-builtin-shim.cjs`、`sharp-stub.cjs` | jitless / 无原生模块 / 无 WASM 的替身 |
| 挂载期（YAML） | `patches/ohos.patch.yml`、`profile-ohos/.../cordis.patch.yml`、`$DSH_HOME/patches/user.patch.yml` | 插件行级别的开/关/改配置，不是代码 |
| 挂载期（小插件） | `host/profile-ohos/.../node_modules/@ohos/*` | 4 个进程内插件（搜索、PTC、密钥热更、boot 自检）+ 1 个 bundle 清单（`@ohos/dsh-bundle-ohos`，它就是上面那份 patch 的宿主） |

判据很简单：改 `.ets` 只影响 UI（重新 build 即可）；改 `host/` 下任何东西——包括那几个 YAML——
都必须先重跑 `assemble-payload` 再 build；只有设置页生成的 `user.patch.yml` 是运行期写的，不用重装。
`scripts/*.sh` 与运行时无关，它们只是把「装 / 签 / 跑 / 验」串起来。

### 5.1 为什么同时有 `.cjs` 和 `.mjs`

扩展名是**这个文件属于哪套模块系统**的硬声明，优先级高于 `package.json` 的 `type`：

| 扩展名 | 模块系统 | 谁决定 |
|---|---|---|
| `.cjs` | 永远 CommonJS | 扩展名 |
| `.mjs` | 永远 ESM | 扩展名 |
| `.js` | 看最近的 `package.json` 的 `type` | `"module"` → ESM，缺省/`"commonjs"` → CJS |

本仓三种都在用，而且都不是随手写的：

- **`host/*.cjs`（bootstrap / fetch-shim / sharp-stub / require-builtin-shim）**：要在 dsh 的 ESM
  import **之前**同步打补丁（`Module._load`、`Module._resolveFilename`、`fsp.link`、`process.stdin`），
  并且到处用 `__dirname`（ESM 里没有）。ESM 的命名导入是首次 import 时的**快照**，晚一步补丁
  就落不到 `import { link } from 'node:fs/promises'` 上——这正是 `installLinkFallback` 注释里
  "Must run before any ESM import" 的实际含义，不是风格问题。
- **`host/undici-esm.mjs` + `undici-hooks.mjs`**：必须 ESM。`module.register()` 注册的 resolve
  钩子本身按 ESM 加载，而它要拦的是 `await import('undici')`——那条路绕过
  `Module._resolveFilename`，CJS 补丁够不着。`undici-esm.mjs` 再用
  `import shim from './fetch-shim.cjs'` 把 ESM 请求转回**同一个** CJS 单例，避免两份 shim 各自持有
  dispatcher。
- **`scripts/*.mjs`**：仓库根**没有** `package.json`（那里的 `.js` 会默认成 CJS），所以用 `.mjs`
  明说；顺带拿到 top-level await 与 `import.meta.url`（`ROOT` 就是这么算的）。
- **载荷里的 `.js` 两种都出现**：`payload/package.json` 写 `"type": "commonjs"`，而 dsh 自己的
  `package.json` 是 `"type": "module"`——所以 `lib/bin.js` 里能直接写 `import`，同一个树里两套并存。

一句话记法：**`.cjs` 是「我要抢在别人加载前动手」，`.mjs` 是「我要参与 import 图」。**

## 6. 想快速读懂，按这个顺序读 6 个文件

| 顺序 | 文件 | 只看这些 |
|---|---|---|
| 1 | `entry/src/main/ets/host/NodeHost.ets` | `boot()` 全文（58-191）。全链路编排，90 行 |
| 2 | `host/bootstrap.cjs` | 文件头注释（1-17）、`main()`（789-835）、`boot()`（268-346）。垫片函数先只读注释 |
| 3 | `entry/src/main/ets/host/Payload.ets` | `ensure()`（21-49）。载荷怎么落地 |
| 4 | `host/profile-ohos/profiles/ohos/package.json` + `@ohos/dsh-bundle-ohos/cordis.patch.yml` | 插件树是「表」不是代码 |
| 5 | `entry/src/main/ets/model/DshClient.ets` | `connect()` / `initialize()` / 分帧解码。UI 与 dsh 之间只有 JSON-RPC |
| 6 | `scripts/assemble-payload.mjs` | 156 行全文。谁被塞进载荷、为什么 |

垫片（`fetch-shim` / `sharp-stub` / 那几个 `install*Fallback`）**不要先读**：它们每条对应一个真机
踩过的坑，读之前先看 `docs/ARCHITECTURE.md` 的平台约束表和 `AGENTS.md` §5，否则只有细节没有理由。

## 7. 出问题时看哪

| 现象 | 看这里 |
|---|---|
| 卡在「启动内嵌 Node 运行时」 | `node.log`（`filesDir/node.log`，原生桥写的，含 env dump） |
| 卡在「连接本地桥」 | `dsh-home/bridge-status.json` 的 `state` / `error`（`failed` 时还带 `profile`/`port`/`pid`/`node`/`wasm`），以及 `bridge.log` |
| 卡在「握手」 | `bridge.log` 里 `boot: …` 与 `boot failed:` 两行；`FAILED` 文案里的 `stage=` 来自原生引导件（dlopen/dlsym/stdio/start），`bridge-status.json` 里没有 |
| 起来了但工具不对 | `bridge.log` 里 `boot-report-ohos` 打的工具清单与 `web searchReady/fetchReady` |
| 图片发不出去 | `bridge.log` 里 `sharp-stub:` 与 `fsync dir fallback` 两类行 |

设置 → 诊断面板把 `tail(node.log)`、`bridge-status.json`、崩溃记录三样都读出来了，等价于上面三行。
