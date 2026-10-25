/**
 * Jitless fetch shim for Node on HarmonyOS.
 *
 * Under `--jitless`, `WebAssembly` is undefined. Node's built-in `fetch` is
 * implemented by undici, whose HTTP parser (llhttp) ships as WASM, so every
 * outbound request fails before it reaches the network. dsh imports `undici`
 * directly in a few places and otherwise uses the global `fetch`.
 *
 * This module provides a dependency-free replacement built on `node:http` /
 * `node:https` and `node:stream/web`, plus a CommonJS resolution alias for
 * `undici`. It is intentionally tolerant: undici-only APIs are stubbed so an
 * import never throws, even when the feature degrades.
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

  if (typeof WebAssembly === 'undefined') {
    define('fetch', fetchImpl)
  } else if (typeof globalThis.fetch !== 'function') {
    define('fetch', fetchImpl)
  }
  // Deliberately NOT redefining Headers / Response / Request: measured on Node
  // 24.2.0, redefining any of the three materialises Node's lazy web globals,
  // which initialises the built-in undici and rejects with
  // "WebAssembly is not defined" under --jitless. Redefining `fetch` alone is
  // safe, and callers that construct Headers themselves still get ours through
  // the returned Response objects.

  // CommonJS alias: `require('undici')` resolves here.
  const original = Module._resolveFilename
  Module._resolveFilename = function (request, ...rest) {
    if (request === 'undici') return __filename
    return original.call(this, request, ...rest)
  }

  module.exports.fetch = fetchImpl
  module.exports.Headers = Headers
  module.exports.Response = Response
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
  Agent,
  setGlobalDispatcher: (next) => { dispatcher = next || dispatcher },
  getGlobalDispatcher: () => dispatcher,
  request: (url, init) => fetchImpl(url, init)
}
