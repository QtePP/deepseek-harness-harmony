/**
 * DSH on HarmonyOS — in-process Node backend entry.
 *
 * Runs INSIDE the app process (libnode.so started by @fellow99/node-bridge).
 * HarmonyOS forbids fork/exec, so we cannot spawn `dsh` as a child process.
 * Instead we:
 *
 *   1. open a loopback TCP server (the "bridge") for the ArkTS UI;
 *   2. on the first client, replace process.stdin/stdout with socket-backed
 *      streams, because the dsh SDK profile speaks newline-delimited JSON-RPC
 *      over stdio;
 *   3. boot `dsh --profile sdk` in THIS process.
 *
 * Wire format on the socket: one JSON-RPC 2.0 frame per '\n' (identical to
 * the SDK stdio contract, see @deepseek-ai/dsh-sdk-protocol). Lines that do
 * not parse as JSON are diagnostic noise and must be ignored by the client.
 */

'use strict'

const net = require('node:net')
const fs = require('node:fs')
const path = require('node:path')
const Module = require('node:module')
const { PassThrough } = require('node:stream')

const HOST = '127.0.0.1'
const PORT = Number(process.env.DSH_BRIDGE_PORT || 4517)
const PAYLOAD_ROOT = __dirname
const DSH_HOME = process.env.DSH_HOME || path.join(path.dirname(PAYLOAD_ROOT), 'dsh-home')
const STATUS_FILE = path.join(DSH_HOME, 'bridge-status.json')
const LOG_FILE = path.join(DSH_HOME, 'bridge.log')

/**
 * Which dsh profile to mount: a shipped bundle name (`sdk` / `acp`) or a custom
 * profile directory under $DSH_HOME/profiles. Defaults to `sdk`.
 *
 * The name is passed through rather than whitelisted: a custom profile (`ohos`)
 * is how platform plugins get mounted — profile patches can only override or
 * disable existing rows, never add one (verified: "patch: entry X not found"),
 * so new rows must come from a bundle listed in the profile's
 * `dsh.profile.bundles`.
 *
 * Both shipped profiles speak newline-delimited JSON-RPC over stdio, so the
 * bridge does not care which one is mounted — the client does, because the
 * method sets differ:
 *
 *   sdk: initialize / session/prompt / session/resume /
 *        session/working-directory/set / shutdown
 *   acp: initialize / session/new / session/list / session/resume /
 *        session/close / session/set_config_option / session/prompt /
 *        session/cancel  (+ notifications session/update, and the server-issued
 *        request `session/request_permission`)
 */
let PROFILE = (process.env.DSH_PROFILE || 'sdk').trim() || 'sdk'

/**
 * Custom profile template shipped in the payload (rawfile). When present it
 * is copied into $DSH_HOME/profiles so the loader can pick `--profile ohos`
 * up; a content-hash stamp makes the copy idempotent across boots while still
 * refreshing after a payload update. The template carries the pure-JS search
 * bundle (`@ohos/dsh-tool-fs-search-js`) that replaces the spawn-ripgrep
 * tool-fs-search, which can never run here (fork/exec is forbidden).
 */
const PROFILE_TEMPLATE_DIR = path.join(PAYLOAD_ROOT, 'profile-ohos', 'profiles', 'ohos')
const TEMPLATE_STAMP_FILE = '.ohos-template-stamp'

let booted = false
let client = null
let bootError = null
let debugChmodTimer = null

/** Best-effort recursive chmod so hdc shell can inspect runtime state. */
function chmodTree(root) {
  fs.chmodSync(root, 0o755)
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const child = path.join(root, entry.name)
    if (entry.isDirectory()) {
      chmodTree(child)
    } else {
      try {
        // The credential file stays 0600: the relaxation exists for
        // shell-side debugging, and the key must not become shell-readable.
        fs.chmodSync(child, child === keyFilePath() ? 0o600 : 0o644)
      } catch {
        /* file may be mid-write */
      }
    }
  }
}

