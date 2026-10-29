/*
 * Pure-JS stand-in for the `sharp` module on HarmonyOS.
 *
 * The payload's `sharp` dependency ships only darwin-arm64 and wasm32
 * bindings: the Mach-O objects cannot dlopen on-device and the wasm32
 * fallback needs WebAssembly, which --jitless forbids. bootstrap.cjs
 * redirects require("sharp") here (DSH_SHARP_STUB=0 opts out), so
 * dsh-attachment-local keeps working for pass-through images:
 *
 *   - metadata() parses real container headers (JPEG/PNG/WebP/GIF),
 *     so canPassThroughNormalization sees true facts;
 *   - raw().toBuffer() validates container framing and returns a
 *     placeholder raster (callers only use it as a decodeability probe);
 *   - the re-encoding ladder (rotate/resize + jpeg/webp) has no libvips
 *     stand-in, so `.jpeg()` hands back the source bytes unchanged and
 *     reports the source dimensions. dsh's request projection then degrades
 *     to a pass-through: the provider downsamples onto its own vision grid,
 *     so the only cost is a larger upload. WebP/PNG/TIFF/GIF output still
 *     fails closed — those bytes cannot stand in for a JPEG.
 */

'use strict'

class SharpStubError extends Error {
  constructor(message) {
    super(message)
    this.name = 'SharpStubError'
  }
}

function isBytes(data) {
  return Buffer.isBuffer(data) || data instanceof Uint8Array
}

function u16be(b, o) { return (b[o] << 8) | b[o + 1] }
function u16le(b, o) { return b[o] | (b[o + 1] << 8) }
function u24le(b, o) { return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) }
function u32be(b, o) { return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0 }

/** JPEG scan: framing, SOF dimensions, EXIF APP1 presence, EOI terminator.
 * ICC APP2 segments are deliberately NOT reported: HarmonyOS ImagePacker always
 * embeds an ICC profile, and dsh treats metadata.icc/hasProfile as retained
 * metadata which would force the (unavailable) normalize path. ICC chunks are
 * color-description only and harmless to downstream vision APIs. */
function probeJpeg(b) {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) throw unsupported('JPEG')
  let off = 2
  let sof = null
  let exif = false
  let xmp = false
  while (off + 4 <= b.length) {
    if (b[off] !== 0xff) throw malformed('JPEG marker stream desynchronized')
    const marker = b[off + 1]
    if (marker === 0xd9) {
      if (sof === null) throw malformed('JPEG ended before any frame header')
      // EOI may be followed by padding; treat it as the terminator.
      return {
        format: 'jpeg',
        width: sof.width,
        height: sof.height,
        progressive: sof.progressive,
        exif: exif ? Buffer.alloc(0) : undefined,
        xmp: xmp ? Buffer.alloc(0) : undefined,
      }
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { off += 2; continue }
    if (off + 4 > b.length) throw malformed('JPEG segment header truncated')
    const size = u16be(b, off + 2)
    if (size < 2 || off + 2 + size > b.length) throw malformed('JPEG segment overruns buffer')
    const segStart = off + 4
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      if (size < 7) throw malformed('JPEG SOF segment too short')
      // SOF body: precision(1) height(2) width(2) components(1)...
      sof = {
        height: u16be(b, segStart + 1),
        width: u16be(b, segStart + 3),
        progressive: marker === 0xc2,
      }
    } else if (marker === 0xe1) {
      if (size >= 8 && b[segStart] === 0x45 && b[segStart + 1] === 0x78 &&
          b[segStart + 2] === 0x69 && b[segStart + 3] === 0x66 && b[segStart + 4] === 0) exif = true
      else xmp = true
    } else if (marker === 0xed) {
      xmp = true // APP13 Photoshop/IPTC
    }
    if (marker === 0xda) {
      // Entropy-coded scan: marker segments stop until EOI; scan for it.
      if (sof === null) throw malformed('JPEG SOS before frame header')
      let i = off + 2 + size
      while (i + 1 < b.length) {
        if (b[i] === 0xff && b[i + 1] === 0xd9) {
          return {
            format: 'jpeg',
            width: sof.width,
            height: sof.height,
            progressive: sof.progressive,
            exif: exif ? Buffer.alloc(0) : undefined,
            xmp: xmp ? Buffer.alloc(0) : undefined,
          }
        }
        i++
      }
      throw malformed('JPEG scan never terminated with EOI')
    }
    off += 2 + size
  }
  throw malformed('JPEG stream ended without EOI')
}

