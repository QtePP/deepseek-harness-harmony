/**
 * Display copy for attachment-bearing turns.
 *
 * `ChatMessage.note` is persisted, so historical rows already carry the old
 * literal `附件图片`. Rather than migrate stored data (and risk rewriting
 * unrelated notes such as tool names or usage digests), the label is derived
 * at render time: the legacy literal is recognised and replaced with wording
 * that reads like product copy instead of a field name.
 */

/** The literal older builds wrote into `note` for image turns. */
const LEGACY_IMAGE_NOTE = '附件图片'

/** Extensions we are willing to describe in prose. */
function isImagePath(path: string): boolean {
  const dot = path.lastIndexOf('.')
  if (dot < 0) {
    return false
  }
  const ext = path.substring(dot + 1).toLowerCase()
  return ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'webp' || ext === 'gif'
    || ext === 'heic' || ext === 'bmp'
}

/**
 * True when the turn carried images, judging from the paths rather than the
 * note — an old row may have no note at all while still holding an image.
 */
export function isImageTurn(note: string, imageCount: number): boolean {
  if (imageCount > 0) {
    return true
  }
  return note === LEGACY_IMAGE_NOTE
}

/**
 * The label above a user bubble. Returns '' for text-only turns so callers can
 * keep the existing "render nothing" behaviour.
 */
export function attachmentNote(note: string, imageCount: number): string {
  if (!isImageTurn(note, imageCount)) {
    return note
  }
  if (imageCount <= 0) {
    return '图片'
  }
  if (imageCount === 1) {
    return '随消息发送了 1 张图片'
  }
  return `随消息发送了 ${imageCount} 张图片`
}

/** Short prose for the composer strip: what is staged, and what happens next. */
export function stagedImageHint(count: number): string {
  if (count <= 0) {
    return ''
  }
  if (count === 1) {
    return '1 张图片待发送 · 将随下一条消息一起送出'
  }
  return `${count} 张图片待发送 · 将随下一条消息一起送出`
}

/** Accessibility label for one staged thumbnail, keyed by its file name. */
export function thumbnailLabel(path: string, index: number, total: number): string {
  const slash = path.lastIndexOf('/')
  const name = slash >= 0 ? path.substring(slash + 1) : path
  const kind = isImagePath(path) ? '图片' : '附件'
  return `${kind} ${index + 1}/${total}：${name}`
}
