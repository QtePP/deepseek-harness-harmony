# 第三方组件声明 / Third-Party Notices

本仓库自身以 [MIT](LICENSE) 发布。但分发的 HAP 中**包含第三方组件**，它们遵循各自的许可证。此文件记录这些组件及其许可，以符合开源合规要求。

## 直接依赖

| 组件 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) | 0.2.1-rc.4 | MIT | AI 运行时本体（会话、工具、插件、模型适配） |
| [`@fellow99/node-bridge`](https://ohpm.openharmony.cn/) | 0.1.0 | 见上游 | NAPI 桥接，把 Node 拉进鸿蒙进程 |
| [`@fellow99/node-runtime`](https://ohpm.openharmony.cn/) | 24.2.0 | 见上游 | `libnode.so`，Node v24.2.0 arm64 构建 |

## 载荷内含组件

`dsh-payload.zip` 由 `scripts/assemble-payload.mjs` 装配，内含 `dsh` 及其依赖。实测 **552 个包**，全部声明了许可证：

| 许可证 | 包数 |
|---|---|
| MIT | 465 |
| Apache-2.0 | 52 |
| BSD-3-Clause | 15 |
| ISC | 10 |
| MPL-2.0 | 2 |
| BSD-2-Clause | 2 |
| Unlicense | 1 |
| Python-2.0 | 1 |
| LGPL-3.0-or-later | 1 |
| Apache-2.0 AND LGPL-3.0-or-later AND MIT | 1 |

### 关于弱著佐权组件

包内存在 4 个 **MPL-2.0 / LGPL-3.0** 组件，需注意：

| 组件 | 许可证 | 设备端状态 |
|---|---|---|
| `@deepseek-ai/libreoffice-kit` | MPL-2.0 | 纯 JS 封装，未被本项目调用 |
| `@deepseek-ai/libreoffice-kit-darwin-arm64` | MPL-2.0 | **darwin 二进制，鸿蒙无法加载** |
| `@img/sharp-libvips-darwin-arm64` | LGPL-3.0-or-later | **darwin 二进制，鸿蒙无法加载** |
| `@img/sharp-wasm32` | Apache-2.0 + LGPL-3.0 + MIT | **wasm32，jitless 下不可用** |

其中 3 个是**平台专属二进制**，在 arm64-ohos 上永远不会被加载：

- `sharp` 在设备端由 `host/sharp-stub.cjs` 完全接管（`require` 被重定向）
- `wasm` 在 `--jitless` 下不可用

**这意味着**：虽然它们随载荷分发，但不参与运行。若需严格规避弱著佐权，可在装配后删除这些目录（注意：`*-darwin-*` 包是**构建机本地测试所需**，删除后本地冒烟会失败）。

### 主要类别

| 类别 | 示例 | 常见许可证 |
|---|---|---|
| 运行时与工具库 | `undici`、`zod`、`schemastery` | MIT |
| 文件与流处理 | `glob`、`minimatch`、`tar` | ISC / MIT |
| 解析与序列化 | `yaml`、`jsonc-parser` | ISC / MIT |
| 日志与终端 | `picocolors`、`debug` | MIT |

### 完整清单

装配后可在载荷目录中逐包查看许可证：

```bash
# 列出所有包的 name / version / license
node -e "
const fs=require('fs'),path=require('path');
const root='.build/payload/node_modules';
function walk(dir){
  for(const name of fs.readdirSync(dir)){
    if(name.startsWith('.')) continue;
    const p=path.join(dir,name);
    if(name.startsWith('@')){
      if(fs.statSync(p).isDirectory()) walk(p);
      continue;
    }
    const pj=path.join(p,'package.json');
    if(fs.existsSync(pj)){
      try{
        const j=JSON.parse(fs.readFileSync(pj,'utf8'));
        if(j.name) console.log(\`\${j.name}@\${j.version}\t\${j.license||'UNKNOWN'}\`);
      }catch(e){}
    }
  }
}
walk(root);
" | sort > THIRD-PARTY-MANIFEST.txt
```

## 平台与商标

- **HarmonyOS / ArkTS / ArkUI** 是华为技术有限公司的商标。本项目为社区移植，**与华为无隶属关系**。
- **DeepSeek / DeepSeek Harness** 是深度求索公司的产品与商标。本项目为社区外壳，**与深度求索无隶属关系**。
- **Node.js** 是 OpenJS Foundation 的商标。

## 分发注意

若你基于本项目二次分发 HAP：

1. **保留** `LICENSE` 与本文件
2. **保留**载荷内各 npm 包的原始 `LICENSE` 文件（`assemble-payload.mjs` 默认保留）
3. 若移除 `dsh` 或替换 Node 运行时，相应条目应同步更新

## 许可证全文

- MIT: <https://opensource.org/licenses/MIT>
- ISC: <https://opensource.org/licenses/ISC>
- Apache-2.0: <https://www.apache.org/licenses/LICENSE-2.0>

---

**最后更新**：2026-10-30

如发现遗漏或错误，请提交 Issue。
