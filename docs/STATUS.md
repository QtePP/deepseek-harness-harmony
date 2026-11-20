# STATUS.md — 真机验收与状态日志

> 本文件是 `AGENTS.md` §7 的**证据日志**：每项能力在哪台设备、哪次构建上验过、结论是什么、
> 踩了哪些坑、代价多大。**大致按时间倒序**（新的在上）。
>
> **口径不在这里**：术语、协议契约、平台约束、签名规则都在 `AGENTS.md`（唯一权威）。
> 本文件只回答「验过没有、怎么验的、发现了什么」。新增验收记录请写在这里，并在
> `AGENTS.md` §7 的摘要里更新一句——两处同一 commit 改。
>
> 载荷里的 `payload/docs/` 是构建期快照（`assemble-payload.mjs` 的 `stageDocs()` 拷 `docs/*.md`），
> 权威副本始终是本文件。

---

- **`git` 工具真机第二轮：又两个缺陷，其中一个是「上一轮修错了」（2026-11-20 15:22，MatePad Mini）**。
  把上一轮的三条文案改进重新部署后再让模型跑一遍，并从设备会话日志（`session.v4.jsonl.zstd`）取**原始
  返回文本**核对，不只看模型复述：
  - 三条文案确实变了（`diff` → `GIT_NO_HISTORY` 带根因；`pull` → 指明 `snapshot` + `force=true`；
    `clone` 已存在 → 同样指向 `force`），`log limit=3` 仍返回 `1 commit … 228436f`。
  - **新缺陷 1：文案让模型「删掉再重跑」，但设备上没有删目录的手段。** 26 个工具里没有 `rm`、没有
    `bash`、没有 shell——模型做不到，用户也做不到，而我们自己写的话把死路说成了出路。修法：`git`
    工具自己加 `force` 开关（它建的目录它自己删），三条文案全部改指 `force=true`。
  - **新缺陷 2（严重，上一轮改错的正是它）：`diff` 的默认 `HEAD~1` 在任何仓库上都不成立**，不是只有
    depth-1 快照。本地 `--jitless` 探针在 **128 个 commit 的全量 clone** 上直接证明：
    `isomorphic-git` 的 `resolveRef` **根本不实现 ancestry 语法**——`HEAD~1`、`HEAD^` 都抛
    `NotFoundError`；同一条提交用 oid 或 `main` 都能解析。也就是说上一轮「提前报 GIT_NO_HISTORY、
    建议 clone 全量历史」的诊断和建议**双双错误**：全量 clone 照样失败。
    修法：自己走父链（`resolveRev`），并**逐步校验父提交真的在对象库里**——shallow clone 的 commit
    对象**仍记录父 oid，但父本身不在库里**（实测 `parent NOT in object store: NotFoundError`），
    盲目跟指针会得到一个「能查出 oid、稍后在 js-git 里才炸且不报原因」的引用。
  **验证（本地，`--jitless`）**：全量 clone 上 `HEAD`/`HEAD~1`/`HEAD~3`/`main` 全部解析成功，
  `HEAD~1..HEAD` 走出 **4 条真实改动路径**；depth-1 快照上 `HEAD~1` 立刻给
  `GIT_NO_HISTORY: HEAD has fewer than 1 commit of history here …`。`force` replace 也实测：
  snapshot（shallow=true, 1 commit）→ `force` clone（shallow=false, **128 commits**）。
  单测 25 → **32**（6 条 `resolveRev` 用例，含「父提交不在库里」这一条）；六套件合计 **120**。
  **方法论教训**：上一轮我接受了模型对文案的解读就改代码，没在本地跑一遍 `diff` 的真实路径——
  于是把「所有仓库都失败」误诊成「只有快照失败」。**给模型的建议本身也是代码，必须实测**，
  不能靠读起来合理。

- **`git` 工具真机端到端：三个缺陷（2026-11-20 14:58–15:03，MatePad Mini）**。这一轮全部通过**模型**
  亲口触发（不是脚本调 API），共四轮：
  ①`log limit=3` → `1 commit in qtepp-deepseek-harness-harmony` + `228436f 2026-11-20 Instrument …`；
  ②`status` → `qtepp-deepseek-harness-harmony is clean (159 paths)`；
  ③三条守卫按名触发，错误都是单行、无堆栈——`pull` → `GIT_SHALLOW`、`clone` 已存在 → `GIT_EXISTS`、
  `action=sync` → `GIT_BAD_ACTION`（错误里列全 6 个合法 action）；
  ④`snapshot microsoft/vscode` → `GIT_TOO_LARGE`，`repos/` 下**没有**留下 `microsoft-vscode/` 半成品，
  前一份 depth-1 副本完好（159 路径 / 228436f），平板没被撑爆。
  **模型从错误文案里读出了三个真问题**（它写进了回答，我们据此改代码，这是本轮最有价值的产出）：
  - **超限发生在传输中途，文案却写成先验判断**。原文案 `needs more than 50 MB of packfile` 被理解成
    「事先探测到大小再拒绝」，模型据此对用户说「没有下载任何 pack 字节」。实测（本地 `--jitless` 探针，
    上限 5MB）是**真流式 abort**：`cap hit at 6299474 bytes` / 16.5s，即越过 6,291,456 之后立刻断连。
    改法：`tooLargeMessage()` 明说 `exceeded the N MB limit after X of transfer, so the connection was
    aborted mid-stream and the partial tree was deleted`，且删掉 `needs more than` 措辞。
  - **`pull` 与 `clone` 的建议互相打架**：`pull` 说「delete it and clone again」，`clone` 说「use action
    pull」。对一个 depth-1 副本，这条闭环是死的。改法：两处文案各自说清分支（full history → pull；
    snapshot → 删了重跑 snapshot；确实需要历史才 clone），并加 `existsMessage()` / `shallowMessage()`
    两个纯函数 + 5 条断言（含「不许出现 needs more than」）。
  - **`diff` 默认 `HEAD~1` 在 depth-1 副本上必然失败**，报的还是 `Could not find HEAD~1`——看起来像仓库坏了。
    改法：默认 base 且存在 `.git/shallow` 时提前抛 `GIT_NO_HISTORY`，说明「只有一个 commit，没有 HEAD~1，
    请显式传 base=/head=，或 clone 全量历史」。**未改默认行为**（显式传 base/head 仍然可用，模型当场验过）。
  单测 20 → **25**；六套件合计 108 → **113**。**契约**：这类"给模型看的拒绝文案"属于产品表面，
  必须可测——模型会把它们复述给用户，措辞错了就是我们在骗用户。