/** Path of the credential file handed over by the host, when configured. */
function keyFilePath() {
  const configured = process.env.DSH_KEY_FILE
  return configured && path.isAbsolute(configured) ? configured : null
}

/**
 * Tighten the credential file as early as possible. The host cannot chmod
 * (@ohos.file.fs has no permission API), so the file briefly lands with the
 * default creation mode inside the app sandbox; per-uid isolation covers
 * that window, and 0600 from here on also keeps the debug chmod timer and
 * shell-side reads out.
 */
function tightenKeyFile() {
  const keyFile = keyFilePath()
  if (!keyFile) return
  try {
    if (fs.existsSync(keyFile)) {
      fs.chmodSync(keyFile, 0o600)
      log('key: file tightened to 0600')
    }
  } catch {
    /* best effort */
  }
}

/**
 * dsh creates sessions/ and storages/ with 0700 (app uid), which blocks all
 * shell-side inspection while debugging; relax the tree on a timer.
 */
function startDebugChmod() {
  if (debugChmodTimer !== null) return
  debugChmodTimer = setInterval(() => {
    try {
      chmodTree(DSH_HOME)
    } catch {
      /* tree may not exist yet */
    }
  }, 10000)
  debugChmodTimer.unref()
}

/** Append to the on-device log file; never throws. */
function log(line) {
  const text = `[${new Date().toISOString()}] ${line}\n`
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true })
    fs.appendFileSync(LOG_FILE, text)
  } catch {
    /* logging must never break boot */
  }
  try {
    process.stderr.write(text)
  } catch {
    /* stderr may be detached on device */
  }
}

/** Publish bridge state for the ArkTS side to read when boot fails. */
function writeStatus(state, extra) {
  const body = {
    state,
    profile: PROFILE,
    port: PORT,
    pid: process.pid,
    node: process.version,
    wasm: typeof WebAssembly !== 'undefined',
    platform: process.platform,
    arch: process.arch,
    updatedAt: new Date().toISOString(),
    error: bootError ? String(bootError && bootError.stack || bootError) : null,
    ...extra
  }
  try {
    fs.mkdirSync(path.dirname(STATUS_FILE), { recursive: true })
    fs.writeFileSync(STATUS_FILE, JSON.stringify(body, null, 2))
  } catch {
    /* status is advisory */
  }
}

/** Keep stdout pure: route console output to the log file instead. */
function rerouteConsole() {
  const emit = (...args) => log(args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' '))
  console.log = emit
  console.info = emit
  console.warn = emit
  console.error = emit
}

/**
 * Install the jitless compatibility layer.
 * Under `--jitless`, `WebAssembly` is undefined, so Node's built-in fetch
 * (undici, WASM-backed HTTP parser) cannot initialise. The shim provides a
 * pure-JS fetch plus an `undici` module alias.
 */
function installJitlessShims() {
  if (typeof WebAssembly !== 'undefined') {
    log('wasm: available, jitless shims not needed')
    return
  }
  log('wasm: unavailable (jitless), installing fetch shim')
  try {
    require('./fetch-shim.cjs').install()
  } catch (error) {
    log(`fetch shim failed: ${error && error.stack || error}`)
  }
  // `import('undici')` bypasses the CommonJS resolve hook, and dsh uses it.
  // Without this, the real undici loads and throws on WebAssembly.
  try {
    const { register } = require('node:module')
    const { pathToFileURL } = require('node:url')
    register('./undici-hooks.mjs', pathToFileURL(__filename).href)
    log('esm: undici resolve hook registered')
  } catch (error) {
    log(`esm hook failed: ${error && error.stack || error}`)
  }
}

/**
 * Replace process.stdin/stdout with the socket-backed streams.
 * Node removed the stdio setters in v24 (the property is a getter-only
 * accessor), so plain assignment throws there; redefining the still
 * configurable property works on every supported version.
 */
