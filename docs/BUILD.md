# 构建与安装

## 前置

| 项 | 版本 / 说明 |
|---|---|
| DevEco Studio | 本机 `/Applications/DevEco-Studio.app`（含 SDK `Contents/sdk`） |
| HarmonyOS SDK | **API 26 / platformVersion 26.0.0（HarmonyOS 7.0.0）**；`DEVECO_SDK_HOME` 需指向 SDK 根 |
| Node.js | 18+（装配载荷用；DevEco 自带 18.20.1 也可） |
| zip | macOS 自带 |

`build-profile.json5` 当前 `targetSdkVersion` / `compatibleSdkVersion` 均为 **`"26.0.0"`**。

> ⚠️ 版本字符串的坑：本机 hvigor **不接受** `"7.0.0(26)"` 这种带括号写法，会报
> `00308018 api version parameter is illegal`；`"26"` 和 `"7.0.0"` 也不认。能通过的是
> **纯平台版本号 `"26.0.0"`**。构建产物里 `minAPIVersion`/`targetAPIVersion` 会写成
> `260000026`（API 26）。
>
> 需要兼容更低版本时，`compatibleSdkVersion` 可单独调低（如 `"6.0.2(22)"`），但本机只装了
> API 26 的 SDK，实测只有 26.0.0 能编过。

## 1. 安装 ohpm 依赖

```bash
export PATH="/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
ohpm install
```

装的是两个包：

- `@fellow99/node-bridge@0.1.0` — ArkTS API + NAPI 引导（`dlopen("libnode.so")` + `node::Start`）
- `@fellow99/node-runtime@24.2.0` — arm64-v8a 的 `libnode.so`（解压后约 122 MB）

> 若 `ohpm install` 在 symlink 阶段报 `00625004 SymLink Dir Failed`（本机沙箱限制），
> 包其实已经解到 `oh_modules/.ohpm/` 下，手工补两条软链即可：
>
> ```bash
> mkdir -p oh_modules/@fellow99
> ln -sfn ../.ohpm/@fellow99+node-bridge@0.1.0/oh_modules/@fellow99/node-bridge oh_modules/@fellow99/node-bridge
> ln -sfn ../.ohpm/@fellow99+node-runtime@24.2.0/oh_modules/@fellow99/node-runtime oh_modules/@fellow99/node-runtime
> ```

## 2. 装配 dsh 载荷

```bash
node scripts/assemble-payload.mjs
```

做四件事：`npm install @deepseek-ai/dsh`（`--ignore-scripts`，见下）→ 拷入
`host/bootstrap.cjs`、`host/fetch-shim.cjs` 与 `host/patches/` → 校验 `lib/bin.js` 存在 →
打成 `entry/src/main/resources/rawfile/dsh-payload.zip`。

迭代时可加 `--skip-install` 只重新打包；指定版本用 `--dsh-version 0.2.1-rc.4`；
换一个全新的 staging 目录用 `--staging .build/payload-b`（避免删大目录触发安全策略）。

**为什么必须 `--ignore-scripts`**：`koffi` 是 dsh 的普通依赖，安装时会尝试用 CMake 编译原生
FFI 二进制，没有工具链就整包安装失败。它的加载是懒的且只服务 Windows API
（`advapi32`/`kernel32`），在鸿蒙上不会被触发，所以跳过它的构建脚本是安全的。

**为什么不能 `--omit=optional`**：`node-addon-require-builtin` 的平台二进制是
optionalDependency，一旦省略，`cordis-plugin-loader` 的 `requireBuiltin` 就找不到实现。
那条路径有 `try/catch` 兜底，但安装树会残缺、行为不可预期——老老实实保留。

### 可选：平台补丁

`host/patches/ohos.patch.yml.example` 列出了在鸿蒙上必然不可用的行（`tool-bash`、
`tool-pwsh`、`subprocess`、`plugin-manager`、`skill-office` 等）。把它复制成
`ohos.patch.yml` 并重新装配载荷即生效——`bootstrap.cjs` 会以 `--patch <file>` 传给 dsh，
`NodeHost` 通过 `DSH_PATCH_FILE` 环境变量指路。