- **平板重装新载荷（2026-11-20 14:56，MatePad Mini / tablet）**：`assemble-payload` 重打后 zip
  **239,893,674 B**（+17.3KB；相对上一份的唯一变化是 `glob` 描述与新增的 `docs/STATUS.md`），
  `deploy.sh` 覆盖安装直接成功——**签名没再轮换，所以没有 `9568332`**；安装保留数据 ⇒
  **没有首启提问**（`profile_prompted` 仍在）。解包后逐项核对：`payload.stamp` = 新长度；
  `payload/docs` = **18 个**（含 STATUS.md）；设备上 `dsh-tool-fs-search-js/index.js` 已含新描述；
  `bridge-status.json` 仍 `profile: ohos` / `node: v24.2.0` / `wasm: false`；`bridge.log` 给
  **`tools(26)`（含 `git`）** 与 `search=auto (deepseek-official for deepseek-official)`。
  界面实拍：双栏成立，上一轮 git 会话原样还在（轨迹条「有失败 · 9 步 · 17.0s」就是那次超时重试）。

- 已交付并真机验证：冷启动恢复、会话 resume、文件预览（网页/图片/文本）、能力开关、
  项目分类（创建/切换真机验证，每项目独立 workspace）。
- **聊天体验对齐 dsh-go（2026-11-12，纯客户端，无协议改动）**：①**插话队列**——跑动中发送
  改为入队（`Index.queued` + `flushQueue()`），输入框上方排队条可单条撤回，「立即发送」先
  `session/cancel` 再续发（ACP 无 steering，见 §4.2）；②**待办条**——`todo_write` 参数投影成
  `TodoItem[]`（`model/TodoModel.ets`），常驻输入框上方，冷启动/切会话按持久化轨迹
  `refreshTodos()` 重建，不依赖服务端投影通道；③**上下文小环**——从 `usage_update` 的
  「上下文 used/size」注记算占用率（70%/90% 两档变色），点开 toast 给精确值；④**引用追问**
  ——长按消息 ›「引用到输入框」生成 `>` 引用块；⑤**会话搜索**——会话栏顶部按标题过滤；
  ⑥**目标条（只读）**——`create_goal`/`update_goal` 参数投影（`model/GoalModel.ets`），与待办条
  同法重建，编辑动作在 ACP 无通道故只读；⑦**重新回答**——保留到该问题前的历史，新会话重发，
  原会话不动（ACP 服务端上下文从本轮重启，toast 明说）；⑧**完成摘要**——轨迹条收成
  「已完成 · N 步 · 8.4s」，失败/中断分别转红与标注；⑨**凭据遮挡**——`common/SecretMask.ets`
  只遮挡渲染（前 8 位 + 可展开），存储/复制/重发保真；⑩**系统通知**——后台时一轮完成/出错/
  待审批发本地通知（`common/Notify.ets`，前台不发、首次用才要授权）；⑪**图片存相册**——
  全屏查看器用 `SaveButton` 安全组件换临时媒体写权限再 `createAsset`，不申请受限权限
  （`common/Gallery.ets`）；⑫**斜杠命令面板**——`/` 只映射本地动作（8 条），引擎命令 ACP 无通道
  故不列（含 `导出对话`：`model/Export.ets` 把转录写成 Markdown 存进 `workspace/exports/`，
  因为 ACP 没有 `session/export`）；⑬**`@` 文件引用**——`common/WorkspaceFiles.ets` 索引工作区（深度 3 / 300 条 / 跳过
  node_modules 等），4s TTL，插入相对路径；⑭**六套主题色**——`common/Theme.ets` +
  `AppStorage['accent']`，9 个组件 `@StorageLink('accent')` 绑定，只换强调色、背景保持中性。
  **语音输入 / 朗读：上一版结论已勘误（2026-11-15）**。旧文写「本机 SDK 不含 `@kit.CoreSpeechKit`」，
  实测**存在**：`<DevEco>/sdk/default/hms/ets/kits/@kit.CoreSpeechKit.d.ts` 提供
  `speechRecognizer`（离线、中文、since 4.1.0）与 `textToSpeech`（中英、三种音色）；
  写一个 `import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit'` 的探针文件，
  `devecocli check arkts` 直接通过。**因此语音输入与朗读是 A 级（纯客户端可做），不是 C 级**，
  真机还需确认设备带 `SystemCapability.AI.SpeechRecognizer` / `SystemCapability.AI.TextToSpeech`。
  旧结论错在只看 `openharmony/ets/kits`，没看 `hms/ets/kits`。
  **已实现并真机验（2026-11-16，平板 MatePad Mini）**：`common/Speech.ets` + `common/ReadAloud.ets`。
  （该设备当时记为「手机」，2026-11-20 查明是平板，见 §6 设备身份。）
  真机结论：**syscap 在、引擎起不来**——麦克风按钮渲染出来了（说明 `canIUse` 为真）、授权弹窗与
  我们写的理由串正常显示，但 `createEngine` 返回 **1002200001**（设备日志 `AI_COMMON:
  CreateEngineErrorByCallback Failed to create engine [callback]`）；朗读同样，
  `AI_TEXT: Create Engine Error! engineNo 0`。两者都指向**离线中文语音包/系统语音包未安装**
  （模型是单独下载项，不在 App 内）。**降级已验证**：识别失败后按钮立刻隐藏，并把
  `speech_asr_usable=false` 写进 preferences，重启后不再出现（实测 force-stop 重启后按钮消失）；
  toast 文案「语音引擎启动失败（1002200001）：可能缺少离线中文语音包」。
  **复位入口（已真机验，2026-11-16，CMM-AL10 / API 26）**：设置页在 `!speechAsrUsable` 时显示「语音输入 / 重试」一行，点重试清标志并写
  `AppStorage['speechAsrUsable']`——`ChatView` 用 `@StorageLink` 绑这个 key，所以装好语音包后
  **不用重装 App**，回对话就有麦克风。**设备限制记录**：另一台旧平板装不上
  （`code:9568297 install failed due to older sdk version`），只有手机能跑。
  **重试流程已真机验**：点麦克风 → 授权 → 引擎失败 → 输入框麦克风消失 → 设置出现
  「语音输入 / 上次引擎启动失败，装好离线语音包后点右边重试 [重试]」→ 点重试 → 该行消失 →
  回对话麦克风回来（**未重装、未重启**）。
  **工具表差异的结论**：新手机 boot-report 是 `tools(21)`、缺 `read/write/edit/read_image`，
  一度怀疑是升级回归；查 `files/patches/user.patch.yml` 发现是本机**能力开关把 `tool-fs` 关了**
  （`- id: tool-fs / disabled: true`）——不是 bug，是开关生效。旧手机那份 patch 没关，所以 25 个。
  麦克风按钮仅在 `canIUse('SystemCapability.AI.SpeechRecognizer')` 为真时渲染；朗读入口在长按菜单，
  同样先查 `SystemCapability.AI.TextToSpeech`。**API 签名坑**：`startListening` 的 `StartParams`
  必填 `audioInfo{audioType:'pcm',sampleRate:16000,soundChannel:1,sampleBit:16}`；
  `finish(sessionId)` 必须传回会话 id；`speak(text,{requestId})` 的回调挂在 `engine.setListener` 上
  （不是 speak 的第二个参数）。`spokenForm()` 5 个单测。真机验收待设备在线。
  本地验证：`bash scripts/test.sh arkts local` 全绿（arkts 40 文件 + LocalUnit 通过；
  `entry/src/test/LocalUnit.test.ets` 覆盖 `SecretMask` / `Typography` / `TodoModel` / `GoalModel` /
  `TimelineNode` / `Rollback`（纯函数部分）六个模块，共 27 个用例）。
  **真机验收（2026-11-12，手机，ACP profile，`scripts/deploy.sh` 调试签名）**：冷启与安装正常；
  通过的有——`/` 命令面板（9 条）、`@` 文件选择与插入（相对路径）、`/导出对话`（真实写出
  `workspace/exports/<标题>-<时间>.md`，模型随后能读到）、待办条（3/3 全绿）、目标条
  （进行中 → 已完成）、完成摘要（`已完成 · N 步 · 2.6s`）、上下文小环、凭据遮挡
  （`sk-abcde…` + 「已隐藏 1 处凭据」）、排队（跑动中入队、settle 后自动发出，模型确认收到）、
  主题切换（琥珀，重启后保持）、重新回答（新会话「· 重答」）、长按菜单五项。
  **外观三档（跟随系统/浅色/深色）已真机验成**：浅色与深色均重启后保持；**暗色必须在启动期应用**
  ——运行中 `setColorMode` 会重建窗口并让 ArkUI 树变黑屏（真机实测），因此 `EntryAbility.onCreate`
  用 `getPreferencesSync` 先读 `appearance` 再 `loadContent`，设置页只落盘 + 提示重启。
  **桌面快捷方式「新对话」**：`shortcuts.json`（profile）+ `ohos.ability.shortcuts` 元数据 +
  `AppStorage['pendingShortcut']` 交给页面；`aa start --ps shortcutId new_chat` 实测打开「新会话」。
  桌面长按菜单未显示该条目（启动器行为），功能路径已验证。
  **图片存相册已真机验成（真手）**：长按对话图片 → 全屏查看器（修了父手势吞子手势与顶栏落进
  状态栏两个真机缺陷）→ 点「保存图片」→ 弹出系统授权框 → toast「已保存到相册」。
  **自动化点不动它**：`SaveButton` 是安全组件，`uitest` 注入点击不触发授权，只能真手验。
  **分享卡已真机验成**：长按回复 ›「分享为图片」→ 系统分享面板显示「分享 1 项 · 16.82 KB」；
  记录一条契约：`SharedRecord.uri` 必须用 `fileUri.getUriFromPath()`，手拼 `file:///data/...`
  会被 `show()` 以 `IPC data is oversized` 拒绝。
  **对话字号四档已真机验成**：设置 › 对话字号切「特大」后气泡文字高度 52px → 68px（1.3×），
  Markdown 正文与代码块同步放大，按钮/说明文字不变。
  **重启丢回复已修（真机发现，严重）**：`session/prompt` 响应与 `session/update` 流分帧到达，
  回合结束的 `persist()` 早于回复行创建 ⇒ 落盘只有提问。改为 `settlePersist()`（先
  `drainAcpUpdates()` 再存）+ `drainAcpUpdates()` 在 `!turnInFlight` 时补存。日志取证：
  修前 `n=8 u=8 a=0`，修后 `n=12 u=11 a=1`，重启后回复仍在。
  **子代理独立成类已真机验成**：`subagent` 调用有专属动词/颜色/图标，回合摘要显示
  「已完成 · 5 步 · 1 子代理 · 3.3s」，展开轨迹里那一行写着「子代理 | subagent」。
  **会话未读标记（渲染与清除已真机验成）**：停应用后往真实 preferences 的 index 行写
  `unread: true`，重启打开 rail → 该行右侧出现强调色圆点；点开该会话 → 圆点消失，存储里
  `unread` 变回 `false`。**自动置位那一半（回合进行中切走）只有代码路径，未真机复现**——
  多次尝试都赶在回合结束之后。
  **会话置顶已真机验成**：长按 ›「置顶」后该会话跳到列表首位、标题前出现「置顶」标签；排序为
  「置顶优先、再按更新时间」。**记录一条设备契约**：`sys.symbol.pin` 编译期能解析、运行期不绘制
  （`person_2` 等其它符号正常），凡是「图标缺失就看不出来」的语义都不要只靠 SymbolGlyph。
  **会话归档已真机验成**：长按 ›「归档」后该会话从默认列表消失、标题旁出现「已归档 1」；
  点它切到归档视图（标题变「已归档」、旁边「返回」），里面只有被归档的那条；长按 ›「取消归档」
  后归档视图变空并提示「没有已归档的会话」，返回默认列表该会话已复原。归档是视图过滤，
  转录与工作区文件不动。
  **每轮用量已真机验成**：注记显示「上下文 5126/1048576 · 本轮 +92」；上下文小环仍然渲染
  （`Progress` 节点存在即证明解析没被后缀打断）。**契约**：注记是「前缀 + 数字/数字 + 可选后缀」，
  任何解析它的地方都必须只取开头数字（`leadingNumber`），别用 `Number()` 整段转换。
  **会话多选已真机验成（批量归档方向）**：标题旁「选择」→ 行首出现勾选圈、底部「归档 0 / 删除 0」
  置灰；勾两行 → 「已选 2」、按钮变「归档 2 / 删除 2」并可点；点「归档 2」→ 两条从列表消失、
  标题旁变「已归档 2」。随后在归档视图里逐条「取消归档」，恢复原状、归档视图显示
  「没有已归档的会话」。**批量「取消归档」走同一按钮（归档视图里即取消）但未单独点过**；
  批量删除未点过（会真删数据，留给用户自己决定）。
  **会话内容搜索已真机验成**：搜「微内核」→ 标题无匹配、内容匹配 1 条（答 · 图片请求 +
  「…鸿蒙微内核、Linux 内核与 LiteOS…」），点结果进入该会话。**边界写死**：只扫
  `SessionStore` 缓存（每会话 200 条），不读服务端 zstd 日志——UI 上不要暗示「全部历史」。
  **自动化任务（schedule）已实测关闭为「不可行」**：把 `schedule` + `tool-schedule` 两行插进
  ohos bundle 后重打载荷、本地起 runtime，日志给的是
  `schedule (@deepseek-ai/dsh-schedule): pending (waiting for service: sessionController)`——
  它依赖 `@deepseek-ai/dsh-api-session-controller`（32 个 peer 依赖，含 `dsh-api-gateway` 整套
  HTTP 面），不是「补个插件」能补的，缺的是宿主服务。两行已回滚、载荷已重打、本地启动回到
  零警告。**方法论**：先本地 `--profile ohos` 起一次 runtime 看挂载结果，再决定要不要装机。
  **消息文件 chip 重复已修（用户真机发现）**：同一文件在消息里被写成
  `file:///data/…/x.html` 与 `x.html` 时出了三个 chip（chip 只显示 basename，看起来一模一样）。
  `refsFromText` 原来只按完整路径字符串去重，现在「一条是另一条的 `/` 边界后缀」即折叠；
  同名不同目录仍分开。**契约**：chip 展示的是 basename，所以去重键必须比展示名更粗——按路径
  精确去重等于没去重。真机验成：该会话从 3 个 chip 变 1 个。
  **会话详情已真机验（2026-11-16）**：`/会话详情` 弹出，读到「上下文 39508 / 1048576（4%）」
  「9 步」「没有待办」「没有目标」「1 个：grandpa-fitness-plan.html」。
  **会话详情（原记录）**：`/会话详情` → `detailSheet()`，一页汇总上下文 / 轨迹（步数·失败·子代理）/
  待办 / 目标 / **改动文件**（复用 `pathsInToolInput`，与回撤同一批路径）/ 产物数。纯只读，无协议改动。
  **用量统计已真机验（2026-11-16）**：发一轮后设备 preferences `dsh_usage` 里是
  `<string key="ledger">[{"day":"2026-11-16","tokens":573,"turns":1}]</string>`，与注记
  「本轮 +573」一致；装后首启显示「还没有记录」（空态正确）。
  **用量统计（原记录）**：`model/Usage.ets` 把每轮 `usage_update` 的 delta 累计成日账本
  （preferences `dsh_usage`，保留 60 天，跨会话），设置页显示「今天 +X · 近 7 天 +Y」。
  **契约**：delta≤0 时只计轮次、不计 token——上下文注记本来就只在真实增长时报 delta，
  记 0 会造出「有轮次没用量」的空行。7 个单测；真机验收待设备在线。
  **本地模型扫描（2026-11-16 真机验成一半）**：设置 ›「本地模型」›「扫描」在 CMM-AL10 上跑通——
  按钮进入「扫描中…」、逐个探 12 个端口、结束后渲染结论。本机结论是
  「没有发现：端口 8080 / 8000 / 11434 / 1234 等都没有响应 /v1/models」，与 hdc 侧取证一致
  （该机监听端口只有 4517/33985/51108 和几个系统随机口，306 个应用里无本地推理 App）。
  **接入路径未验**：没有真实服务可接，`llm-pi-ai` 路由写入后「模型出现在选择器」这一步只有代码、
  没有证据。**契约**：`llm-pi-ai` 由 dsh-base 挂载但空转（`providers` 为空则零路由），
  block 里 `api: openai-completions` 是本地服务通用协议；`apiKeyEnv` **不要写**——环回服务不鉴权，
  编一个运行期读不到的 env 名反而会让路由校验失败。
  **`.credentials.yaml` 权限导致启动失败（2026-11-19 真机发现，严重）**：升级到 0.2.2 后
  `dsh-credentials-local` 载入时 `assertOwnerOnly` 拒绝 644 的文件，报
  `dsh: startup failed: 1 required plugin did not activate` / `Failed plugins (1): credentials`，
  于是**每次启动都失败**。根因是它自己首次写盘用的默认 mode 644。
  修法：`bootstrap.cjs` 的 `tightenKeyFile()` 从只收 `.api-key` 扩展到同时收 `.credentials.yaml`
  并打印原 mode。**契约**：ArkTS 没有 chmod API，这个窗口只能在 Node 起来后关，
  所以**首次运行仍会留下 644**，靠下一次启动修好；hdc 侧也 chmod 不了（`Operation not permitted`）。
  **通知未验成**：设备 `allowEnableNotification=false`，`requestEnableNotification` 既不弹框
  也不改状态，需在 系统设置 › 通知 › TA Harness 手动打开后再验。真机暴露并修掉的 4 个缺陷见
  `CHANGELOG.md`（手机端回调缺失、`@` 缓存键、重答标题/多余提示、通知授权时机）。
