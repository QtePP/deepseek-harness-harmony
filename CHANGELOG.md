# 变更记录

本文件记录值得写下来的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- **对话字号四档**：设置 › 对话字号（小 / 标准 / 大 / 特大，0.9×–1.3×），即时生效并持久化。
  只缩放对话内容（正文、思考、工具行、Markdown），按钮与说明文字保持原尺寸；`Markdown` 的
  `InlineText` / `CodeText` 自行读 `AppStorage['fontScale']`，一处开关覆盖全部富文本。
- **分享卡（回复分享为图片）**：长按回复 ›「分享为图片」，用 `componentSnapshot` 把这条气泡渲染成
  PNG，再经 ShareKit 打开系统分享面板（真机实测：面板显示「分享 1 项 · 16.82 KB」）。
  **踩坑**：`SharedRecord.uri` 必须用 `fileUri.getUriFromPath()` 生成，手拼 `file:///data/...`
  会在 `show()` 时报 `IPC data is oversized`；图片分享被拒时自动退到「分享文字」。
- **桌面快捷方式「新对话」**：`shortcuts.json` + `ohos.ability.shortcuts` 元数据，want 携带
  `shortcutId`；`EntryAbility` 经 `AppStorage` 把请求交给页面，冷启动与 `onNewWant` 都能开新会话
  （已用 `aa start --ps shortcutId new_chat` 验证打开的是「新会话」）。**桌面长按菜单里没显示该
  快捷方式**：启动器缓存/版本行为，未深究；功能路径本身已通。
- **外观三档**：设置 › 外观（跟随系统 / 浅色 / 深色），选择持久化、**启动期生效**。
  暗色补齐了缺失的 4 个色 token（`code_header`、`code_border`、`status_success`、
  `status_danger`），暗色下代码块、状态色不再回落到浅色值。
- **六套主题色**：设置 › 主题色，深蓝 / 靛紫 / 青 / 松绿 / 琥珀 / 玫瑰，点一下即时生效并持久化。
  只换强调色（按钮、链接、选中行、上下文环、发送键），背景与气泡保持中性，暗色模式不用第二套表。
- **斜杠命令面板**：输入 `/` 弹出本地动作（新会话 / 模型 / 停止 / 清空排队 / 文件 / 会话 / 设置 /
  待办）。引擎命令（`/compact`、`/export`、`/goal`）在 ACP 下没有通道，不列出来当摆设。
- **`@` 文件引用**：输入 `@` 列出工作区文件（相对路径，最多 8 条，索引 4s TTL / 300 条上限），
  点选插入 `@路径` 继续写。
- **导出对话**：`/导出对话` 把当前会话写成 Markdown（含思考折叠块与工具表）存进
  `workspace/exports/`，文件面板与后续对话都能找到。ACP 没有 `session/export`，导出的就是
  App 手里那份转录——诚实清单。
- **目标条（只读）**：从 `create_goal` / `update_goal` 的参数投影出当前目标，常驻输入框上方：
  「目标 · 进行中 · <objective>」，完成/受阻后转灰。与待办条同一套思路——参数随轨迹持久化，
  冷启动重放即可，不需要 ACP 的投影通道；编辑动作（`goals/*`）在 ACP 下没有通道，所以只读。
- **重新回答**：长按回复 ›「重新回答（新会话）」——保留到该问题之前的对话，在新会话里重发同一个
  问题，原会话完整保留可对比。ACP 下服务端上下文从本轮重新开始，toast 会明说这一点。
- **完成摘要**：一轮结束后，轨迹条从「N 步」变成「已完成 · N 步 · 8.4s」（失败转红并写「有失败」，
  被取消写「已中断」），把整轮收成一行，与 dsh-go 的「过程折叠成一行」对齐。
- **凭据遮挡**：消息里出现 `sk-…`、GitHub token、AWS key、JWT、Bearer 值时，只显示前 8 位，
  气泡下方给「已隐藏 N 处凭据」小条，点一下显示原文。只遮挡渲染，存储、复制、重发都保留真值。
- **系统通知**：应用在后台时，一轮完成 / 出错 / 等待审批会发本地通知（`NotificationKit`）。
  首次需要授权时弹系统对话框；前台不发，避免在已看得见的答案上再叠一条通知。
- **保存图片到相册**：全屏查看图片时右上角是 `SaveButton` 安全组件——点它即授予临时媒体写权限，
  再 `createAsset` 落库，不需要申请 `WRITE_IMAGEVIDEO` 这类受限权限；长按对话里的图片直接进全屏。
- **插话队列（排队发送）**：回合进行中打字不再被丢弃。发送键在跑动时变成「排队」，消息落到
  输入框上方的排队条里，可单条撤回；回合结束（含停止、断线复附）后自动续发下一条。
  排队条上的「立即发送」会先取消当前轮再发出——ACP 没有 steering 通道，`session/prompt`
  在跑动中会被服务端拒绝（`a prompt is already in flight for this session`），所以「打断」
  是唯一诚实的语义。
- **待办条**：从模型 `todo_write` 的参数投影出待办清单，常驻输入框上方。折叠时一行
  「3/7 · 正在：…」，点开看全表（✓ / ● / ○ 三态，完成项划线）；全部完成时转绿。
  冷启动和切会话按持久化轨迹重建，不需要服务端投影通道。