启用前先用 `--dump-config` 核对行 id 是否与当前 dsh 版本一致。

## 3. 配置密钥

`entry/src/main/resources/rawfile/secrets.json`（**已 gitignore**）：

```json
{ "deepseekApiKey": "sk-..." }
```

优先级：设置页保存的值 > 该文件。设置页写入后即以偏好设置为准。

## 4. 手机侧准备（一次性）

1. **打开开发者模式**：设置 → 关于手机 → 连续点击「版本号」7 次，直到提示已进入开发者模式。
2. **打开 USB 调试**：设置 → 系统 → 开发者选项 → 「USB 调试」。
3. **连接电脑**：插 USB，手机弹「是否允许 USB 调试」→ 允许（勾选「始终允许」）。
4. **验证**：

```bash
hdc list targets        # 应打印设备序列号，而不是 [Empty]
```

`hdc` 在 `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`，
加进 PATH 或写全路径。若一直 `[Empty]`：换一根能传数据的线（很多线只供电）、换 USB 口、
在开发者选项里点「撤销 USB 调试授权」再重插。

## 5. 签名

HarmonyOS 5 起，真机安装**必须有华为签发的调试证书与 profile**，自签名包不被接受。
所以签名绕不开一次华为账号登录：

```bash
devecocli auth login          # 浏览器/设备码登录
devecocli signature generate  # 生成 .p12/.cer/.p7b 并写回 build-profile.json5
```

`signature generate` 做三件事：申请调试证书、把当前设备的 UDID 注册进调试 profile、
把 `signingConfigs` 写进 `build-profile.json5`。**设备要先连上**，否则 profile 里没有你的机型。

签名失败常见原因：

| 报错/现象 | 原因 | 处理 |
|---|---|---|
| bundleName 不可用 | `com.qtepp.taharness` 在 AGC 全局唯一命名空间里可能已被占用 | 改 `AppScope/app.json5` 的 `bundleName` 为更独特的名字，如 `com.yourname.dshharmony` |
| 未实名 / 无团队权限 | 账号状态问题 | `devecocli auth status`、`devecocli auth team` |
| 生成成功但装不上 | profile 里没有这台设备的 UDID | 连上设备后重新 `signature generate --force` |

## 5.5 发布签名（分发给他人）

调试签名（`signature generate` 产出的）**绑定设备白名单**，别人装了会校验失败：

```
appProvisionType: "debug"
debug-info.device-ids: [ ...只有你自己的几台设备... ]
```

要给任意鸿蒙设备安装，必须用 AGC 签发的**发布证书**。两者区别：

| | 调试签名 | 发布签名 |
|---|---|---|
| 设备限制 | 仅 profile 里的 UDID（≤100 台） | **无限制** |
| 有效期 | 90 天 | 证书 3 年 / profile 长期 |
| 用途 | 自己开发调试 | 分发、上架 |

### 一次性准备（在 AGC 完成，需本人操作）

1. **注册并实名**华为开发者账号（个人 ¥99/年），
   <https://developer.huawei.com/consumer/cn/>
2. **创建应用**：AGC → 我的应用 → 新建，bundleName 填 `com.qtepp.taharness`
   （必须与 `AppScope/app.json5` 完全一致；AGC 全局唯一，被占用就得换）
3. **申请发布证书**：AGC → 证书、APP ID 和 Profile → 证书 → 新建（`.cer`）
4. **生成密钥库**：用 DevEco Studio 的 Generate Key and CSR，得到 `.p12` + `.csr`，
   上传 CSR 换取证书
5. **创建发布 Profile**：AGC → Profile → 新建，类型选 **Release**，
   关联上面证书与 bundleName，下载 `.p7b`

### 本地构建

