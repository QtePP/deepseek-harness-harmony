/**
 * ESM facade for the jitless fetch shim.
 *
 * `fetch-shim.cjs` patches CommonJS resolution (`require('undici')`), but dsh
 * also does `await import('undici')`, which bypasses `Module._resolveFilename`.
 * On device that path reached the real undici, whose llhttp parser is WASM, and
 * threw `ReferenceError: WebAssembly is not defined` under `--jitless`.
 *
 * `undici-hooks.mjs` maps the bare specifier here so both module systems land
 * on the same pure-JS implementation.
 */

import shim from './fetch-shim.cjs'

export const fetch = shim.fetch
export const Headers = shim.Headers
export const Response = shim.Response
export const Request = shim.Request
export const FormData = shim.FormData
export const Agent = shim.Agent
export const request = shim.request
export const setGlobalDispatcher = shim.setGlobalDispatcher
export const getGlobalDispatcher = shim.getGlobalDispatcher

export default shim
