'use strict'
/*
 * Unit tests for host/sharp-stub.cjs — run with: node --test host/sharp-stub.test.cjs
 * Builds minimal JPEG/PNG/WebP/GIF containers by hand and checks that
 * metadata()/raw() surface the facts dsh-attachment-local needs, and that
 * the encoding ladder fails closed.
 */
const test = require('node:test')
const assert = require('node:assert')
const path = require('node:path')
const sharpStub = require(path.join(__dirname, 'sharp-stub.cjs'))

// --- minimal container builders -------------------------------------------------

/** Baseline JFIF: SOI, APP0(JFIF), DQT, SOF0, DHT, SOS, one byte of entropy, EOI. */
function buildJpeg({ withExif = false, withIcc = false } = {}) {
  const parts = []
  const seg = (marker, body) => {
    const head = Buffer.from([0xff, marker, (body.length + 2) >> 8, (body.length + 2) & 0xff])
    parts.push(head, body)
  }
  parts.push(Buffer.from([0xff, 0xd8]))
  seg(0xe0, Buffer.concat([Buffer.from('JFIF\0'), Buffer.from([1, 2, 0, 0, 1, 0, 1, 0, 0])]))
  if (withExif) {
    seg(0xe1, Buffer.concat([Buffer.from('Exif\0\0'), Buffer.from([0x4d, 0x4d, 0x00, 0x2a, 0, 0, 0, 8])]))
  }
  if (withIcc) {
    // HarmonyOS ImagePacker always emits an APP2 ICC_PROFILE segment like this.
    seg(0xe2, Buffer.concat([Buffer.from('ICC_PROFILE\0'), Buffer.alloc(464)]))
  }
  seg(0xdb, Buffer.from([0x00, 0x01, 0x02, 0x03]))
  seg(0xc0, Buffer.from([0x08, 0x00, 0x64, 0x00, 0xc8, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01])) // 8-bit, 100x200, 3 components
  seg(0xc4, Buffer.from([0x00, 0x01, 0x05, 0x01]))
  seg(0xda, Buffer.from([0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00]))
  parts.push(Buffer.from([0x12, 0x34, 0xff, 0xd9]))
  return Buffer.concat(parts)
}