```bash
# 1. 准备发布签名材料（gitignored，只存 material 八字段，密码为明文）
cat > build-profile.release.json5 <<'EOF'
{
  certpath: '/path/to/发布证书.cer',
  keyAlias: '密钥别名',
  keyPassword: '密钥密码',
  profile: '/path/to/发布Profile.p7b',
  signAlg: 'SHA256withECDSA',
  storeFile: '/path/to/密钥库.p12',
  storePassword: '密钥库密码',
}
EOF

# 2. 构建（脚本会先校验 profile 里的 bundleName 是否匹配）
bash scripts/build-release.sh
```

一次构建产出两份产物：

| 产物 | 用途 |
|---|---|
| `build/outputs/default/dshharmony-default-signed.app` | **AGC 提交（含测试轨道）上传**——AGC 的文件选择器直接过滤掉 .hap，只收 App Pack |
| `entry/build/default/outputs/default/entry-default-signed.hap` | **hdc 直连安装** |

**AGC 校验的是 .app 容器本身的签名（实测 2026-10-31）**：容器未签名的 .app 被测试轨道以
`991 非法软件包`（"未检测"到签名）拒收。正确形态（= DevEco Studio 签名构建的产物）：
**包内 HAP 保持未签名 + 容器整体签名**——hvigor `PackageApp` 装的永远是未签名 HAP
（源码实证：所有 `getModuleTargetOutputFileName` 调用都传 signed=false），
`SignApp` 给 .app 容器整体签名，AGC 分发时再拆包重签；官方 FAQ「其中的HAP包没有
签名」说的就是这个设计。脚本用 `hap-sign-tool sign-app -inForm zip` 对容器签名
（hvigor SignApp 的 CLI 等价）。

脚本做的事：校验 bundleName 一致性 → `--build-mode release --assemble-type
assembleApp` 一次构建出**未签名** HAP 与 .app（仓库口径的 `build-profile.json5`
原样使用，无注入无还原）→ `hap-sign-tool` 以明文密码给 HAP 本地签名（hdc 直装用）→
`hap-sign-tool sign-app -inForm zip` 给 .app 容器整体签名（AGC 上传用）→
`verify-app` 对独立 HAP 与 .app 容器各校验一次。

签名为什么绕开 hvigor SignHap：SignHap 只收 DevEco **加密格式**密码
（≥32 字符的 `000000...` 密文），明文密码直接报 `00303116`；
`hap-sign-tool sign-app` 收明文密码，且就是 DevEco 内部用的同一个签名工具。
脚本工具链路径可用 `JAVA_BIN` / `SIGN_TOOL` 环境变量覆盖。

### 常见失败

| 报错 | 原因 | 处理 |
|---|---|---|
| `00303116 Configuration Error`<br>`The length of the storePassword or keyPassword field ... is less than 32` | 把明文密码塞进了 `signingConfigs` 走 hvigor SignHap（只收 DevEco 加密密码） | 走 `scripts/build-release.sh`（hap-sign-tool 路径），别手动注入签名配置构建 |
| `00303074 Configuration Error`<br>`bundleName ... does not match ... SigningConfigs` | 签名 profile 的 bundleName 与 `app.json5` 不一致 | 在 AGC 用新 bundleName 重新生成 profile |
| AGC 报 `991 非法软件包`（"未检测"签名） | .app **容器**未签名——AGC 校验容器签名（hvigor SignApp 的职责），与包内 HAP 是否签名无关 | 上传 `dshharmony-default-signed.app`（`scripts/build-release.sh` 已用 `-inForm zip` 对容器签名） |
| AGC 报 `992 包名不一致` | .app / pack.info 里的 bundleName 与 AGC 应用记录不符 | 核对 `AppScope/app.json5` 与 AGC 应用基础信息 |
| 装上了但打不开 | 接收设备系统版本低于 `compatibleSdkVersion` | 当前要求 **API 26 / HarmonyOS 7.0.0** |
| AGC 提示 bundleName 已占用 | `com.*` 命名空间全局唯一 | 换更独特的反写域名 |

### 分发前还要想清楚