- **0.2.2-rc.5 + 首启引导已真机闭环（2026-11-20，手机）**：装机后首启弹出「选择运行模式」，
  点「用 ACP」→ **同一次启动**即以 `--profile ohos` 挂载（`bridge-status.json` 的
  `profile: ohos`、`node: v24.2.0`、`wasm: false`），**不需要重启**——提问发生在 `boot()` 之前。
  `bridge.log` 两条关键行与本地一致：`tools(25)` 与
  `web: search=auto (deepseek-official for deepseek-official)`（不再误报 ambiguous）。
  **真实一轮搜索跑通**：`web_search`×4 + `web_fetch`×1，模型给出带来源的一句话结论；会话日志里
  `web/deepseek-search-llm-request` **出现 10 次**、端点是 `https://api.deepseek.com/anthropic/v1/messages`
  ——证明 rc.5 的**服务端 Messages 搜索**路径在设备上成立（旧 Search API 不会追加该事件），
  且 fetch-shim 扛得住这个新请求形态。同轮快照：`sandbox/mode=workspace-write`、`approval/policy=ask`。
  **装机坑（新设备必踩）**：`build-profile.signing.json5` 里的 DevEco 加密密码会与
  `~/.ohos/config/` 下的 `.p12` 失配（报 `11014003 Init keystore failed / keystore password was
  incorrect`）。修法是 `devecocli signature generate --force` 重新生成，然后把新的
  `build-profile.json5` 覆盖到 `build-profile.signing.json5` 备份、再 `git checkout
  build-profile.json5`。注意它复用了同一组文件名（哈希后缀相同）——**覆盖的是内容**，这正是旧
  备份密文对不上的原因。

