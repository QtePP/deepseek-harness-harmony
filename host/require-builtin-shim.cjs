/**
 * Shim for `node-addon-require-builtin` on platforms without a native binding
 * (HarmonyOS: no openharmony-arm64 build exists).
 *
 * dsh-app-boot reaches Node's internal module loader through
 * `require("node-addon-require-builtin").requireBuiltin(id)`. The real addon
 * probes internal access natively; the same access is available to plain
 * `require()` when Node runs with `--expose-internals`, which is how this
 * shim implements it. Without that flag every requireBuiltin call throws
 * with a pointed message instead of a confusing module-not-found.
 *
 * `host/bootstrap.cjs` aliases the package name to this file via
 * `Module._resolveFilename` ONLY when the real addon cannot be loaded, so a
 * normal desktop install keeps using the native addon.
 */

'use strict'

function requireBuiltin(moduleId) {
  try {
    return require(moduleId)
  } catch (error) {
    if (!process.execArgv.includes('--expose-internals')) {
      throw new Error(
        'require-builtin shim: internal modules are not requireable — ' +
        'start Node with --expose-internals (missing flag, first failure: ' +
        `${error && error.message})`
      )
    }
    throw error
  }
}

function isAllowedInternalId(moduleId) {
  try {
    require.resolve(moduleId)
    return true
  } catch {
    return false
  }
}

function getBindingInfo() {
  return {
    backend: 'expose-internals-shim',
    native: false,
    platform: process.platform,
    arch: process.arch
  }
}

module.exports = {
  requireBuiltin,
  isAllowedInternalId,
  getBindingInfo
}
