# 对局军师 · match-coach

一个「边玩边问」型的定制 Agent：你在打游戏，它在你手边，用三行话告诉你下一步做什么。

**它是什么**：一个可整体拷贝的 workspace —— `AGENTS.md` 决定人格与热知识，`.dsh/skills/` 决定能力，
`cards/` 决定状态怎么展示，`data/` 装它自己写的数据。没有一行 ArkTS，没有新增依赖，
不需要重打载荷。

**它不是什么**：不读游戏内存、不投屏、不跨 App、不自动操作、不做挂机脚本。
鸿蒙的权限模型拿不到别的应用的内容（见 `docs/PERSONAL-AGENT.md` §5.2），这类需求一律拒绝。

---

## 怎么装（两条路，都不用改代码）

### 路 A：应用内自建（推荐，只需要手机）

1. 在应用里新建一个项目（建议叫「对局军师」），进入它的会话；
2. 把 `BOOTSTRAP.md` 里 `---` 之间的那段整段粘进去发送；
3. 模型用 `write` 把 5 个文件落盘，然后一次性问你游戏 / 段位 / 位置 / 英雄池。

这条路本身就是 `docs/PERSONAL-AGENT.md` §6.1 的"对话生成"路径，顺带验证了它。

### 路 B：整包投放（适合开发者，要电脑）

DevEco Studio → Device File Browser → 定位到应用沙箱
`.../haps/entry/files/workspaces/<projectId>/` → 把本目录**内容**（不是目录本身）上传进去。

上传后必须是这个形状，否则技能不会被加载：

```
workspaces/<projectId>/
  AGENTS.md
  agent.json
  cards/review.card.json
  .dsh/skills/quick-call/SKILL.md
  .dsh/skills/match-review/SKILL.md
  .dsh/skills/patch-notes/SKILL.md
  data/matches/
```

---

## 长什么样

三个真实形态，都是三行：

```
你：这波打不打（附图：三人压到对面二塔，对面打野 40 秒没露头）
它：撤，绕红区回城补装。
    打野 40 秒没露头，二塔下打等于送先手。
    他们中单大招还在，反打你跑不掉。
```

```
你：对面打野在哪
它：大概率蓝区，去反他红。
    他上次露头在下路，40 秒够走到蓝区；我们下路有线权。
    如果他已经到红，立刻放弃，别恋战。
```

```
你：出什么
它：碎星锤。对面双前排，护甲堆得高。
    如果他们换双刺客，改出名刀，别硬堆穿透。
```

注意第三条：用户没给阵容，它没有反问"对面什么阵容"，而是给了一个默认答案 + 一条分支。
**对局中反问的代价比给错一条分支高。**

## 三条会静默失效的坑

这三条都是读了 `dsh` 源码确认的，不是猜的：

1. **技能目录锚定 git 根，不是 cwd。** `dsh-skill-filesystem` 的 `findProjectRoot()` 从 cwd 向上找
   `.git`，找到就用那个目录当 project root，找不到才回落到 cwd，然后才去读
   `<projectRoot>/.dsh/skills`。设备沙箱里没有 `.git`，所以能生效；**但你在本仓库里直接测这个
   pack 时它一定不生效**（project root 会变成仓库根）。要在桌面验证，先把 pack 拷到仓库外。
2. **默认 profile 没有代码执行。** 当前 native 模式工具表 21 个，`bash` / `job_*` 已被 patch 移除，
   `run_code` 不在表内（`docs/GAP-ANALYSIS.md` §3）。所以这个 pack **不带 `scripts/`**：
   没有能跑 JS 的地方，写了也是死文件。数字靠"公式写清 + 标可信度"来保证，不靠脚本。
3. **每调一次工具就是一次完整模型往返。** 对局中调一次 `read` 读配置，2 秒变 5 秒。
   所以配置和热知识全塞 `AGENTS.md`（会话建立时注入，不花轮次），`quick-call` 明令零工具调用。

---

## 为什么是"三行"而不是"攻略"

用户在对局里，读不完第二段。所以输出契约是硬约束：

```
动作（祈使句，能立刻照做）
依据（一句话，说清为什么）
前提/风险（一句话）
```

合计 ≤ 120 字。信息不够时**给两条分支**（"他们压线 → A；他们回城 → B"）而不是反问——
反问会打断他，分支不会。

## 换一个游戏

只改 `AGENTS.md` 的「配置」和「热知识」两段，其余文件不动：

- 配置：游戏、平台、段位、位置、英雄池、当前版本；
- 热知识：节奏锚点、常见对位、我常犯的错。

`quick-call` 的问法映射表（打不打 / 在哪 / 出什么 / 要不要抢）对 MOBA、FPS、自走棋都通用，
不用改。抽卡类游戏的"日常 / 体力 / 保底"不适合这个 pack，那属于卡片场景。

## 目录

| 路径 | 作用 | 谁改 |
|---|---|---|
| `AGENTS.md` | 人格 + 配置 + 输出契约 + 热知识；热路径唯一真源 | 用户（改行为要确认） |
| `agent.json` | Agent 元数据，给以后的切换器 / 卡片板读 | 用户 |
| `.dsh/skills/quick-call/` | 对局中秒回，零工具调用 | 用户 |
| `.dsh/skills/match-review/` | 赛后复盘，写 `data/matches/` | 用户 |
| `.dsh/skills/patch-notes/` | 版本要点，只认官方来源 | 用户 |
| `cards/review.card.json` | 上一局的卡片投影（**当前应用内还没有渲染器**，见下） | 用户 |
| `data/matches/` | 一局一个 JSON，只增不改 | Agent |
| `data/latest.json` | 最新一局的投影，卡片读它 | Agent |

## 已知没做

- **卡片还看不见。** `cards/review.card.json` 是给 S1 的 CardRenderer 准备的契约，当前应用里没有
  渲染器（`entry/.../view` 下没有 CardRenderer），所以它现在是"写好了但没人读"。
  数据链路是真的：`match-review` 确实会写 `data/latest.json`。
- **没有提醒。** `agent.json` 的 `schedule` 是空的，`reminderAgentManager` 还没接。
- **没有脚本。** 见上面第 2 条；等 `run_code` 或应用侧计算落地再补。
- **`data/latest.json` 首次复盘前不存在**，卡片应当隐藏而不是显示空值。

## 验收（装完自己点四下）

1. 发「这波打不打」→ 三行、≤120 字、工具轨迹只有一步（没有 read/glob）。
2. 发「复盘」→ `data/matches/<日期>-01.json` 出现，FilesPanel 能看见。
3. 发「这版本改了什么」→ 没网时它说"抓不到"，而不是编一段版本内容。
4. 杀掉 app 重进 → 技能还在。

第 1 条和第 3 条是这个 pack 的核心价值：**快，且不装懂**。
