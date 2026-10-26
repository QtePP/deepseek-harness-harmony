/**
 * Jitless fetch shim for Node on HarmonyOS.
 *
 * Under `--jitless`, `WebAssembly` is undefined. Node's built-in `fetch` is
 * implemented by undici, whose HTTP parser (llhttp) ships as WASM, so every
 * outbound request fails before it reaches the network. On Node ≥24 the whole
 * fetch family (fetch/Headers/Response/Request/FormData) sits behind lazy
 * accessors, and dsh reads globalThis.Headers during boot
 * (dsh-deepseek-account-platform platformHeaders), so `install()` swaps the
 * ENTIRE family via defineProperty — descriptor replacement, never assignment:
 * assignment goes through the accessor and materialises the WASM undici
 * regardless of jitless. dsh also imports `undici` directly in a few places.
 *
 * This module provides a dependency-free replacement built on `node:http` /
 * `node:https` and `node:stream/web`, plus resolution aliases for `undici`
 * (CommonJS and ESM). It is intentionally tolerant: undici-only APIs are
 * stubbed so an import never throws, even when the feature degrades.
 */

'use strict'

const http = require('node:http')
const https = require('node:https')
const { ReadableStream } = require('node:stream/web')
const { URL } = require('node:url')
const Module = require('node:module')

/** Headers with the subset of the WHATWG API that real clients use. */
class Headers {
  constructor(init) {
    this._map = new Map()
    if (!init) return
    if (typeof init.forEach === 'function' && !Array.isArray(init)) {
      init.forEach((value, key) => this.set(key, value))
    } else if (Array.isArray(init)) {
      for (const pair of init) this.append(pair[0], pair[1])
    } else {
      for (const key of Object.keys(init)) this.set(key, init[key])
    }
  }

  set(name, value) {
    this._map.set(String(name).toLowerCase(), String(value))
  }

  append(name, value) {
    const key = String(name).toLowerCase()
    const existing = this._map.get(key)
    this._map.set(key, existing === undefined ? String(value) : `${existing}, ${value}`)
  }

  get(name) {
    const value = this._map.get(String(name).toLowerCase())
    return value === undefined ? null : value
  }

  has(name) {
    return this._map.has(String(name).toLowerCase())
  }

  delete(name) {
    this._map.delete(String(name).toLowerCase())
  }

  forEach(callback) {
    this._map.forEach((value, key) => callback(value, key, this))
  }

  entries() {
    return this._map.entries()
  }

  [Symbol.iterator]() {
    return this._map.entries()
  }
}

/** Minimal Request for callers that construct one before passing it to fetch. */
class Request {
  constructor(url, init) {
    const options = init || {}
    this.url = typeof url === 'string' ? url : url.url
    this.method = (options.method || 'GET').toUpperCase()
    this.headers = new Headers(options.headers)
    this.body = options.body
    this.signal = options.signal
  }

  clone() {
    return this
  }
}

/** Minimal FormData: append/get/has/entries, good enough for multipart builders. */
class FormData {
  constructor() {
    this._map = new Map()
  }

  append(name, value) {
    const key = String(name)
    const list = this._map.get(key)
    if (list === undefined) this._map.set(key, [String(value)])
    else list.push(String(value))
  }

  get(name) {
    const list = this._map.get(String(name))
    return list === undefined || list.length === 0 ? null : list[0]
  }

  getAll(name) {
    return (this._map.get(String(name)) || []).slice()
  }

  has(name) {
    return this._map.has(String(name))
  }

  entries() {
    const out = []
    this._map.forEach((list, key) => {
      for (const value of list) out.push([key, value])
    })
    return out[Symbol.iterator]()
  }

  [Symbol.iterator]() {
    return this.entries()
  }

  forEach(callback) {
    for (const entry of this.entries()) callback(entry[1], entry[0], this)
  }
}

/** Minimal Response with a real streaming body. */
class Response {
  constructor(stream, init) {
    const options = init || {}
    this.status = options.status === undefined ? 200 : options.status
    this.statusText = options.statusText || ''
    this.headers = options.headers instanceof Headers ? options.headers : new Headers(options.headers)
    this.url = options.url || ''
    this.redirected = Boolean(options.redirected)
    this.body = stream
    this.bodyUsed = false
  }