function buildPng({ colorType = 2, bitDepth = 8 } = {}) {
  const chunk = (type, body) => {
    const len = Buffer.alloc(4)
    len.writeUInt32BE(body.length)
    const data = Buffer.concat([Buffer.from(type), body])
    const crc = Buffer.alloc(4)
    crc.writeUInt32BE(crc32(data) >>> 0)
    return Buffer.concat([len, data, crc])
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(60, 0)
  ihdr.writeUInt32BE(30, 4)
  ihdr[8] = bitDepth
  ihdr[9] = colorType
  ihdr[10] = 0
  ihdr[11] = 0
  ihdr[12] = 0
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', Buffer.from([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

let crcTable = null
function crc32(buf) {
  if (crcTable === null) {
    crcTable = []
    for (let n = 0; n < 256; n++) {
      let c = n
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
      crcTable[n] = c >>> 0
    }
  }
  let crc = 0xffffffff
  for (const byte of buf) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8)
  return crc ^ 0xffffffff
}

function buildWebpLossy() {
  // RIFF....WEBP + VP8 (lossy) chunk with sync code and 320x240
  const vp8 = Buffer.alloc(10)
  vp8[0] = 0x30 // frame tag
  vp8[1] = 0x01
  vp8[2] = 0x00
  vp8[3] = 0x9d
  vp8[4] = 0x01
  vp8[5] = 0x2a
  vp8.writeUInt16LE(320, 6) // width
  vp8.writeUInt16LE(240, 8) // height
  const riffSize = 4 + 8 + vp8.length
  const header = Buffer.alloc(12)
  header.write('RIFF', 0, 'latin1')
  header.writeUInt32LE(riffSize, 4)
  header.write('WEBP', 8, 'latin1')
  const chunkHead = Buffer.alloc(8)
  chunkHead.write('VP8 ', 0, 'latin1')
  chunkHead.writeUInt32LE(vp8.length, 4)
  return Buffer.concat([header, chunkHead, vp8])
}

function buildGif({ frames = 1 } = {}) {
  const parts = [Buffer.from('GIF89a')]
  const lsd = Buffer.alloc(7)
  lsd.writeUInt16LE(80, 0)
  lsd.writeUInt16LE(40, 2)
  lsd[4] = 0xf0
  lsd[5] = 0
  lsd[6] = 0
  parts.push(lsd)
  for (let i = 0; i < frames; i++) {
    const img = Buffer.alloc(11)
    img[0] = 0x2c
    img.writeUInt16LE(0, 1)
    img.writeUInt16LE(0, 3)
    img.writeUInt16LE(80, 5)
    img.writeUInt16LE(40, 7)
    img[9] = 0
    img[10] = 0x02 // LZW min code size
    parts.push(img, Buffer.from([0x02, 0x44, 0x01, 0x00])) // one data sub-block + terminator
  }
  parts.push(Buffer.from([0x3b]))
  return Buffer.concat(parts)
}

// --- tests -----------------------------------------------------------------------

test('jpeg metadata exposes dimensions and stays EXIF-free for JFIF', async () => {
  const meta = await sharpStub(buildJpeg()).metadata()
  assert.equal(meta.format, 'jpeg')
  assert.equal(meta.width, 200)
  assert.equal(meta.height, 100)
  assert.equal(meta.exif, undefined)
  assert.equal(meta.hasAlpha, false)
  assert.equal(meta.depth, 'uchar')
  assert.equal(meta.space, 'srgb')
})

test('jpeg with EXIF APP1 reports exif buffer (carriesMetadata path)', async () => {
  const meta = await sharpStub(buildJpeg({ withExif: true })).metadata()
  assert.notEqual(meta.exif, undefined)
})

test('jpeg raw probe returns a correctly sized raster', async () => {
  const buf = await sharpStub(buildJpeg()).raw().toBuffer()
  assert.equal(buf.length, 200 * 100 * 3)
})

test('truncated jpeg (no EOI) is rejected', async () => {
  const whole = buildJpeg()
  const cut = whole.subarray(0, whole.length - 2)
  await assert.rejects(() => sharpStub(cut).metadata(), /corrupt|unsupported/i)
})

test('png metadata exposes dimensions, depth, and alpha', async () => {
  const opaque = await sharpStub(buildPng({ colorType: 2 })).metadata()
  assert.equal(opaque.format, 'png')
  assert.equal(opaque.width, 60)
  assert.equal(opaque.height, 30)
  assert.equal(opaque.hasAlpha, false)
  const alpha = await sharpStub(buildPng({ colorType: 6 })).metadata()
  assert.equal(alpha.hasAlpha, true)
  const sixteen = await sharpStub(buildPng({ colorType: 2, bitDepth: 16 })).metadata()
  assert.equal(sixteen.depth, 'ushort')
})

test('png missing IEND is rejected', async () => {
  const whole = buildPng()
  const cut = whole.subarray(0, whole.length - 12)
  await assert.rejects(() => sharpStub(cut).metadata(), /corrupt/i)
})

test('webp lossy metadata exposes dimensions', async () => {
  const meta = await sharpStub(buildWebpLossy()).metadata()
  assert.equal(meta.format, 'webp')
  assert.equal(meta.width, 320)
  assert.equal(meta.height, 240)
})

test('gif metadata counts frames as pages', async () => {
  const single = await sharpStub(buildGif()).metadata()
  assert.equal(single.pages, 1)
  const animated = await sharpStub(buildGif({ frames: 3 })).metadata()
  assert.equal(animated.pages, 3)
})

test('jpeg encoding passes the source through with its true dimensions', async () => {
  const source = buildJpeg()
  const encoded = await sharpStub(source).jpeg({ quality: 85 }).toBuffer({ resolveWithObject: true })
  // dsh projects request images by resizing first; the stub cannot resize, so
  // it must report the source size or verifyRequestImage rejects the result.
  const resized = await sharpStub(source)
    .rotate()
    .toColourspace('srgb')
    .resize({ height: 10, withoutEnlargement: true })
    .jpeg({ quality: 85 })
    .toBuffer({ resolveWithObject: true })
  assert.equal(resized.info.width, 200)
  assert.equal(resized.info.height, 100)
  assert.equal(resized.info.format, 'jpeg')
  assert.equal(resized.data.length, source.length)
  assert.equal(Buffer.compare(resized.data, source), 0)
  assert.equal(encoded.info.size, source.length)
})

test('jpeg toBuffer without resolveWithObject returns the bytes', async () => {
  const source = buildJpeg()
  const buf = await sharpStub(source).jpeg().toBuffer()
  assert.equal(Buffer.isBuffer(buf), true)
  assert.equal(Buffer.compare(buf, source), 0)
})

test('non-jpeg sources cannot be encoded as jpeg', async () => {
  await assert.rejects(
    () => sharpStub(buildPng()).jpeg().toBuffer({ resolveWithObject: true }),
    /cannot re-encode PNG as JPEG/)
})

test('webp and png output still fail closed', async () => {
  await assert.rejects(() => sharpStub(buildJpeg()).webp({ quality: 80 }).toBuffer(), /sharp-stub/)
  await assert.rejects(() => sharpStub(buildJpeg()).png().toBuffer(), /sharp-stub/)
})

test('toBuffer without an output format is rejected', async () => {
  await assert.rejects(() => sharpStub(buildJpeg()).toBuffer(), /needs an output format/)
})

test('clone keeps the chain state of its parent', async () => {
  const base = sharpStub(buildJpeg()).resize({ width: 10 })
  const encoded = await base.clone().jpeg({ quality: 60 }).toBuffer({ resolveWithObject: true })
  assert.equal(encoded.info.width, 200)
  assert.equal(encoded.info.height, 100)
})

test('clone returns an independent working pipeline', async () => {
  const base = sharpStub(buildJpeg())
  const copy = base.clone()
  const meta = await copy.metadata()
  assert.equal(meta.width, 200)
})

test('real picker-style jpeg round-trips through inspect unchanged', async () => {
  // The app transcodes picker photos to clean JFIF (no EXIF, 8-bit sRGB),
  // which is exactly the shape canPassThroughNormalization admits.
  const meta = await sharpStub(buildJpeg()).metadata()
  const passThrough = meta.exif === undefined && meta.xmp === undefined &&
    meta.hasProfile === false && meta.depth === 'uchar' && meta.space === 'srgb' &&
    (meta.pages ?? 1) === 1 && !meta.hasAlpha
  assert.equal(passThrough, true)
})

test('harmony packer jpeg with ICC APP2 stays pass-through', async () => {
  // HarmonyOS ImagePacker always embeds an ICC profile; the stub must not
  // surface it as retained metadata (dsh would then force the normalize path).
  const meta = await sharpStub(buildJpeg({ withIcc: true })).metadata()
  assert.equal(meta.icc, undefined)
  assert.equal(meta.hasProfile, false)
  assert.equal(meta.exif, undefined)
  assert.equal(meta.width, 200)
  assert.equal(meta.height, 100)
})
