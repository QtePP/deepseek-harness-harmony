import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { NodeRuntime, NodeRuntimeOptions, NodeStartResult, NodeState } from '@fellow99/node-bridge'
import { Payload } from './Payload'
import { AppConfig } from '../common/AppConfig'
import { DshClient } from '../model/DshClient'
import { AcpClient } from '../model/AcpClient'

/** Boot progress surfaced by the splash screen. */
export enum BootPhase {
  IDLE = 'idle',
  EXTRACTING = 'extracting',
  STARTING = 'starting',
  WAITING = 'waiting',
  READY = 'ready',
  FAILED = 'failed'
}

/**
 * Owns the on-device backend.
 *
 * HarmonyOS forbids fork/exec, so the dsh host runs as a Node.js runtime
 * embedded in this very process (`libnode.so` via @fellow99/node-bridge) and
 * listens on a loopback TCP bridge. The ArkUI client then speaks the dsh SDK
 * JSON-RPC protocol over that socket.
 *
 * Two platform facts shape this class:
 *   · `node::Start()` may run once per process — a crash is terminal, so the
 *     only recovery is restarting the app (we say so instead of pretending);
 *   · a JIT-free build (`--jitless`) needs no restricted ACL, at the cost of
 *     WebAssembly, which host/fetch-shim.cjs compensates for.
 */
export class NodeHost {
  private static instance: NodeHost = new NodeHost()

  phase: BootPhase = BootPhase.IDLE
  detail: string = ''
  client: DshClient = new DshClient()
  acp: AcpClient = new AcpClient()
  private runtime: NodeRuntime = NodeRuntime.getInstance()
  private payloadRoot: string = ''
  private booting: boolean = false

  static get(): NodeHost {
    return NodeHost.instance
  }

  /** ACP is opt-in through Settings; SDK remains the default profile. */
  isAcp(): boolean {
    return AppConfig.profile === AppConfig.PROFILE_ACP
  }

  isBooting(): boolean {
    return this.booting
  }