- **体积 335MB**：含 225MB dsh 载荷，首次启动解包 60–90 秒
- **API 26 门槛**：HarmonyOS 6.x 及更早装不上，当前装机量有限
- **接收方需自备 API Key**：密钥不能随包分发
- **上架需审核**：本脚本只产出可安装的包，上架 AppGallery 另需在 AGC 提交

## 6. 构建与安装（devecocli）

```bash
bash scripts/deploy.sh              # 一条命令：查设备 → 登录 → 签名 → 构建 → 安装启动
bash scripts/deploy.sh <serial>     # 指定设备
```

等价的手动步骤：

```bash
devecocli build                     # 编译出已签名 HAP
devecocli run --device <serial>     # 安装并拉起
devecocli device list               # 看已连接设备
devecocli log                       # 看设备应用日志
```

`signature generate` 支持 `--force`（覆盖本地材料）、`--team-id`、`--product`。
没有真机时：`devecocli emulator start <name>`。

### 首次启动会发生什么

解包 156MB 载荷（约 60–75 秒）→ 起内嵌 Node → 连本地桥 → 与 dsh 握手 → 进入聊天界面。
之后冷启约 3 秒。卡住时用 `devecocli log` 或应用内 设置 → 诊断 看 `stage=` / `node.log`。

### 纯命令行构建（不经 devecocli）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"
hvigorw --mode module -p product=default assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（未签名）或
`entry-default-signed.hap`（配好签名后）。

### 签名配置被拆到本地文件（重要）

`build-profile.json5` 里 `signingConfigs` 是**空的**（密钥不进版本库），真实配置在
`build-profile.signing.json5`（本地文件）。命令行构建必须先合并、构建完再还原，否则 hvigor 会
打印 `Will skip sign 'hos_hap'`，产物只有 `entry-default-unsigned.hap`：

```bash
cp build-profile.json5 /tmp/bp.bak
python3 - << 'EOF'
import re
sig = open('build-profile.signing.json5').read()
block = re.search(r'signingConfigs:\s*\[(.*?)\n    \],', sig, re.S).group(0)
s = open('build-profile.json5').read()
open('build-profile.json5','w').write(s.replace('signingConfigs: [],', block))
EOF
hvigorw --mode module -p product=default assembleHap --no-daemon
cp /tmp/bp.bak build-profile.json5        # 立刻还原
```

DevEco Studio 里则直接 Build 即可（IDE 会读本地签名文件）。

### 在受限环境里跑 devecocli 的两个坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `spawn EPERM` | devecocli 用 `ps -o rss=` 探内存，环境禁 `ps` | PATH 前面放一个 `ps` 桩脚本（输出任意数字即可） |
| `00625004 SymLink Dir Failed` + `CODEBUDDY_BROKER_DENY` | ohpm 重建 `oh_modules` 软链时被宿主沙箱拒绝 | 手工补软链（见 §1），或在普通终端里跑 |

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `Invalid value of 'DEVECO_SDK_HOME'` | 未设 SDK 根 | `export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk` |
| 启动卡在「等待 Node 主循环就绪」 | Node 启动失败 | 设置 → 诊断，看 `stage=`（`dlopen`/`dlsym`/`stdio`/`start`）与 `node.log` |
| `SIGTRAP` 崩溃 | 无 JIT ACL 却跑了 JIT | 确认 `flags` 含 `--jitless`（`NodeHost` 默认已带） |
| 网络请求全失败、日志提 `WebAssembly` | jitless 下 undici 不可用 | 确认 `fetch-shim.cjs` 已随包且 `wasm: unavailable` 时被安装 |
| `session/prompt` 超时 | dsh 未启动完就发了请求 | 首次握手 `initialize` 超时已放宽到 180s；检查桥状态文件 |
| 崩溃后无法恢复 | `node::Start` 不可重入 | 彻底退出应用再打开（UI 会明示） |

诊断入口：设置 → 诊断，聚合了 phase、桥状态 JSON、Node 日志尾 120 行、崩溃记录。