  get ok() {
    return this.status >= 200 && this.status < 300
  }

  _consume() {
    if (this.bodyUsed) return Promise.reject(new TypeError('body already used'))
    this.bodyUsed = true
    if (!this.body) return Promise.resolve(Buffer.alloc(0))
    const reader = this.body.getReader()
    const chunks = []
    const pump = () => reader.read().then(({ done, value }) => {
      if (done) return Buffer.concat(chunks)
      chunks.push(Buffer.from(value))
      return pump()
    })
    return pump()
  }

  arrayBuffer() {
    return this._consume().then((buffer) => buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength))
  }

  text() {
    return this._consume().then((buffer) => buffer.toString('utf8'))
  }

  json() {
    return this.text().then((text) => JSON.parse(text))
  }

  clone() {
    return this
  }
}

/** Convert an IncomingMessage into a web ReadableStream. */
function toStream(res) {
  return new ReadableStream({
    start(controller) {
      res.on('data', (chunk) => controller.enqueue(new Uint8Array(chunk)))
      res.on('end', () => controller.close())
      res.on('error', (error) => controller.error(error))
    },
    cancel() {
      res.destroy()
    }
  })
}

/** Normalise the many body shapes callers pass. */
function encodeBody(body) {
  if (body === undefined || body === null) return null
  if (typeof body === 'string') return Buffer.from(body, 'utf8')
  if (Buffer.isBuffer(body)) return body
  if (body instanceof Uint8Array) return Buffer.from(body)
  if (body instanceof ArrayBuffer) return Buffer.from(new Uint8Array(body))
  if (typeof body === 'object' && typeof body.toString === 'function') return Buffer.from(body.toString(), 'utf8')
  return null
}

/**
 * fetch-compatible request. Follows redirects up to `redirectLimit`, honours
 * AbortSignal, and never buffers the response (SSE keeps streaming).
 */
function fetchImpl(input, init) {
  const options = init || {}
  const target = typeof input === 'string' ? input : (input && input.url) || String(input)
  const url = new URL(target)
  const isHttps = url.protocol === 'https:'
  const transport = isHttps ? https : http

  const headers = {}
  const source = options.headers
  if (source) {
    if (source instanceof Headers) source.forEach((value, key) => { headers[key] = value })
    else if (Array.isArray(source)) for (const pair of source) headers[pair[0]] = pair[1]
    else for (const key of Object.keys(source)) headers[key] = source[key]
  }

  const payload = encodeBody(options.body)
  if (payload && headers['content-length'] === undefined && headers['Content-Length'] === undefined) {
    headers['content-length'] = String(payload.length)
  }

  const signal = options.signal
  return new Promise((resolve, reject) => {
    if (signal && signal.aborted) {
      reject(new DOMExceptionLike('The operation was aborted.', 'AbortError'))
      return
    }

    const request = transport.request({
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port || (isHttps ? 443 : 80),
      path: `${url.pathname}${url.search}`,
      method: (options.method || 'GET').toUpperCase(),
      headers
    }, (res) => {
      const status = res.statusCode || 0
      const location = res.headers.location
      const limit = options.redirect === 'manual' ? 0 : (typeof options.follow === 'number' ? options.follow : 5)
      if (status >= 300 && status < 400 && location && limit > 0) {
        res.resume()
        const next = new URL(location, url).href
        resolve(fetchImpl(next, { ...options, follow: limit - 1, redirected: true }))
        return
      }
      const responseHeaders = new Headers()
      for (const key of Object.keys(res.headers)) {
        const value = res.headers[key]
        if (Array.isArray(value)) for (const item of value) responseHeaders.append(key, item)
        else if (value !== undefined) responseHeaders.set(key, value)
      }
      resolve(new Response(toStream(res), {
        status,
        statusText: res.statusMessage || '',
        headers: responseHeaders,
        url: url.href,
        redirected: Boolean(options.redirected)
      }))
    })

    request.on('error', (error) => reject(error))
    if (signal) {
      const abort = () => {
        request.destroy(new DOMExceptionLike('The operation was aborted.', 'AbortError'))
      }
      if (typeof signal.addEventListener === 'function') signal.addEventListener('abort', abort)
    }
    if (payload) request.write(payload)
    request.end()
  })
}