- **第二次装机（2026-11-20，含 docs 载荷 + 通知诊断）**：重打包后 `payload/docs/` 带 **17 个
  markdown**（当时计数；本文件搬进来后是 **18**。构建期快照，权威副本仍在仓库；`assemble-payload.mjs`
  的 `stageDocs()` 拷 `docs/*.md`）。
  重装后**首启不再问运行模式**（`profile_prompted` 跨重装保留），`bridge-status.json` 仍是
  `profile: ohos`，`tools(25)` / `search=auto (…)` 不变。**踩到一个装机的顺序坑**：`aa start` 对
  **仍在后台运行**的应用只是「拉到前台」，不会重跑 `Index.init()` ⇒ 新载荷解包不会发生
  （`payload.stamp` 仍是旧 zip 长度）。换载荷后必须 `aa force-stop` 再启动，或从桌面冷启。
  **通知：发得出去，进不了当前用户的列表**。hilog 实证系统侧收到了它——
  `NotificationParserFactory: Parse notification __100_20020319_com.qtepp.taharness__4517 … appLabel:"TA Harness"`、
  `NotificationDataManager: SaveNtf …, isUpdate: true`——但紧接着
  `Parse … failed, invalid creatorUserId: 100`（`currentUserId: 101`，`errorCodes:[999]`，`check data fail`），
  通知面板里因此看不到卡片。根因是**设备的用户态**：应用 uid `20020319`（user 100）与当前界面用户 101 不一致，
  公开 API 里**没有** `creatorUserId` 字段可以覆盖，我们改不了。待确认的一处：我们的请求没设
  `notificationSlotType`（日志 `slotType: 65535`），下一轮换一台单用户设备时顺手补上再验。
  为定位这类「静默丢弃」，`Notify.publish()` 现在会 `hilog` 一行 attempt/enabled/published。