function swapStdio(name, stream) {
  const existing = Object.getOwnPropertyDescriptor(process, name)
  if (existing && typeof existing.set === 'function') {
    process[name] = stream
    return
  }
  Object.defineProperty(process, name, {
    value: stream,
    writable: true,
    configurable: true,
    enumerable: existing === undefined ? true : existing.enumerable
  })
}

let bridgeInbound = null
let bridgeOutbound = null

/**
 * The dsh SDK profile captures process.stdin/stdout once at startup, so the
 * backing streams must live for the whole process; every accepted socket is
 * piped into them. Recreating the streams per connection would leave the
 * runtime reading an orphaned pipe after a reconnect.
 */
function ensureBridgeStreams() {
  if (bridgeInbound !== null) return
  bridgeInbound = new PassThrough()
  bridgeOutbound = new PassThrough()
  swapStdio('stdin', bridgeInbound)
  swapStdio('stdout', bridgeOutbound)
}

/** Pipe an accepted socket into the process-long bridge streams. */
function adoptSocket(socket) {
  ensureBridgeStreams()
  const pushInbound = (chunk) => bridgeInbound.write(chunk)
  const pushOutbound = (chunk) => {
    if (!socket.destroyed) socket.write(chunk)
  }
  socket.on('data', pushInbound)
  socket.on('close', () => {
    socket.off('data', pushInbound)
    bridgeOutbound.off('data', pushOutbound)
    // dsh treats stdin EOF as a shutdown request; a dropped UI must not kill
    // the runtime, so pause instead of ending on socket close.
    log('bridge: client stream ended (runtime kept alive)')
  })
  socket.on('error', (error) => log(`bridge socket error: ${error && error.message}`))
  bridgeOutbound.on('data', pushOutbound)
}