/** Error shape close enough to DOMException for `err.name === 'AbortError'`. */
class DOMExceptionLike extends Error {
  constructor(message, name) {
    super(message)
    this.name = name
  }
}

/** undici surface that dsh may touch; unsupported knobs degrade quietly. */
class Agent {
  constructor(options) {
    this.options = options || {}
  }

  close() {
    return Promise.resolve()
  }

  destroy() {
    return Promise.resolve()
  }
}

let dispatcher = new Agent()

function install() {
  // IMPORTANT: never *read* globalThis.fetch / Headers / Response / Request here.
  // In Node they are lazy accessors whose first read initialises the built-in
  // undici, whose llhttp parser is WASM — under --jitless that read rejects
  // with "ReferenceError: WebAssembly is not defined". defineProperty replaces
  // the accessor without invoking it.
  const define = (name, value) => {
    try {
      Object.defineProperty(globalThis, name, {
        value,
        writable: true,
        configurable: true,
        enumerable: false
      })
    } catch {
      /* non-configurable on exotic runtimes; nothing else to do */
    }
  }

  // Node ≥24 installs the fetch family as LAZY ACCESSORS: the first read of
  // fetch/Headers/Response/Request/FormData materialises the built-in undici,
  // whose llhttp parser is WASM — under --jitless that read throws
  // "ReferenceError: WebAssembly is not defined". dsh reads globalThis.Headers
  // while still booting (dsh-deepseek-account-platform platformHeaders →
  // `new Headers()` inside `new PlatformAccount`), so the whole family must be
  // swapped BEFORE dsh loads. defineProperty replaces the accessor descriptor
  // without invoking it; plain assignment would go through the setter and
  // materialise anyway (that side effect is what the old build owed its
  // accidental boot protection to).
  const replacements = {
    fetch: fetchImpl,
    Headers,
    Response,
    Request,
    FormData
  }
  for (const name of Object.keys(replacements)) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name)
    const shape = descriptor === undefined
      ? 'absent'
      : descriptor.get || descriptor.set
        ? `lazy accessor (configurable: ${descriptor.configurable})`
        : 'plain value'
    define(name, replacements[name])
    console.error(`fetch-shim: globalThis.${name} was ${shape}, replaced with shim`)
  }

  // CommonJS alias: `require('undici')` resolves here.
  const original = Module._resolveFilename
  Module._resolveFilename = function (request, ...rest) {
    if (request === 'undici') return __filename
    return original.call(this, request, ...rest)
  }

  // Guard against an explicit `require('node:internal/deps/undici/undici')`
  // under --expose-internals: the bundle's global.js eagerly constructs an
  // Agent whose llhttp is WASM — fatal under jitless. Serve the shim instead.
  const originalLoad = Module._load
  Module._load = function (request, parent, isMain) {
    if (typeof request === 'string' && request.includes('internal/deps/undici')) {
      return module.exports
    }
    return originalLoad.call(this, request, parent, isMain)
  }

  module.exports.fetch = fetchImpl
  module.exports.Headers = Headers
  module.exports.Response = Response
  module.exports.Request = Request
  module.exports.FormData = FormData
  module.exports.Agent = Agent
  module.exports.setGlobalDispatcher = (next) => { dispatcher = next || dispatcher }
  module.exports.getGlobalDispatcher = () => dispatcher
  module.exports.request = (url, init) => fetchImpl(url, init)
  module.exports.installed = true
}

module.exports = {
  install,
  fetch: fetchImpl,
  Headers,
  Response,
  Request,
  FormData,
  Agent,
  setGlobalDispatcher: (next) => { dispatcher = next || dispatcher },
  getGlobalDispatcher: () => dispatcher,
  request: (url, init) => fetchImpl(url, init)
}