- **`git` 工具已交付（2026-11-20，本地闭环 + 平板真机闭环）**：HarmonyOS 没有 `git` 二进制，也不可能有
  （禁 fork/exec），但"把仓库搬到手机上"这一步可以用纯 JS 补上。spike 先证明可行——`node --jitless`
  下 `wasm: false`，2MB 与 **92MB** packfile 都 clone 成功——再按实测设计成 `@ohos/dsh-tool-git`
  （六动作，`repos/<slug>`，走 bundle-insert）。**三个 spike 结论写进了代码**：内存 ≈100MB + 11×pack
  ⇒ `maxPackMb` 默认 50 且**中途 abort**（vscode 在 1MB 上限下 6.1s 触发 `GIT_TOO_LARGE` 并清掉半成品）；
  shallow 仓 pull 会撞 js-git 的 `TypeError` ⇒ `GIT_SHALLOW` 提前拒绝；js-git 的 `onProgress` 只报
  **对象数**不是字节 ⇒ HTTP 客户端自己写（`http.js`，字节计数 + 冲刷 + 超时），顺带解除了"必须靠全局
  fetch-shim"的耦合。**挂载实证**：`--profile ohos` 冒烟从 `tools(25)` 变 **`tools(26)`**，`git` 在表里；
  `--dump-config` 有 `- id: tool-git`。**本地验证**：插件单测 20/20（六个套件合计 108）+ 真实网络
  端到端（snapshot 2.0MB/7s、log 1 条、status 159 条目 clean、4 条守卫全部按预期失败）。
  **两处踩过的坑**：①`ctx.systemPrompt.getSectionOrder("TOOL_GIT")` 返回 undefined，section API 直接
  拒绝（`order must be a finite number`）⇒ 整个插件没挂载、工具表停在 25——所以不写 systemPrompt 段，
  引导语移进工具 description；②`Span`/`Text` 之外这次是**参数归一化**：`repo.git/` 要先剥斜杠再剥
  `.git`，否则网盘式地址会带后缀进 slug（单测抓到）。**真机闭环见下一条平板记录**：`clone` 一次
  `request to github.com timed out` 后重试成功（真实流量走过超时/重试路径），随后 `glob`/`read` 完成分析。