/** Boot the dsh SDK runtime in this process. */
async function boot() {
  if (booted) return
  booted = true
  writeStatus('booting')

  process.env.DSH_HOME = DSH_HOME
  process.env.DSH_NO_OPEN = '1'

  // The native bridge dumps the child environment into node.log at start
  // (`[node_bridge] env DEEPSEEK_API_KEY=…`), so the key is handed over as a
  // 0600 file rather than an env var and assigned here — after that line was
  // already written. Anything reading process.env sees the usual name.
  const keyFile = process.env.DSH_KEY_FILE
  if (keyFile && !process.env.DEEPSEEK_API_KEY) {
    try {
      const key = fs.readFileSync(keyFile, 'utf8').trim()
      if (key.length > 0) {
        process.env.DEEPSEEK_API_KEY = key
        log('key: loaded from DSH_KEY_FILE')
      }
    } catch {
      /* no key file: the provider simply stays unauthenticated */
    }
  }
  try {
    fs.mkdirSync(DSH_HOME, { recursive: true })
    fs.mkdirSync(path.join(DSH_HOME, 'tmp'), { recursive: true })
  } catch {
    /* created lazily by dsh if needed */
  }

  installJitlessShims()

  const bin = path.join(PAYLOAD_ROOT, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
  if (!fs.existsSync(bin)) {
    bootError = new Error(`dsh entry not found: ${bin}`)
    log(String(bootError.message))
    writeStatus('failed')
    return
  }

  // The CLI parses process.argv; present it as a normal `dsh --profile <name>`.
  // An optional patch file lets a deployment disable rows that cannot work on
  // this platform (native addons, Windows-only helpers) without touching code.
  const argv = [process.execPath, bin, '--profile', PROFILE]
  const patch = process.env.DSH_PATCH_FILE
  if (patch && fs.existsSync(patch)) {
    argv.push('--patch', patch)
    log(`patch: ${patch}`)
  }
  // `--patch` is repeatable and later rows override earlier ones, so the
  // user patch (Settings capability toggles) rides after the platform patch.
  const userPatch = process.env.DSH_USER_PATCH_FILE
  if (userPatch && fs.existsSync(userPatch)) {
    argv.push('--patch', userPatch)
    log(`patch: ${userPatch}`)
  }
  process.argv = argv

  try {
    log(`boot: ${process.argv.slice(2).join(' ')}`)
    const entry = await import(require('node:url').pathToFileURL(bin).href)
    // bin.js self-executes only when `import.meta.main` is true, which never
    // holds for an in-process dynamic import — invoke the exported CLI.
    if (typeof entry.runCli !== 'function') {
      throw new Error('dsh entry does not export runCli')
    }
    await entry.runCli()
    writeStatus('running')
    // runCli resolves once the profile is mounted (verified for both profiles:
    // the ACP server keeps its own loop alive after the mount promise settles).
    log(`boot: ${PROFILE} runtime mounted`)
    startDebugChmod()
  } catch (error) {
    bootError = error
    log(`boot failed: ${error && error.stack || error}`)
    writeStatus('failed')
  }
}

/**
 * The HarmonyOS app sandbox denies hard links (link(2) → EACCES), which
 * breaks dsh's atomic exclusive publishes (`link tmp -> final` with EEXIST
 * as the collision guard). Fall back to copyFile with COPYFILE_EXCL, which
 * preserves the exclusive-create semantics. Must run before any ESM import
 * of node:fs/promises: builtin named exports snapshot module.exports at
 * first ESM import, so patching the CJS export early makes dsh's
 * `import { link }` bindings pick the wrapper up.
 */
function installLinkFallback() {
  const fsp = require('node:fs/promises')
  const fsSync = require('node:fs')
  const flags = fsSync.constants
  if (typeof fsp.link === 'function') {
    const originalLink = fsp.link
    fsp.link = async function linkSandboxSafe(source, destination) {
      try {
        return await originalLink(source, destination)
      } catch (error) {
        const code = error && error.code
        if (code !== 'EACCES' && code !== 'EPERM') throw error
        await fsp.copyFile(source, destination, flags.COPYFILE_EXCL)
        log(`fs.link fallback (hardlinks denied): ${source} -> ${destination}`)
      }
    }
  }
  if (typeof fsSync.linkSync === 'function') {
    const originalLinkSync = fsSync.linkSync
    fsSync.linkSync = function linkSyncSandboxSafe(source, destination) {
      try {
        return originalLinkSync(source, destination)
      } catch (error) {
        const code = error && error.code
        if (code !== 'EACCES' && code !== 'EPERM') throw error
        fsSync.copyFileSync(source, destination, flags.COPYFILE_EXCL)
        log(`fs.linkSync fallback (hardlinks denied): ${source} -> ${destination}`)
      }
    }
  }
}

/**
 * The HarmonyOS sandbox only vouches for paths below the app files root, but
 * dsh-attachment-local's durability walk (`ensureDurableHome`) opens every
 * ancestor of DSH_HOME read-only and fsyncs it, up to the filesystem root —
 * ancestors like /data refuse the open (EACCES), which surfaces as
 * "unable to persist the prompt image batch" on every inline-image prompt.
 * A refused read-only open of a directory gets a stub handle whose sync() is
 * a no-op, and a denied fsync on a directory fd is swallowed; file fsyncs
 * keep failing loudly. Must run before any ESM import of node:fs/promises
 * for the same named-binding reason as the link fallback.
 */
function installDirSyncFallback() {
  const fsp = require('node:fs/promises')
  const fsSync = require('node:fs')
  const oReadOnly = fsSync.constants.O_RDONLY
  if (typeof fsp.open === 'function') {
    const originalOpen = fsp.open
    fsp.open = async function openSandboxAware(target, flags, mode) {
      try {
        return await originalOpen(target, flags, mode)
      } catch (error) {
        const code = error && error.code
        if (code !== 'EACCES' && code !== 'EPERM' && code !== 'EISDIR') throw error
        if (flags !== undefined && flags !== oReadOnly && flags !== 'r') throw error
        let isDirectory = true
        try {
          isDirectory = fsSync.statSync(target).isDirectory()
        } catch {
          /* Unstatable ancestor: only the durability walk opens such paths read-only. */
        }
        if (!isDirectory) throw error
        log(`fs.open dir fallback (sandbox denied): ${target}`)
        return {
          sync: async () => {},
          close: async () => {}
        }
      }
    }
  }
}

/**
 * `require('node:fs/promises').FileHandle` is undefined on this Node line
 * (the class is not exported through the CJS namespace), so prototype
 * patches that go through `fsp.FileHandle` are dead code and never wrap
 * anything. Recover the real prototype from a live `fsp.open()` instance
 * (a probe file in the sandbox tmp dir), then apply the handle-level
 * fallbacks:
 * - `sync()`: directory fsync is denied by the sandbox (EINVAL/EACCES/...)
 *   and by the userfile mount; swallow it for directories only.
 * - `chmod()/chown()`: the userfile mount under /storage/Users does not
 *   implement POSIX mode/owner changes (fchmod answers EPERM, sdcardfs
 *   semantics); swallow permission errors for descriptors that live on
 *   that mount, rethrow everything else.
 */
function installFileHandleFallbacks() {
  const fsp = require('node:fs/promises')
  const fsSync = require('node:fs')
  const nodeOs = require('node:os')
  const nodePath = require('node:path')
  const MOUNT_PREFIX = '/storage/Users/'
  const tolerantCodes = new Set(['EPERM', 'EACCES', 'EINVAL', 'ENOSYS', 'ENOTSUP'])
  const isUserStoragePath = (target) => typeof target === 'string' && target.startsWith(MOUNT_PREFIX)
  const isTolerant = (error) => error !== null && error !== undefined && tolerantCodes.has(error.code)
  const fdPath = (fd) => {
    try {
      return fsSync.readlinkSync(`/proc/self/fd/${fd}`)
    } catch {
      return ''
    }
  }
  Promise.resolve().then(async () => {
    const probePath = nodePath.join(nodeOs.tmpdir(), `.fh-probe-${process.pid}`)
    let handle
    try {
      handle = await fsp.open(probePath, 'w')
    } catch (error) {
      log(`FileHandle probe failed: ${error && error.message}`)
      return
    }
    try {
      const proto = Object.getPrototypeOf(handle)
      if (proto && typeof proto.sync === 'function') {
        const originalSync = proto.sync
        proto.sync = async function syncMountAware() {
          try {
            return await originalSync.call(this)
          } catch (error) {
            const code = error && error.code
            if (code !== 'EINVAL' && code !== 'EACCES' && code !== 'EPERM' && code !== 'EROFS') throw error
            let isDirectory = false
            try {
              isDirectory = fsSync.fstatSync(this.fd).isDirectory()
            } catch {
              isDirectory = false
            }
            if (!isDirectory) throw error
            log(`fsync dir fallback (denied): fd=${this.fd}`)
          }
        }
      }
      for (const name of ['chmod', 'chown']) {
        if (!proto || typeof proto[name] !== 'function') continue
        const original = proto[name]
        proto[name] = async function mountAware(...args) {
          try {
            return await original.call(this, ...args)
          } catch (error) {
            if (!isTolerant(error)) throw error
            const path = fdPath(this.fd)
            if (!isUserStoragePath(path)) throw error
            log(`FileHandle.${name} fallback (userfile mount denies mode/owner changes): ${path}`)
          }
        }
      }
    } finally {
      try {
        await handle.close()
      } catch {
        /* probe close race is irrelevant */
      }
      try {
        fsSync.unlinkSync(probePath)
      } catch {
        /* probe cleanup is best-effort */
      }
    }
  })
}

/**
 * `/storage/Users/<user>/...` is the userfile mount the document picker
 * grants access to. The mount does not implement POSIX chmod/chown and
 * answers EPERM for every attempt (sdcardfs/FUSE semantics, same as Android
 * user storage). dsh-fs-local's atomic write stages through
 * `mkdir .tmpdir -> chmod 0700 -> open wx -> handle.chmod 0600`, so every
 * write tool call into a bound user directory dies at the first chmod.
 * Wrap the chmod/chown families: permission errors under the mount resolve
 * as no-ops (the mount enforces its own uniform ACL model); anything else
 * rethrows loudly.
 */
function installUserStorageChmodFallback() {
  const fsp = require('node:fs/promises')
  const fsSync = require('node:fs')
  const MOUNT_PREFIX = '/storage/Users/'
  const tolerantCodes = new Set(['EPERM', 'EACCES', 'EINVAL', 'ENOSYS', 'ENOTSUP'])
  const isUserStoragePath = (target) => typeof target === 'string' && target.startsWith(MOUNT_PREFIX)
  const isTolerant = (error) => error !== null && error !== undefined && tolerantCodes.has(error.code)
  for (const name of ['chmod', 'chown']) {
    if (typeof fsp[name] === 'function') {
      const original = fsp[name]
      fsp[name] = function userStorageAware(target, ...rest) {
        return original.call(fsp, target, ...rest).catch((error) => {
          if (!isTolerant(error) || !isUserStoragePath(target)) throw error
          log(`fsp.${name} fallback (userfile mount denies mode/owner changes): ${target}`)
        })
      }
    }
      if (typeof fsSync[`${name}Sync`] === 'function') {
        const syncName = `${name}Sync`
        const original = fsSync[syncName]
        fsSync[syncName] = function userStorageAwareSync(target, ...rest) {
          try {
            return original.call(fsSync, target, ...rest)
          } catch (error) {
            if (!isTolerant(error) || !isUserStoragePath(target)) throw error
            log(`fs.${syncName} fallback (userfile mount denies mode/owner changes): ${target}`)
          }
        }
      }
  }
}

/**
 * libuv's copyFile tries a FICLONE (reflink) ioctl first; the userfile
 * mount (HMDFS under /storage/Users) answers EPERM for it and libuv
 * surfaces the failure instead of falling back to its userland loop.
 * dsh-fs-local publishes new files as `link tmp -> final` (EXCL guard),
 * the link fallback above already downgrades that to
 * copyFile(COPYFILE_EXCL) — so on the userfile mount every file create
 * dies right there. Route copyFile with a userfile endpoint through an
 * explicit read/write loop (COPYFILE_EXCL preserved via `wx`); everything
 * else keeps the native fast path.
 */
function installUserStorageCopyFallback() {
  const fsp = require('node:fs/promises')
  const fsSync = require('node:fs')
  const MOUNT_PREFIX = '/storage/Users/'
  const CHUNK = 1024 * 1024
  const copyfileExcl = fsSync.constants.COPYFILE_EXCL
  const isUserStoragePath = (target) => typeof target === 'string' && target.startsWith(MOUNT_PREFIX)
  async function userlandCopy(src, dst, mode) {
    const excl = mode !== undefined && (mode & copyfileExcl) !== 0
    let srcHandle
    let dstHandle
    try {
      srcHandle = await fsp.open(src, 'r')
      dstHandle = await fsp.open(dst, excl ? 'wx' : 'w')
      const buffer = Buffer.allocUnsafe(CHUNK)
      let position = 0
      for (;;) {
        const { bytesRead } = await srcHandle.read(buffer, 0, CHUNK, position)
        if (bytesRead === 0) break
        await dstHandle.write(buffer, 0, bytesRead, position)
        position += bytesRead
      }
    } finally {
      if (dstHandle) {
        try {
          await dstHandle.close()
        } catch {
          /* best-effort close */
        }
      }
      if (srcHandle) {
        try {
          await srcHandle.close()
        } catch {
          /* best-effort close */
        }
      }
    }
  }
  function userlandCopySync(src, dst, mode) {
    const excl = mode !== undefined && (mode & copyfileExcl) !== 0
    const srcFd = fsSync.openSync(src, 'r')
    let dstFd
    try {
      dstFd = fsSync.openSync(dst, excl ? 'wx' : 'w')
      const buffer = Buffer.allocUnsafe(CHUNK)
      let position = 0
      for (;;) {
        const bytesRead = fsSync.readSync(srcFd, buffer, 0, CHUNK, position)
        if (bytesRead === 0) break
        fsSync.writeSync(dstFd, buffer, 0, bytesRead, position)
        position += bytesRead
      }
    } finally {
      if (dstFd !== undefined) fsSync.closeSync(dstFd)
      fsSync.closeSync(srcFd)
    }
  }
  if (typeof fsp.copyFile === 'function') {
    const original = fsp.copyFile
    fsp.copyFile = async function userStorageAwareCopy(src, dst, mode) {
      if (isUserStoragePath(src) || isUserStoragePath(dst)) {
        log(`fsp.copyFile fallback (userland loop, userfile mount): ${src} -> ${dst}`)
        return userlandCopy(src, dst, mode)
      }
      return original.call(fsp, src, dst, mode)
    }
  }
  if (typeof fsSync.copyFileSync === 'function') {
    const original = fsSync.copyFileSync
    fsSync.copyFileSync = function userStorageAwareCopySync(src, dst, mode) {
      if (isUserStoragePath(src) || isUserStoragePath(dst)) {
        log(`fs.copyFileSync fallback (userland loop, userfile mount): ${src} -> ${dst}`)
        return userlandCopySync(src, dst, mode)
      }
      return original.call(fsSync, src, dst, mode)
    }
  }
}

/**
 * Alias `node-addon-require-builtin` to the pure-JS shim when the native
 * addon cannot load (no openharmony-arm64 binding is published). A normal
 * desktop install keeps the real addon; the shim needs --expose-internals,
 * which the host passes on the Node command line.
 */
function installRequireBuiltinAlias() {
  try {
    require('node-addon-require-builtin')
    return
  } catch {
    /* fall through to the shim */
  }
  const shimPath = path.join(__dirname, 'require-builtin-shim.cjs')
  if (!fs.existsSync(shimPath)) {
    log('addon: node-addon-require-builtin unavailable and shim missing; internal-module access will fail')
    return
  }
  const original = Module._resolveFilename
  Module._resolveFilename = function (request, ...rest) {
    if (request === 'node-addon-require-builtin') return shimPath
    return original.call(this, request, ...rest)
  }
  log('addon: node-addon-require-builtin unavailable, using --expose-internals shim')
}

/**
 * Content hash of the template tree (sorted path + bytes), so a payload
 * update changes the digest and triggers a refresh of the working copy.
 */
function hashTemplateTree(root) {
  const crypto = require('node:crypto')
  const hash = crypto.createHash('sha256')
  const walk = (dir, prefix) => {
    const entries = fs.readdirSync(dir, { withFileTypes: true })
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    for (const entry of entries) {
      const child = path.join(dir, entry.name)
      const rel = prefix + entry.name
      if (entry.isDirectory()) {
        hash.update(rel + '/\0')
        walk(child, rel + '/')
      } else if (entry.isFile()) {
        hash.update(rel + '\0')
        hash.update(fs.readFileSync(child))
        hash.update('\0')
      }
    }
  }
  hash.update('template-v1\0')
  walk(root, '')
  return hash.digest('hex')
}

/** Plain recursive copy (the template holds only regular files and dirs). */
function copyTemplateTree(source, target) {
  fs.mkdirSync(target, { recursive: true })
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name)
    const to = path.join(target, entry.name)
    if (entry.isDirectory()) {
      copyTemplateTree(from, to)
    } else if (entry.isFile()) {
      fs.copyFileSync(from, to)
    }
  }
}

