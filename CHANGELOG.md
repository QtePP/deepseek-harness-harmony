# 变更记录

本文件记录值得写下来的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- **三国裁判引擎** `@ohos/dsh-sanguo`：掷骰（xorshift32，状态存存档内，重载刷不了骰）、
  判成败（难度夹在 10–95，模型建议只作 hint）、算数值、推演势力、记人物记忆、算「势」。
  五个工具 `sanguo_new / status / choose / act / advance`。
- **三国棋盘原生视图** `SanguoBoardView.ets`：读 `.sanguo/life.json` 投影；手机顶部切换器单栏、
  平板 340vp 右栏双栏；选项在点击前就显示代价。
- **五个 Agent pack**（`agents/`）：`match-coach`、`openworld-guide`、`story-guide`、
  `sanguo-guide`、`sanguo-life`，配 `scripts/check-agent-pack.mjs` 校验。
- **商店截图** `store-assets/screenshots/`：5 张 1080×1920，从真机状态实拍合成。

### 修复

- **Flash 模型每一轮都发送失败**：上游 catalog 给 `deepseek-flash` 标了
  `toolUpdate: "addition-only"`，该路由会把全部工具标成 `deferLoading: true`，
  API 直接拒绝（`at least one tool must have defer_loading=false`）。
  改为在 ohos bundle 补丁里覆盖模型目录，去掉该字段；`inputModalities: [text, image]`
  与 1048576 上下文窗口显式重述，多模态不受影响。
- **一轮未结束时可重复发送**：服务端会回 `a prompt is already in flight`。
  `send()` 现在有同步闩锁（`await` 之前置位，`finally` 释放），发送按钮也在回合进行中禁用。
- **启动页署名位置**：`Powered by DeepSeek Harness` 从标题下方移到页面底部，字号 11vp、三级灰。

### 变更

- **包名** `com.example.dshharmony` → `com.qtepp.taharness`（`com.example` 是保留域名，
  AGC 不收）。`vendor` 改为 `qtepp`。
- **发布构建脚本** `scripts/build-release.sh`：校验 profile 与 bundleName 一致 → 注入发布签名 →
  `--build-mode release` → `trap` 兜底还原。
- **文档**：README 补首次启动必做两步（填 Key、切 ACP 并重启）、单实例限制、发布签名不能
  `hdc` 直装等边界；新增 `CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`、
  `THIRD-PARTY-NOTICES.md`、Issue 模板。

## [1.0.0] - 2026-10-31

首个版本：在鸿蒙设备上本地运行 DeepSeek Harness 的原生外壳。

### 包含

- 原生 ArkUI 客户端，覆盖手机 / 平板 / 2in1，840vp 断点切换单双栏
- 同进程内嵌 Node v24.2.0（NAPI `dlopen libnode.so` + `node::Start`），回环 TCP 桥
- 流式对话、工具轨迹（按功能分类、失败高亮）、产物面板与内嵌预览
- 回合回撤（并还原该轮写入的文件）、会话分支
- 项目隔离（每项目独立 workspace）、多模态图片输入
- API 密钥热更新、权限三档（沙箱与审批捆绑）
- 纯 JS 搜索套件（`glob`/`grep`，替代需要 spawn 的 stock 实现）
- 自定义 `ohos` profile：纯 JS 搜索、PTC 运行时、密钥热更新、时间上下文、能力自检

### 已知边界

- 无 token 级流式；无二进制工具面（`git`/`rg`/`bash`）
- `run_code` 仅支持 JavaScript，且当前默认未启用
- 设备端不做图片降采样，原尺寸上传由服务端投影
- 发布证书签名的 HAP 平台禁止 `hdc` 直装，只能经 AGC 分发

[Unreleased]: https://github.com/QtePP/deepseek-harness-harmony/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/QtePP/deepseek-harness-harmony/releases/tag/v1.0.0