/** PNG: signature, IHDR facts, IEND terminator. */
function probePng(b) {
  const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  if (b.length < 8 || !b.slice(0, 8).equals(SIG)) throw unsupported('PNG')
  if (b.length < 33) throw malformed('PNG shorter than IHDR')
  const chunkType = (o) => b.slice(o + 4, o + 8).toString('latin1')
  if (chunkType(8) !== 'IHDR' || u32be(b, 8) !== 13) throw malformed('PNG does not open with IHDR')
  const width = u32be(b, 16)
  const height = u32be(b, 20)
  const bitDepth = b[24]
  const colorType = b[25]
  if (width === 0 || height === 0) throw malformed('PNG has zero dimension')
  let off = 8
  let sawIend = false
  while (off + 12 <= b.length) {
    const len = u32be(b, off)
    if (off + 12 + len > b.length) throw malformed('PNG chunk overruns buffer')
    const type = chunkType(off)
    if (type === 'IEND') { sawIend = true; break }
    off += 12 + len
  }
  if (!sawIend) throw malformed('PNG stream ended without IEND')
  return {
    format: 'png',
    width,
    height,
    depth: bitDepth === 16 ? 'ushort' : 'uchar',
    hasAlpha: colorType === 4 || colorType === 6,
  }
}

/** WebP: VP8X / VP8L / VP8 headers inside RIFF. */
function probeWebp(b) {
  if (b.length < 30) throw unsupported('WebP')
  if (b.slice(0, 4).toString('latin1') !== 'RIFF' || b.slice(8, 12).toString('latin1') !== 'WEBP') {
    throw unsupported('WebP')
  }
  const tag = b.slice(12, 16).toString('latin1')
  if (tag === 'VP8X') {
    if (b.length < 30) throw malformed('WebP VP8X truncated')
    const width = 1 + u24le(b, 24)
    const height = 1 + u24le(b, 27)
    return { format: 'webp', width, height, hasAlpha: (b[20] & 0x10) !== 0 }
  }
  if (tag === 'VP8L') {
    if (b.length < 25) throw malformed('WebP VP8L truncated')
    const bits = u32be(b, 21)
    return { format: 'webp', width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1, hasAlpha: (bits & 0x10000000) !== 0 }
  }
  if (tag === 'VP8 ') {
    if (b.length < 30) throw malformed('WebP VP8 truncated')
    if (b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) throw malformed('WebP VP8 sync code mismatch')
    return { format: 'webp', width: u16le(b, 26) & 0x3fff, height: u16le(b, 28) & 0x3fff, hasAlpha: false }
  }
  throw unsupported('WebP')
}

/** GIF: logical screen descriptor + frame count (pages). */
function probeGif(b) {
  if (b.length < 13) throw unsupported('GIF')
  const sig = b.slice(0, 6).toString('latin1')
  if (sig !== 'GIF87a' && sig !== 'GIF89a') throw unsupported('GIF')
  const width = u16le(b, 6)
  const height = u16le(b, 8)
  let off = 13
  let pages = 0
  while (off < b.length) {
    const block = b[off]
    if (block === 0x3b) break
    if (block === 0x21) {
      if (off + 2 > b.length) throw malformed('GIF extension truncated')
      off += 2
      while (off < b.length && b[off] !== 0) off += 1 + b[off]
      off++
      continue
    }
    if (block === 0x2c) {
      pages++
      if (off + 10 > b.length) throw malformed('GIF image descriptor truncated')
      off += 10
      if (b[off - 1] & 0x80) off += 3 * (1 << ((b[off - 1] & 0x07) + 1))
      if (off >= b.length) throw malformed('GIF LZW stream truncated')
      off++ // LZW min code size
      while (off < b.length && b[off] !== 0) off += 1 + b[off]
      off++
      continue
    }
    throw malformed('GIF block stream desynchronized')
  }
  if (pages === 0) throw malformed('GIF has no frames')
  return { format: 'gif', width, height, pages }
}

function unsupported(kind) {
  return new SharpStubError(`Input buffer contains unsupported ${kind} data`)
}
function malformed(why) {
  return new SharpStubError(`Input buffer contains corrupt image data: ${why}`)
}