- **平板整机重装 + 链接点击 + `git` 端到端（2026-11-20，MatePad Mini / tablet / API 26）**：
  换设备后装不上，报 `code:9568332 install sign info inconsistent`——`signature generate --force`
  轮换过签名身份，机上旧包与新证书不同源。**契约：改过签名就不能覆盖安装，必须先卸**：
  `hdc shell bm uninstall -n com.qtepp.taharness`（带 `-k` 保留数据；不带 `-k` 全清）。
  本次按用户选择**全清重装**，因此 `profile_prompted` 也被清掉 ⇒ 首启重新问了一次运行模式（预期行为，
  不是回归）。重装后归档：`bridge-status.json` 给 `profile: ohos` / `node: v24.2.0` / `wasm: false`；
  `bridge.log` 给 **`tools(26)`（含 `git`）** 与 `search=auto (deepseek-official for deepseek-official)`，
  与之前设备记录一致；`devicetype=tablet` ⇒ ≥840vp 双栏（会话栏 + 对话）成立。
  **`git` 真机端到端**：模型自己 `git clone` 本仓库到 `repos/qtepp-deepseek-harness-harmony`
  （首次 `Error: request to github.com timed out`，重试成功——超时/重试路径被真实流量走过），
  随后用 `glob`/`read` 分析并答出沙箱四层；回答里把这次 clone 描述成「depth-1 snapshot，不能 pull」，
  与 `snapshot` 的语义一致。
  **`glob` 锚点语义由此写进 description（同一 commit）**：带分隔符的 pattern 锚在**会话工作区**，
  `path` 只缩小搜索范围、不改变锚点；两者同用时按「`path` 相对」理解会漏文件。
  **链接点击两条路径真机验成**：单链接（`m.pcpop.com/article_6958496.html`）→ 直接交给系统浏览器打开；
  一句多链接（转载 / 凤凰网 / 人民政协网）→ 弹「打开链接」选择框（标题下写明「这段文字里有多个链接」），
  选「凤凰网」后打开该文。**契约**：`Span` 没有 onClick、ArkUI 也没有 span 级命中测，只能用整段
  `Text` 接管点击；`linksOf()` 返回 1 条直开、≥2 条才弹框，否则就是「点了没反应」或「选错」。

- **官方 dsh 上游已核对（2026-11-15）**：`deepseek-ai/deepseek-harness` master `39163dd3`
  = `dsh` **0.2.2-rc.3**，我们载荷钉的是 0.2.1-rc.4。**ACP 协议面没变**（9 方法 +
  `$/cancel_request`、5 种 `session/update`、`session/request_permission`），客户端无需改动。
  官方 ACP README 明确写「intentionally exposes only the standard ACP v1 surface」，
  并点名 DSH 专有的 cards / plans / titles / todos / terminal views **不在 ACP 里**——
  这为我们「从 tool_call 反推待办/目标」的做法提供了官方依据。工具面差异与新工具见
  `docs/DSH-GO-PARITY-V2.md` §11.5。