/**
 * Install the shipped `ohos` profile template into $DSH_HOME/profiles/ohos.
 * The payload tree is read-only, so dsh needs a writable working copy. The
 * stamp file records the source content hash: unchanged hash + existing copy
 * → no-op; changed hash (payload update) → refresh. Returns true when a
 * usable template is in place.
 */
function installProfileTemplate() {
  if (PROFILE !== 'acp' && PROFILE !== 'ohos') return false
  if (!fs.existsSync(path.join(PROFILE_TEMPLATE_DIR, 'package.json'))) return false
  const target = path.join(DSH_HOME, 'profiles', 'ohos')
  if (!path.isAbsolute(target)) {
    log('profile template: refusing relative target')
    return false
  }
  let digest = ''
  try {
    digest = hashTemplateTree(PROFILE_TEMPLATE_DIR)
  } catch (error) {
    log(`profile template: hash failed: ${error && error.message}`)
    return false
  }
  const stampFile = path.join(target, TEMPLATE_STAMP_FILE)
  try {
    if (
      fs.existsSync(stampFile) &&
      fs.readFileSync(stampFile, 'utf8').trim() === digest &&
      fs.existsSync(path.join(target, 'package.json'))
    ) {
      return true
    }
    fs.rmSync(target, { recursive: true, force: true })
    copyTemplateTree(PROFILE_TEMPLATE_DIR, target)
    fs.writeFileSync(stampFile, digest + '\n')
    log(`profile template: installed ohos (hash ${digest.slice(0, 12)})`)
    return true
  } catch (error) {
    log(`profile template: install failed: ${error && error.stack || error}`)
    return false
  }
}