- **上下文小环**：输入条右侧 22vp 圆环显示上下文占用（<70% 品牌蓝、≥70% 琥珀、≥90% 红），
  点开 toast 显示 `12k/128k · 9%` 的精确值。占用数据来自 `usage_update` 写在回复上的
  「上下文 used/size」注记，没有注记时不显示空环。
- **引用追问**：长按消息 ›「引用到输入框」，把该条正文前 6 行（≤400 字）以 `>` 引用块
  前缀进草稿，模型按引用块理解，用户仍可编辑。
- **会话搜索**：会话栏顶部搜索框（会话数 >0 时出现），按标题大小写不敏感过滤，
  空结果给一行「没有匹配的会话」而不是塌成空列表。
- **一条命令跑全部检查** `scripts/test.sh`：payload 单测 / ArkTS 检查 / LocalUnit / 设备端 ohosTest。
- **商店截图** `store-assets/screenshots/`：5 张 1080×1920，从真机状态实拍合成。

### 修复

- **重启后回答全部消失（只留提问）**（真机发现，严重）：`session/prompt` 的响应与
  `session/update` 的流是两帧，回合结束时的 `persist()` 跑在回复行创建**之前**，于是落盘的是
  「只有提问」的转录；回复随后渲染出来，却再也没有落盘。改为 settle 时先 `drainAcpUpdates()`
  把队列里的更新同步应用完再存；回合结束后才到的分片由 `drainAcpUpdates()` 自己补存一次。
  顺带修了错误行不落盘（发送失败的系统提示同样会丢）。
  **取证**：`Persist` 日志显示修复前 `n=8 u=8 a=0`（8 条全提问），修复后 `n=12 u=11 a=1`。
- **短会话停在顶部、下面一大片空白**（真机发现）：`scrollToIndex` 默认把目标项对齐到视口**顶部**，
  消息少时整段对话被顶到上面。改为 `ScrollAlign.END`。
- **对话里的图片长按没反应**（真机发现）：消息行自己挂了一个长按手势（操作菜单），子节点 `Image`
  上的普通 `LongPressGesture` 会被父手势吞掉。改成 `priorityGesture`。
- **全屏查看器的顶栏落在状态栏里**（真机发现）：`bindContentCover` 在本机是全屏绘制，顶栏
  （关闭 / 文件名 / 保存图片）被画进状态栏区域，点那里的事件被系统吃掉——保存按钮看得见、点不动。
  查看器启动时用 `window.getAvoidArea(TYPE_SYSTEM)` 量出状态栏高度并加到顶栏内边距。
- **切深色后界面全黑**（真机发现）：运行中调 `setColorMode` 会重建窗口，ArkUI 树留在空白状态。
  改为**启动期**应用：`EntryAbility.onCreate` 用同步 `getPreferencesSync` 读 `appearance`，
  在 `loadContent` 之前设定；设置页切换只落盘并提示「重启应用后生效」。
- **手机端 `/` 命令与 `@` 引用点了没反应**（真机发现）：`Index` 里宽屏与手机各有一处
  `ChatView` 调用，新增回调只接到了宽屏那处，手机端 `onClearQueue` / `onExport` /
  `onSearchFiles` 全部回落到组件的 no-op 默认值。两处已补齐，并在代码里写明「两个调用点必须同步」。
- **`@` 选择器永远不出现**（真机发现）：缓存键初值 `''` 与「刚输入 `@`」的空查询 `''` 相等，
  第一次查询被判成缓存命中，列表一直是空的。改为独立的有效性标记。
- **重新回答丢标题、并多出一条「服务端上下文不可用」**（真机发现）：发送时
  `messages.length === 0` 会无条件重命名会话，把「· 重答」覆盖掉；ACP 下又对临时本地 id 做
  `session/resume`，失败后追加系统提示。改为只在会话还没有名字时自动命名，ACP 下先
  `session/new` 再保存本地副本。
- **通知授权在后台必然失败**（真机发现）：`requestEnableNotification` 只能在应用可见时弹框。
  改为后台只记「待请求」，回到前台再请求；设置页新增「后台通知 › 开启」，失败时 toast 出原因
  并提示去系统设置打开。
- **设置页「保存」按钮不跟主题色**：默认系统蓝是唯一忽略强调色的控件，改为 accent。
- **Flash 模型每一轮都发送失败**：上游 catalog 给 `deepseek-flash` 标了
  `toolUpdate: "addition-only"`，该路由会把全部工具标成 `deferLoading: true`，
  API 直接拒绝（`at least one tool must have defer_loading=false`）。
  改为在 ohos bundle 补丁里覆盖模型目录，去掉该字段；`inputModalities: [text, image]`
  与 1048576 上下文窗口显式重述，多模态不受影响。
- **一轮未结束时可重复发送**：服务端会回 `a prompt is already in flight`。
  `send()` 的同步闩锁（`await` 之前置位，`finally` 释放）保留；但不再靠「禁用发送键」
  回避——跑动中的发送改为入队，闩锁释放后由 `flushQueue()` 续发。
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