- **升级后工具表已本地实测（2026-11-15，不需要设备）**：本地起 `--profile ohos` 并等 boot-report，
  `bridge.log` 给出 **`tools(25)`**：`create_goal, edit, exit_plan_mode, get_goal, glob, grep,
  list_agents, read, read_image, send_message, skill, subagent, subagent_fork, team_task_create,
  team_task_get, team_task_list, team_task_update, todo_write, update_goal, wait_agent, web_fetch,
  web_search, workflow, working_directory, write`。
  **真机复验（2026-11-16）**：设备 `bridge.log` 同样是 `tools(25)`，与本地完全一致。
  **这条证据替代了「必须真机确认工具表」的担心**：native executor 生效、`glob`/`grep` 仍是纯 JS 实现、
  没有 `bash`/`job_*`/`run_code`，符合预期。**0.2.2 白送的新工具**：`workflow`（多智能体编排）、
  `team_task_*` 四个（agent-team）、`read_image`、`exit_plan_mode`、`working_directory`、`wait_agent`。
  工具数从 21 → 25。
- **in-process PTC 运行时已交付并真机闭环（2026-10-27，P1①）**：
  `@ohos/dsh-ptc-runtime-vm`（worker_threads + `node:vm`）挂进 `ohos` profile，
  `dsh-bundle-ohos` patch 禁 stock `ptc-runtime`；`tools` 行现为 `mode: native`
  （2026-10-29 起，此前短暂为 `mode: ptc`）——native 下 21 个工具直出（glob/grep/read/web
  等），run_code 不在模型工具表（源码契约：仅非 native 注入）；ptc 模式则 wire 上只有
  run_code，其余经程序内 `tools.*` SDK。
  真机（手机 2026-10-27）全绿：worker_threads 在 arm64/`--jitless` 可用；模型一个 run_code
  程序内 `tools.write`×3 + `tools.glob` 计数正确答 "4"；contain-probe 回归——程序内
  `grep` path=`..` 仍被收口拒绝（`grep path escapes the session workspace`）。本地：
  单测 22/22（含 `--jitless`）+ dump-config + 冒烟 + 真实模型 E2E（`tools.glob` → "3"）。
  三条实测契约写死在 `docs/GAP-ANALYSIS.md` §L2：dsh-tools binding 是 resolve=值/reject=错误
  （不是 settle 对象）；cordis traceable 下 service 类禁 `#private` 字段（方法 `this` 是
  Proxy，品牌检查必炸，用普通属性）；amaro TS 擦除依赖 WASM ⇒ jitless 下设备不能跑 TS，
  executionInstructions 明示写纯 JS。
- **API 密钥热更新已交付并真机闭环（2026-10-27）**：`@ohos/dsh-credentials-live`
  挂进 `ohos` profile（bundle `dependencies` + `cordis.patch.yml` insert 双登记），真机
  bridge.log 实证 `[credentials-live] watching <dsh-home>/.api-key (dir-watch + poll every
  1500ms)` + `boot: ohos runtime mounted`——目录级 fs.watch（inotify）在应用沙箱可用。
  根因链：dsh 启动期 `loadLayeredEnv` 冻结 env 快照 ⇒ 运行中改 `process.env` 无效；外部改
  `.credentials.yaml` 需 0600/锁配合（`assertOwnerOnly`）且有竞态——都不如暂存文件轮询 +
  `credentials.set()`（provider 自身 set/unset 直更内存快照 + notifyUpdated，不经 watcher）。
  ArkTS 侧：`AppConfig.save` 以 temp+rename 原子写 `.api-key`（清 key 删文件）；`NodeHost`
  启动对空 key 删陈旧暂存（修跨重启清 key 失效 bug）；Settings 保存 toast 按 `host.isAcp()`
  分「即将生效」/「重启生效」。单测 8/8（载荷树内）+ 回归 fs-search 38/38、ptc 22/22
  （含 `--jitless`）+ dump-config（`credentials-live-ohos` 挂载、五处 disabled、`mode: native`）
  + 冒烟。
- **纯 JS 搜索插件已交付并真机闭环（2026-10-26，P0）**：自定义 `ohos` profile + bootstrap
  模板安装/acp→ohos 重映射；真机模型轮 `glob`/`grep` 真实命中（`danger-tablet-test.txt`），
  模型工具表无 bash/job_kill/job_list/job_output（P0a），权限三档快照不受影响；插件纯函数
  单测 37/37。根因（bundle 依赖声明）与机制：`docs/GAP-ANALYSIS.md` §7.1。
- fetch-shim 全家族替换修复已真机闭环（Gate 0，2026-10-26）：启动即 `boot: sdk runtime
  mounted`，0 fatal / 0 CRASH，桥 running，UI「dsh 已就绪」；启动期仍有一条良性
  `WebAssembly is not defined` unhandled rejection（与旧可用版本同类，不致命）。
- ACP 切换（Stage 1）已过 spike（`docs/SPIKE-ACP.md`，workbuddy）：进程内 PassThrough 劫持
  stdio + `runCli()` 零 spawn 可行；审批线上方法名 `session/request_permission`（snake_case）。
- `feature/acp` 分支（workbuddy，2026-10-26）：`host/bootstrap.cjs` 引入 `DSH_PROFILE`
  开关（默认 `sdk`，未改动 SDK 路径），`bridge-status.json` 增加 `profile` 字段；两个 profile
  均通过本地桥 smoke（sdk `initialize → serverInfo`；acp `initialize + session/new → sessionId`）。
  断线重连契约已实测并写入 §4.2。