/**
 * Redirect require("sharp") to the pure-JS stub. The shipped bindings are
 * darwin-arm64 (cannot dlopen on-device) and wasm32 (needs WebAssembly,
 * absent under --jitless), so the real module always throws and image
 * admission fails with an opaque "unable to persist the prompt image
 * batch". The stub keeps metadata()/raw() probing alive for pass-through
 * images and fails closed on re-encoding. DSH_SHARP_STUB=0 opts out.
 */
function installSharpStub() {
  if (process.env.DSH_SHARP_STUB === '0') {
    log('sharp-stub: disabled via DSH_SHARP_STUB=0')
    return
  }
  const stubPath = path.join(__dirname, 'sharp-stub.cjs')
  if (!fs.existsSync(stubPath)) {
    log('sharp-stub: stub file missing; image admission will fail on-device')
    return
  }
  const originalLoad = Module._load
  Module._load = function (request, parent, isMain) {
    if (request === 'sharp') return require(stubPath)
    return originalLoad.apply(this, arguments)
  }
  log('sharp-stub: require("sharp") redirected to pure-JS stub (pass-through images only)')
}

function main() {
  rerouteConsole()
  installRequireBuiltinAlias()
  installSharpStub()
  installLinkFallback()
  installDirSyncFallback()
  installUserStorageChmodFallback()
  installUserStorageCopyFallback()
  installFileHandleFallbacks()
  tightenKeyFile()
  const templateReady = installProfileTemplate()
  if (PROFILE === 'acp' && templateReady) {
    PROFILE = 'ohos'
    log('profile: remapping acp -> ohos (custom template present)')
  }
  process.on('uncaughtException', (error) => {
    bootError = error
    log(`uncaught: ${error && error.stack || error}`)
    writeStatus('crashed')
  })
  process.on('unhandledRejection', (error) => log(`unhandled rejection: ${error && error.stack || error}`))

  const server = net.createServer((socket) => {
    if (client && !client.destroyed) {
      log('bridge: replacing previous client')
      client.destroy()
    }
    client = socket
    socket.setNoDelay(true)
    log('bridge: client connected')
    adoptSocket(socket)
    void boot()
  })

  server.on('error', (error) => {
    bootError = error
    log(`bridge server error: ${error && error.message}`)
    writeStatus('failed')
  })

  server.listen(PORT, HOST, () => {
    log(`bridge: listening on ${HOST}:${PORT}`)
    writeStatus('listening')
  })
}

main()
