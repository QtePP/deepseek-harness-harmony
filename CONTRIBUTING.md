# 贡献指南

感谢你有兴趣改进 TA Harness。这个项目是鸿蒙平台上对 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的**宿主适配层**，因此有几条与普通前端项目不同的约定。

## 开始之前

请先读这两份文档，它们决定了改动是否可行：

- [AGENTS.md](AGENTS.md) —— 统一术语、架构口径、平台硬约束
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 四层关系与协议面

**口径以 AGENTS.md 为准。** 若代码与文档冲突，先提 Issue 说明，不要单方面改口径。

## 环境准备

| 依赖 | 版本 |
|---|---|
| DevEco Studio | 含 SDK API 26 / HarmonyOS 7.0.0 |
| 鸿蒙设备 | API 26+（装不上 HarmonyOS 6.x） |
| Node | 22+（仅装配载荷用） |

```bash
node scripts/assemble-payload.mjs   # 首次需装配载荷（约 225MB）
bash scripts/deploy.sh              # 构建并安装到真机
```

## 提交前必做

```bash
# 1. ArkTS 静态检查：必须 0 error
devecocli check arkts <改动的 .ets 文件>

# 2. 构建通过
devecocli build

# 3. 真机验证（涉及界面/协议时）
devecocli run --device <serial> --skip-build
```

**构建不通过、或界面改动未经真机验证的 PR 不会被合并。** 本项目的核心复杂度在平台约束，模拟器与真机行为差异很大。

### 载荷相关改动

若修改了 `host/` 或依赖版本，必须重新装配并跑完三段本地验证（见 AGENTS.md §8.4）：

```bash
# 单测（必须在载荷树内跑）
cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-ptc-runtime-vm
node --test test/*.test.mjs

# 配置层
DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js \
  --profile ohos --patch .build/payload/patches/ohos.patch.yml --dump-config

# 启动冒烟
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}\n' \
  | DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos
```

## 代码约定

### ArkTS

- **写 `.ets` 前必读** [AGENTS.md](AGENTS.md) 的平台约束，尤其 `@Observed` / `@ObjectLink` 的语义
- 不用 `#private` 字段（cordis traceable 下 `this` 是 Proxy，品牌检查会炸）
- 提交的 `.ets` 必须通过 `devecocli check arkts`

### 注释

解释**为什么**，不复述代码。特别地：

- 平台怪癖要写清根因（例如「ArkUI 只保证 fill 支持渐变，stroke + gradient 会画成两条线」）
- 踩过的坑要留下痕迹，避免后人重蹈

### 提交信息

用祈使句描述**行为变化**，而非文件改动：

```
✅ Open the trace panel in place instead of from above
✅ Stop blaming the file for a lookup that failed
❌ Update ChatView.ets
❌ Fix bug
```

正文说明根因。若一个改动修了多个独立问题，逐条列出。

## 安全红线

以下内容**一律不得提交**：

| 项目 | 说明 |
|---|---|
| API Key | `secrets.json`、`.api-key` 已在 `.gitignore` |
| 签名材料 | `build-profile.signing.json5` 已 gitignore |
| 设备序列号 | 不在任何公开文件中出现 |
| 私有对话内容 | 截图需清理个人聊天记录 |

**发现泄漏请立即提 Issue 提醒，并轮换相关密钥。**

## 提 Issue

请包含：

1. **设备型号与系统版本**（API 级别）
2. **复现步骤**，越具体越好
3. **实际行为 vs 预期行为**
4. 相关日志：`devecocli log --level E --bundle-name com.qtepp.taharness`
5. 若涉及界面，附截图

搜索已有 Issue 后再提，避免重复。

## 许可

提交 PR 即表示你同意以 [MIT](LICENSE) 授权你的贡献。