/** Detect the container and return sharp-compatible metadata facts. */
function inspect(data) {
  if (!isBytes(data) || data.length === 0) throw malformed('empty or non-binary input')
  const b = Buffer.isBuffer(data) ? data : Buffer.from(data.buffer, data.byteOffset, data.byteLength)
  let facts
  if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) facts = probeJpeg(b)
  else if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) facts = probePng(b)
  else if (b.length >= 12 && b.slice(0, 4).toString('latin1') === 'RIFF') facts = probeWebp(b)
  else if (b.length >= 6 && b.slice(0, 3).toString('latin1') === 'GIF') facts = probeGif(b)
  else throw unsupported('image')
  const meta = {
    format: facts.format,
    width: facts.width,
    height: facts.height,
    pages: facts.pages === undefined ? 1 : facts.pages,
    depth: facts.depth === undefined ? 'uchar' : facts.depth,
    space: 'srgb',
    hasAlpha: facts.hasAlpha === undefined ? false : facts.hasAlpha,
    hasProfile: facts.exif !== undefined || facts.xmp !== undefined,
    isProgressive: facts.progressive === true,
  }
  if (facts.exif !== undefined) meta.exif = facts.exif
  if (facts.xmp !== undefined) meta.xmp = facts.xmp
  return meta
}

/** Fail-closed surface for formats with no pure-JS stand-in (WebP/PNG/TIFF/GIF). */
function encodingDisabled(method) {
  throw new SharpStubError(
    `sharp-stub: .${method}() re-encoding is unavailable on this platform; ` +
    'only JPEG sources can pass through unchanged')
}

/**
 * Pass-through "encoder" for JPEG sources.
 *
 * dsh asks sharp for a downscaled re-encode of every model-request image
 * (dsh-attachment-local `createRequestImage`). No pure-JS encoder can stand in
 * for libvips here, but the provider downsamples every request image onto its
 * own vision grid anyway, so handing back the source JPEG keeps the request
 * correct: the projection becomes a no-op and only the upload grows. The
 * caller verifies the result against the bytes (`verifyRequestImage`), so the
 * reported dimensions must be the source's — never the requested resize size.
 *
 * Non-JPEG sources cannot stand in for a JPEG and keep failing closed.
 */
function passThroughJpeg(data, meta) {
  if (meta.format !== 'jpeg') {
    throw new SharpStubError(
      `sharp-stub: cannot re-encode ${meta.format.toUpperCase()} as JPEG on this platform; ` +
      'only JPEG sources pass through unchanged')
  }
  return { data: Buffer.from(data), width: meta.width, height: meta.height }
}

function createPipeline(data, inherited) {
  // `clone()` shares the source bytes but starts from the parent's chain state
  // so the encoding ladder's `prepared.clone().jpeg(...)` keeps the resize step.
  const state = inherited === undefined ? { inspected: null, output: null } : inherited
  const ensureInspected = () => {
    if (state.inspected === null) state.inspected = inspect(data)
    return state.inspected
  }
  const withOutput = (output) => {
    state.output = output
    return pipeline
  }
  const pipeline = {
    metadata: async () => ensureInspected(),
    raw: () => ({
      toBuffer: async () => {
        const meta = ensureInspected()
        const channels = meta.hasAlpha ? 4 : 3
        return Buffer.alloc(meta.width * meta.height * channels)
      },
    }),
    rotate: () => pipeline,
    flip: () => pipeline,
    flop: () => pipeline,
    toColourspace: () => pipeline,
    resize: () => pipeline,
    clone: () => createPipeline(data, { ...state }),
    jpeg: () => withOutput('jpeg'),
    webp: () => withOutput('webp'),
    png: () => withOutput('png'),
    tiff: () => withOutput('tiff'),
    gif: () => withOutput('gif'),
    toBuffer: async (options) => {
      if (state.output === null) {
        throw new SharpStubError('sharp-stub: .toBuffer() needs an output format first (.jpeg/.png/.webp)')
      }
      if (state.output !== 'jpeg') throw encodingDisabled(state.output)
      const encoded = passThroughJpeg(data, ensureInspected())
      if (options !== undefined && options.resolveWithObject === true) {
        return {
          data: encoded.data,
          info: { width: encoded.width, height: encoded.height, format: 'jpeg', size: encoded.data.length },
        }
      }
      return encoded.data
    },
  }
  return pipeline
}

function sharpStub(data) {
  return createPipeline(data)
}
sharpStub.format = { jpeg: { input: { buffer: true } }, png: { input: { buffer: true } }, webp: { input: { buffer: true } }, gif: { input: { buffer: true } } }
sharpStub.versions = { stub: '1.0.0' }

module.exports = sharpStub
module.exports.default = sharpStub
module.exports.SharpStubError = SharpStubError
