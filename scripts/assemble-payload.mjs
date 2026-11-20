#!/usr/bin/env node
/**
 * Assemble the on-device dsh payload.
 *
 * Produces `entry/src/main/resources/rawfile/dsh-payload.zip`, which the ArkTS
 * host extracts into the app sandbox on first launch and then hands to the
 * in-process Node runtime as its working tree.
 *
 * Layout inside the archive:
 *
 *   bootstrap.cjs        Node entry (TCP bridge + stdio hijack + dsh boot)
 *   fetch-shim.cjs       pure-JS fetch for --jitless (no WebAssembly)
 *   package.json         {"type":"commonjs"}
 *   node_modules/        @deepseek-ai/dsh and its dependencies
 *   profile-ohos/        custom `ohos` profile template (pure-JS search bundle);
 *                        bootstrap.cjs copies it into $DSH_HOME/profiles and
 *                        remaps DSH_PROFILE=acp -> ohos when present
 *   patches/             profile patch YAMLs (platform + user capability toggles)
 *
 * Usage:
 *   node scripts/assemble-payload.mjs                # install the pinned version + pack
 *   node scripts/assemble-payload.mjs --skip-install  # repack existing staging
 *   node scripts/assemble-payload.mjs --skip-pack     # stage only (CI runs the plugin tests here)
 *   node scripts/assemble-payload.mjs --dsh-version 0.2.2-rc.6   # explicit override
 *
 * The version is PINNED, not `latest`: this tree is the single source of the
 * AI capability, so a rebuild must never silently swap the brain. Bumping it
 * is a deliberate change that carries the doc updates (AGENTS.md §2/§6/§7,
 * tool table, search provider) and a fresh three-stage validation with it.
 */

import { execFileSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const args = process.argv.slice(2)
const stagingIndex = args.indexOf('--staging')
// A fresh staging directory avoids deleting an existing tree (which may be
// large enough to trip safety guards); reuse one explicitly with --staging.
const STAGING = resolve(ROOT, stagingIndex >= 0 ? args[stagingIndex + 1] : '.build/payload')
const OUT = join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'dsh-payload.zip')
const HOST_DIR = join(ROOT, 'host')

/** Pinned dsh version shipped in the payload. See the header for the policy. */
const PINNED_DSH_VERSION = '0.2.2-rc.5'

const skipInstall = args.includes('--skip-install')
// CI needs the staged tree (to run the plugin unit tests) but must not spend
// two minutes compressing 1 GB into a 240 MB zip it will not use.
const skipPack = args.includes('--skip-pack')
const versionIndex = args.indexOf('--dsh-version')
const dshVersion = versionIndex >= 0 ? args[versionIndex + 1] : PINNED_DSH_VERSION

function run(command, commandArgs, cwd) {
  process.stdout.write(`$ ${command} ${commandArgs.join(' ')}\n`)
  execFileSync(command, commandArgs, { cwd, stdio: 'inherit' })
}

function prepareStaging() {
  mkdirSync(STAGING, { recursive: true })
  if (skipInstall) {
    process.stdout.write('reusing staging tree (--skip-install)\n')
    return
  }

  rmSync(join(STAGING, 'node_modules'), { recursive: true, force: true })
  writeFileSync(join(STAGING, 'package.json'), JSON.stringify({
    name: 'dsh-ohos-payload',
    private: true,
    type: 'commonjs',
    dependencies: { '@deepseek-ai/dsh': dshVersion }
  }, null, 2))

  // --ignore-scripts is required: koffi (a regular dsh dependency) runs a
  // cmake build on install and fails on machines without a toolchain. Its
  // prebuilt FFI binary is useless on HarmonyOS anyway — the platform only
  // executes code inside the app's own signing domain.
  run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund'], STAGING)
}

function stageHost() {
  for (const file of ['bootstrap.cjs', 'fetch-shim.cjs', 'require-builtin-shim.cjs',
                      'sharp-stub.cjs', 'undici-esm.mjs', 'undici-hooks.mjs']) {
    cpSync(join(HOST_DIR, file), join(STAGING, file))
  }
  // Profile patches travel with the payload; presence of ohos.patch.yml (not
  // the .example) is what activates them at boot.
  const patches = join(HOST_DIR, 'patches')
  if (existsSync(patches)) {
    cpSync(patches, join(STAGING, 'patches'), { recursive: true })
  }
  writeFileSync(join(STAGING, 'package.json'), JSON.stringify({
    name: 'dsh-ohos-payload',
    private: true,
    type: 'commonjs',
    main: 'bootstrap.cjs'
  }, null, 2))
}

/**
 * Stage the custom `ohos` profile template (pure-JS glob/grep search bundle
 * and friends). bootstrap.cjs looks for `<payload>/profile-ohos/profiles/ohos`
 * at boot: present → install into $DSH_HOME/profiles + remap acp → ohos;
 * absent → stock profiles only.
 */