  /** Extract the payload, start Node, connect the bridge, handshake the runtime. */
  async boot(context: common.UIAbilityContext, onPhase: (phase: BootPhase, detail: string) => void): Promise<void> {
    if (this.booting || this.phase === BootPhase.READY) {
      return
    }
    this.booting = true
    const publish = (phase: BootPhase, detail: string): void => {
      this.phase = phase
      this.detail = detail
      onPhase(phase, detail)
    }

    try {
      if (AppConfig.apiKey.length === 0) {
        throw new Error('未配置 DeepSeek API Key，请在设置中填写')
      }

      publish(BootPhase.EXTRACTING, '解包 dsh 运行时载荷…')
      this.payloadRoot = await Payload.ensure(context)

      const workspace = `${context.filesDir}/workspace`
      if (!fs.accessSync(workspace)) {
        fs.mkdirSync(workspace)
      }
      const dshHome = `${context.filesDir}/dsh-home`
      const tmp = `${context.filesDir}/tmp`
      if (!fs.accessSync(dshHome)) {
        fs.mkdirSync(dshHome)
      }
      if (!fs.accessSync(tmp)) {
        fs.mkdirSync(tmp)
      }

      // node::Start is once per process: on a retry after a connect-stage
      // failure the runtime is already up and must not be re-dispatched.
      if (!this.runtime.isRunning()) {
        publish(BootPhase.STARTING, '启动内嵌 Node 运行时…')
        // An optional profile patch disables rows that cannot work here
        // (subprocess tooling, native FFI). Its presence is the switch.
        const patchPath = `${this.payloadRoot}/patches/ohos.patch.yml`
        const hasPatch = fs.accessSync(patchPath)
        // Settings capability toggles materialise as a second patch file;
        // bootstrap appends it after the platform patch (later rows win).
        const userPatchPath = `${context.filesDir}/patches/user.patch.yml`
        const hasUserPatch = fs.accessSync(userPatchPath)
        // The native bridge dumps the child environment into node.log at start
        // (`[node_bridge] env DEEPSEEK_API_KEY=…`), so the key must NOT travel
        // as an env var. Hand over a file path instead; bootstrap reads it and
        // assigns process.env.DEEPSEEK_API_KEY after the bridge has logged.
        const keyPath = `${dshHome}/.api-key`
        try {
          const key = AppConfig.apiKey
          if (key.length > 0) {
            const file = fs.openSync(keyPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
            fs.writeSync(file.fd, key)
            fs.closeSync(file)
            // No chmod here: @ohos.file.fs exposes no permission API. The
            // sandbox already isolates per-uid; bootstrap.cjs tightens the
            // file to 0600 as soon as Node is up (and keeps it there).
          }
        } catch (error) {
          // A missing key file only degrades to "no credentials"; never block boot.
        }
        const options: NodeRuntimeOptions = {
          scriptPath: `${this.payloadRoot}/bootstrap.cjs`,
          payloadRoot: this.payloadRoot,
          homeDir: context.filesDir,
          logPath: `${context.filesDir}/node.log`,
          // No restricted ACL on this build: jitless keeps the install clean.
          // --expose-internals lets the require-builtin shim reach Node's
          // internal module loader without the native addon (none for ohos).
          flags: '--jitless --expose-internals',
          env: {
            DSH_HOME: dshHome,
            DSH_KEY_FILE: keyPath,
            DSH_BRIDGE_PORT: `${AppConfig.BRIDGE_PORT}`,
            TMPDIR: tmp,
            HOME: context.filesDir,
            DSH_PATCH_FILE: hasPatch ? patchPath : '',
            DSH_USER_PATCH_FILE: hasUserPatch ? userPatchPath : '',
            DSH_PROFILE: AppConfig.profile,
            DSH_PERMISSION_MODE: AppConfig.permissionMode
          },
          onStateChange: (state: NodeState, note?: string) => {
            if (state === NodeState.FAILED) {
              publish(BootPhase.FAILED, `Node 运行时失败：${note === undefined ? '' : note}`)
            }
          }
        }

        const started: NodeStartResult = this.runtime.start(context, options)
        if (!started.ok) {
          throw new Error(`Node 投递失败 (${started.code}): ${started.message}`)
        }

        publish(BootPhase.WAITING, '等待 Node 主循环就绪…')
        try {
          await this.runtime.waitUntilRunning(30000)
        } catch (error) {
          // A probe misfire must not kill an otherwise alive runtime; the
          // bridge connect loop below is the real readiness check.
          if (!this.runtime.isRunning()) {
            throw error as Error
          }
        }
      }

      publish(BootPhase.WAITING, '连接本地桥…')
      await this.connectBridge()

      publish(BootPhase.WAITING, '与 dsh 会话服务握手…')
      if (this.isAcp()) {
        // ACP handshake is idempotent: a later retry may safely repeat it.
        const info = await this.acp.initialize()
        const agent = info.agentInfo
        const label = agent === undefined ? '就绪' : `${agent.name === undefined ? '' : agent.name} ${agent.version === undefined ? '' : agent.version}`.trim()
        publish(BootPhase.READY, label.length === 0 ? '就绪' : label)
      } else {
        const info = await this.client.initialize(workspace, AppConfig.PROVIDER, AppConfig.model)
        const server = info.serverInfo
        publish(BootPhase.READY, server === undefined ? '就绪' : `${server.name} ${server.version}`)
      }
    } catch (error) {
      const failure = error as Error
      const stage = this.runtime.getStage()
      const native = this.runtime.getLastError()
      publish(BootPhase.FAILED, `${failure.message}${stage.length > 0 ? ` [stage=${stage}]` : ''}${native.length > 0 ? ` ${native}` : ''}`)
    } finally {
      this.booting = false
    }
  }

  /**
   * Connect to the loopback bridge, tolerating the window in which Node is
   * up but the TCP listener is not accepting yet (observed several seconds
   * on-device). Each attempt gets a fresh socket; ~16s total budget.
   */
  private async connectBridge(): Promise<void> {
    let lastError: Error = new Error('bridge unreachable')
    for (let attempt = 0; attempt < 8; attempt++) {
      try {
        if (this.isAcp()) {
          await this.acp.connect(AppConfig.BRIDGE_PORT)
        } else {
          await this.client.connect(AppConfig.BRIDGE_PORT)
        }
        return
      } catch (error) {
        lastError = error as Error
        if (attempt < 7) {
          await NodeHost.delay(2000)
        }
      }
    }
    throw lastError
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve()
      }, ms)
    })
  }

  /** Tail the Node log for the diagnostics panel. */
  tail(count: number): string[] {
    const lines: string[] = []
    for (const entry of this.runtime.logs(count)) {
      lines.push(`${entry.stream}: ${entry.text}`)
    }
    return lines
  }

  /** Read the bridge status file written by host/bootstrap.cjs. */
  bridgeStatus(context: common.UIAbilityContext): string {
    try {
      const path = `${context.filesDir}/dsh-home/bridge-status.json`
      if (!fs.accessSync(path)) {
        return '尚无桥状态记录'
      }
      return fs.readTextSync(path)
    } catch (error) {
      return `读取桥状态失败：${(error as Error).message}`
    }
  }

  crashInfo(): string {
    const crash = this.runtime.lastCrash()
    if (crash === null) {
      return '未记录到崩溃'
    }
    return `${new Date(crash.at).toISOString()} stage=${crash.stage} signal=${crash.signal === undefined ? '-' : crash.signal}\n${crash.hint === undefined ? '' : crash.hint}`
  }
}
