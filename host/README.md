# host/ — 端侧后端（Node 侧）

这两个文件会被 `scripts/assemble-payload.mjs` 拷进载荷根目录，随 HAP 分发，在
`libnode.so` 启动的进程内运行。

## bootstrap.cjs

1. 在 `127.0.0.1:4517`（`DSH_BRIDGE_PORT` 可覆盖）起一个 TCP 服务；
2. **首个客户端连入时**才真正启动 dsh——这样 stdout 从第一帧起就有接收方；
3. 把 `process.stdin` / `process.stdout` 换成 socket 支撑的 `PassThrough`，
   dsh 的 SDK profile 对此无感知（它只认「新行分隔的 JSON-RPC 字节流」）；
4. `import()` 载荷里的 `@deepseek-ai/dsh/lib/bin.js`，argv 为 `--profile sdk`。

设计要点：

- **不 fork 子进程**：鸿蒙沙箱禁止 exec，`node::Start` 也每进程只能一次，所以后端必须在
  本进程内挂载。
- **stdout 必须干净**：dsh 把 stdout 全留给协议帧，因此 `console.*` 被重定向到
  `<DSH_HOME>/bridge.log`。万一有漏网日志行，客户端解码时按「非 JSON 行丢弃」处理。
- **状态落盘**：`<DSH_HOME>/bridge-status.json` 记录 state / port / node 版本 / 是否有
  WASM / 错误栈，供设置页诊断读取。

## fetch-shim.cjs

`--jitless` 下 `WebAssembly === undefined`，Node 内置 `fetch`（undici + llhttp WASM）直接失效。
本文件提供：

- 纯 JS `fetch` / `Headers` / `Response` / `Request`，基于 `node:http(s)` 与 `node:stream/web`，
  支持 SSE 流式（body 是真 `ReadableStream`）、重定向、`AbortSignal`、`FormData` 之外的常见 body；
- `undici` 的 CommonJS 模块别名（`Module._resolveFilename` 钩子），以及 `Agent` /
  `setGlobalDispatcher` / `getGlobalDispatcher` 桩。

只在 `WebAssembly` 缺失时安装，JIT 形态下不介入。

## 已知未覆盖

- ESM 的 `import('undici')` 不走 `_resolveFilename`，需要 loader hook 才能拦；当前 dsh 的
  失败路径都是 CJS require，若上游改成纯 ESM 需要补 `--experimental-loader`。
- 鸿蒙 hmfs 上 `fsync` 目录与 `link()` 会返回 `EPERM`（发图/存附件时可见）。社区补丁见
  `Nanoar/dsh-hmos-fix` 的两个子补丁，本项目暂未内置。