- ACP 协议矩阵已在真机闭环（2026-10-26，fport 外部驱动 + `DSH_PERMISSION_MODE=read-only`
  测试构建）：initialize / session/new / set_config_option / prompt（审批 `allow-once` 放行
  后工具真实落盘）/ cancel（通知）/ 断线重连 / close / list / resume 全部实机通过；新发现
  set_config_option 选项集收缩契约（§4.2）。详见 `docs/SPIKE-ACP.md` §9。
- ArkTS ACP 客户端已交付（2026-10-26，手机+平板真机验证）：AcpProtocol/AcpClient + 审批
  弹窗 + 流式气泡 + usage + 停止（cancel 通知）+ 模型选择器（选项集收缩适配）+ resume
  降级 + **权限三档选择器**（只读/平衡/宽松；danger-full-access 平板端到端零审批落盘，
  三档快照写入 session log）。审批弹窗为根 Stack 固定覆盖层（不在 transcript 流内，
  早期「渲染进滚动流」记录是未提交中间态，已勘误）。
- **AcpClient 断线重连已交付并真机闭环（2026-10-27）**：客户端只报掉线（`onDisconnect`
  单发，error/close 同一掉线只报一次），恢复编排在 `Index.ets`——首退避 120s、×2、
  cap 300s、6 次尝试；无在跑轮次直接复附（对旧 sessionId prompt），孤儿轮走重置语义
  （`session/close` 掐孤儿轮 → `session/resume` → 标记「已中断」由用户决定重发，见 §4.2
  与 `docs/SPIKE-ACP.md` §11）。真机验证（手机）：断连 06:38:59.044 → 重连 06:40:59.076，
  **精确 120.03s** 按设计夺回客户端槽位，断连/复附消息均落 `dsh_sessions` 缓存。
  探针窗口注意：桥为**单客户端**（新连接 `replacing previous client` 顶掉旧连接），
  App 会在 2 分钟内自动回连抢回槽位——外部 fport 探针单轮（≤2min）不受影响，更长的
  外部实验须先 force-stop App，否则探针会被 App 的自动重连顶掉。
- 真机序列号等本地信息只记在本地记忆（`.workbuddy-ai/memory/`，gitignored），**不写进公开仓库**。
- **图片识别已修（2026-10-29）**：根因是**请求期投影**而非网络——dsh 把每张请求图投影到 DeepSeek 视觉网格
  （14px patch、3:1 下采样、1024 token），源图超预算就要 sharp 重编码；设备上 sharp 只有 darwin-arm64 +
  wasm32（jitless 无 WASM），`host/sharp-stub.cjs` 的编码阶梯 fail-closed，抛出的普通 Error 被
  `dsh-llm-deepseek` 统一包成 `DeepSeek Messages transport failed`/`TRANSPORT`（重试 5 次全白跑，请求未发出）。
  修法：桩的 `.jpeg()` 改为**原字节直通**并回报**源尺寸**（`toBuffer({resolveWithObject})` 契约），投影退化为
  no-op、由服务端自己下采样，代价只是上传变大；WebP/PNG/TIFF/GIF 仍 fail-closed（其字节不能冒充 JPEG）。
  本地验证：同一张 1320×2848 图 `readRequestImageFile` 从 `SharpStubError` 变为直通；ACP 端到端（无效 key）
  已到达服务端并返回 401 鉴权错误，不再是 TRANSPORT。单测 17/17。
- **dsh 升到 0.2.2-rc.5（2026-11-20，本地闭环，真机待验）**：从 rc.3 只隔两个补丁级 RC。
  逐包 diff 后**真正改动的代码只有三处**：①`dsh-web` / `dsh-web-search-deepseek`——搜索提供方
  改为按模型路由自动选，DeepSeek 路由走服务端 Messages 搜索（不按次收费、按 token 计费），
  端点固定 `https://api.deepseek.com/anthropic/v1`、**不跟随 provider baseURL**；②`dsh-llm-deepseek`
  ——新增 `stop_reason: 'refusal'` → `CONTENT_REFUSED`（先报已耗 token 再抛）；③
  `dsh-session-persistence-jsonl/lib/worker.cjs`——错误码表加一项。其余 13 个直接依赖的包
  **只动了 `package.json` 版本号**。组合配置 diff 只有一行：`web.searchProvider` 消失。
  包数 676 不变、工具表 25 不变、ACP 9 方法不变（`dsh-acp` 只改版本号）。载荷 zip **240MB**。
  **boot-report 同步修**：`describeCapability()` 原来只做「配置优先 / 唯一可用」，rc.5 下两个
  provider 可用就误报 `search=ambiguous`；现按 `dsh-web` 的路由偏好判定（`preferredSearchProvider()`，
  路由取自 `ctx.get('agentDefaultModel').currentSelection().provider`），输出
  `search=auto (deepseek-official for deepseek-official)`。单测 11 → 20。
  **版本钉死**：`assemble-payload.mjs` 的 `PINNED_DSH_VERSION = '0.2.2-rc.5'`，默认不再解析 `latest`
  （此前重打载荷会在不知情下换大脑）。
  本地验证：四组载荷单测 38 / 22 / 8 / 20（ptc 另跑 `--jitless` 22/22）+ `--dump-config`
  （12 行 disabled、5 行 insert 命中、`web` 行只剩 `fetchProvider`）+ 冒烟（`tools(25)`、
  `search=auto (…)`）+ `bash scripts/test.sh arkts local` 全绿（46 个文件 / LocalUnit 通过）。
  **真机未验**：重装后需确认一次真实 `web_search` 走服务端搜索能返回结果。