function stageProfileTemplate() {
  const source = join(HOST_DIR, 'profile-ohos', 'profiles')
  if (!existsSync(join(source, 'ohos', 'package.json'))) {
    throw new Error(`ohos profile template missing: ${join(source, 'ohos', 'package.json')}`)
  }
  rmSync(join(STAGING, 'profile-ohos'), { recursive: true, force: true })
  cpSync(source, join(STAGING, 'profile-ohos', 'profiles'), { recursive: true })
}

/**
 * Replace the POSIX flock binding with a single-process no-op.
 *
 * HarmonyOS forbids fork/exec, so the app process is the only writer of the
 * session JSONL files and a lock can never contend. The native platform
 * package `@deepseek-ai/node-addon-system-<platform>-<arch>` has no
 * openharmony build, and the original flock.js rejects non-linux/darwin
 * platforms outright (ERR_FLOCK_UNSUPPORTED_PLATFORM) — the session
 * persistence layer imports it lazily at first turn and every turn would
 * fail with a module-not-found on the platform package.
 */
function patchNodeModules() {
  const flock = join(STAGING, 'node_modules', '@deepseek-ai', 'node-addon-system', 'lib', 'flock.js')
  if (!existsSync(flock)) {
    throw new Error(`flock entry missing after install: ${flock}`)
  }
  writeFileSync(flock, [
    '/** Single-process no-op flock — HarmonyOS payload patch, see scripts/assemble-payload.mjs. */',
    'export async function tryLockExclusive(_fd) {',
    '\treturn',
    '}',
    ''
  ].join('\n'))
}

/**
 * Drop packages that can never load on HarmonyOS.
 *
 * dsh 0.2.2 pulls in ~312 MB of LibreOffice kits (darwin-arm64 + wasm) and a
 * darwin sharp/sherpa pair. None of them can run here: the platform executes
 * only inside the app's signing domain (no native prebuilts), and jitless means
 * no WebAssembly. They were 225 MB -> 353 MB of the payload for code that is
 * unreachable, so prune them and let the zip stay near its old size.
 *
 * Deliberately conservative, and learned the hard way: `dsh-subprocess-local`
 * imports `@deepseek-ai/dsh-win32-process` statically even on other platforms,
 * so pruning it by name broke the boot ("2 required plugins did not activate").
 * Only packages that are loaded lazily or never may be removed; the boot smoke
 * is what proves it, so run it after any change to this list.
 */
function pruneForeignPlatformPackages() {
  const modules = join(STAGING, 'node_modules')
  const doomed = [
    '@deepseek-ai/libreoffice-kit-darwin-arm64',
    '@deepseek-ai/libreoffice-kit-wasm',
    '@deepseek-ai/node-addon-system-darwin-arm64',
    'sherpa-onnx-darwin-arm64',
    'sherpa-onnx-win-x64',
    'sherpa-onnx-linux-x64'
  ]
  let freed = 0
  for (const name of doomed) {
    const target = join(modules, name)
    if (!existsSync(target)) {
      continue
    }
    freed += dirSize(target)
    rmSync(target, { recursive: true, force: true })
  }
  if (freed > 0) {
    process.stdout.write(`pruned ${Math.round(freed / 1048576)} MB of foreign-platform packages\n`)
  }
}

function dirSize(dir) {
  let total = 0
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    total += entry.isDirectory() ? dirSize(full) : statSync(full).size
  }
  return total
}

function verify() {
  const entry = join(STAGING, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
  if (!existsSync(entry)) {
    throw new Error(`dsh entry missing after install: ${entry}`)
  }
  const pkg = JSON.parse(readFileSync(join(STAGING, 'node_modules', '@deepseek-ai', 'dsh', 'package.json'), 'utf8'))
  process.stdout.write(`dsh ${pkg.version} staged at ${STAGING}\n`)
  return pkg.version
}

function pack() {
  mkdirSync(dirname(OUT), { recursive: true })
  rmSync(OUT, { force: true })
  // -y keeps symlinks as links; npm trees are link-free, so -r is enough.
  run('zip', ['-r', '-q', '-9', OUT, '.'], STAGING)
  const bytes = execFileSync('du', ['-h', OUT]).toString().trim()
  process.stdout.write(`payload written: ${OUT} (${bytes.split('\t')[0]})\n`)
}

prepareStaging()
stageHost()
stageProfileTemplate()
pruneForeignPlatformPackages()
patchNodeModules()
const version = verify()
if (skipPack) {
  process.stdout.write(`\ndone — dsh ${version} staged at ${STAGING} (--skip-pack, no zip)\n`)
  process.stdout.write('next: bash scripts/test.sh unit (payload plugin suites)\n')
} else {
  pack()
  process.stdout.write(`\ndone — dsh ${version} packaged for HarmonyOS\n`)
  process.stdout.write('next: hvigorw assembleHap (or Build > Build Hap(s) in DevEco Studio)\n')
}
