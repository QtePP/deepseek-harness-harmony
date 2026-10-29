import { curves } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { ChatMessage, Role, ToolTrace } from '../model/ChatModel'
import { MdText, copyTextToClipboard } from './Markdown'

/** One text or code segment produced by the minimal Markdown splitter. */
export interface Segment {
  code: boolean
  text: string
}

/** A workspace file surfaced as a tappable preview chip. */
export interface FileRef {
  path: string
  name: string
}

const PREVIEW_EXTS: string[] = [
  'html', 'htm', 'svg', 'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp',
  'md', 'txt', 'json', 'csv'
]

function isPreviewExt(ext: string): boolean {
  for (const item of PREVIEW_EXTS) {
    if (item === ext) {
      return true
    }
  }
  return false
}

function basenameOf(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash >= 0 ? path.substring(slash + 1) : path
}

/**
 * Existence probe for the riskier reference sources: resolve the path the
 * same way a tap would, then stat it. Cheap (a handful of `accessSync`s) and
 * only invoked for space-heuristic candidates, never on every render frame.
 */
function makeExists(resolver: (ref: FileRef) => string): (path: string) => boolean {
  return (path: string): boolean => {
    const ref: FileRef = { path: path, name: basenameOf(path) }
    const resolved = resolver(ref)
    if (resolved.length === 0) {
      return false
    }
    try {
      return fs.accessSync(resolved)
    } catch (error) {
      return false
    }
  }
}

/** Letter ranges (CJK, kana, hangul, latin-extended, greek, cyrillic) for path runs. */
const UNICODE_LETTERS = '\\u00C0-\\u024F\\u0370-\\u03FF\\u0400-\\u04FF' +
  '\\u3040-\\u30FF\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uAC00-\\uD7AF'

/** Trailing prose/bracket punctuation that may cling to a quoted path. */
const TRAILING_JUNK = '.,;:!?、。，；：！？）》」』】>〉'

function stripTrailingJunk(path: string): string {
  let end = path.length
  while (end > 0 && TRAILING_JUNK.indexOf(path.charAt(end - 1)) >= 0) {
    end--
  }
  return path.substring(0, end)
}

function looksLikeUrl(path: string): boolean {
  return /^[A-Za-z][A-Za-z0-9+.-]*:/.test(path)
}

/** Best-effort percent-decode; the raw path survives when decoding fails. */
function decodePath(path: string): string {
  if (!path.includes('%')) {
    return path
  }
  try {
    const decoded = decodeURIComponent(path)
    return decoded.length > 0 ? decoded : path
  } catch (error) {
    return path
  }
}

/**
 * Extract previewable file references from message text.
 *
 * Four sources, most-trustworthy first, all de-duplicated and capped:
 *   1. markdown link targets `](path)` — delimited, so spaces and Chinese
 *      path components are captured verbatim;
 *   2. backtick-quoted spans — the model quotes exact paths (and tool
 *      arguments hold them as `"file_path": "…"`), quoted text may contain
 *      spaces (`fitness plan.MD`);
 *   3. bare runs with an extension — the classic tokenizer, widened with
 *      unicode letters so `/…/饮食/本周饮食计划.html` embedded in Chinese
 *      prose without separators is found; `file://` prefixes drop, URL
 *      fragments (`https://host/a.html`) are skipped;
 *   4. two Latin-token names ending in an extension — filenames with one
 *      space mentioned in bare prose (`fitness plan.MD`). The riskiest
 *      source, so it only fires when `exists` confirms the file.
 *
 * A space-containing candidate supersedes an already-listed bare suffix
 * (`fitness plan.MD` replaces an earlier `plan.MD`) and is skipped when a
 * longer form is already listed.
 */
export function refsFromText(text: string, limit: number = 4,
  exists?: (path: string) => boolean): FileRef[] {
  const out: FileRef[] = []
  const seen = new Set<string>()
  const push = (candidate: string, needsProbe: boolean): void => {
    let path = candidate.trim()
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length)
    }
    path = stripTrailingJunk(path)
    while (path.startsWith('//')) {
      path = path.substring(1)
    }
    if (path.length === 0 || looksLikeUrl(path) || path.startsWith('#')) {
      return
    }
    const slash = path.lastIndexOf('/')
    const dot = path.lastIndexOf('.')
    if (dot <= slash + 1 || dot === path.length - 1) {
      return
    }
    const ext = path.substring(dot + 1).toLowerCase()
    if (!isPreviewExt(ext)) {
      return
    }
    path = decodePath(path)
    if (seen.has(path)) {
      return
    }
    // A listed space form already covers this bare suffix (`plan.MD` after
    // `fitness plan.MD`); likewise a longer form covers a shorter suffix.
    for (const item of out) {
      if (item.path.endsWith(` ${path}`)) {
        return
      }
    }
    // The space heuristic must prove the file exists before it may
    // supersede anything — a rejected candidate leaves the list untouched.
    if (needsProbe && (exists === undefined || !exists(path))) {
      return
    }
    if (path.includes(' ')) {
      for (let index = out.length - 1; index >= 0; index--) {
        const listed = out[index].path
        if (path.endsWith(` ${listed}`)) {
          out.splice(index, 1)
          seen.delete(listed)
        }
      }
    }
    if (out.length >= limit) {
      return
    }
    seen.add(path)
    out.push({ path: path, name: basenameOf(path) })
  }

  const sources: RegExp[] = [
    /\]\(([^)\n]+)\)/g,
    /`([^`\n]+)`/g,
    new RegExp(`[A-Za-z0-9_\\-./~@${UNICODE_LETTERS}]+\\.[A-Za-z]{1,6}`, 'g'),
    new RegExp(`[A-Za-z0-9][A-Za-z0-9_\\-]* [A-Za-z0-9_\\-.]+\\.[A-Za-z]{1,6}(?![A-Za-z])`, 'g')
  ]
  /** Sources 0-1 capture a delimited path in group 1; sources 2-3 match bare. */
  const quoted: boolean[] = [true, true, false, false]
  /** Only source 3 (the space heuristic) requires an existence probe. */
  const probes: boolean[] = [false, false, false, true]
  const cleaned = text.split('file://').join('')
  for (let source = 0; source < sources.length; source++) {
    const pattern = sources[source]
    let match = pattern.exec(cleaned)
    while (match !== null) {
      if (quoted[source]) {
        push(match[1], probes[source])
      } else {
        const before = match.index > 0 ? cleaned.charAt(match.index - 1) : ''
        // ':' marks a URL scheme (`https://…`); '%' a mid-percent-escape
        // fragment of an already-captured encoded path.
        if (before !== ':' && before !== '%') {
          push(match[0], probes[source])
        }
      }
      if (out.length >= limit) {
        return out
      }
      match = pattern.exec(cleaned)
    }
  }
  return out
}

/** Split fenced code blocks out of a message; everything else renders as prose. */
export function segmentsOf(text: string): Segment[] {
  const out: Segment[] = []
  const parts = text.split('```')
  for (let index = 0; index < parts.length; index++) {
    const body = parts[index]
    if (body.length === 0) {
      continue
    }
    if (index % 2 === 1) {
      // A fence may open with a language tag on its first line.
      const newline = body.indexOf('\n')
      const code = newline >= 0 ? body.substring(newline + 1) : body
      out.push({ code: true, text: code })
    } else {
      out.push({ code: false, text: body })
    }
  }
  return out
}

/** A resolved artifact surfaced in the dock below the transcript. */
export interface ArtifactItem {
  path: string
  name: string
  /** Absolute sandbox path the reference resolved to. */
  resolved: string
  /** Whether the file exists right now. */
  exists: boolean
}

/** Extensions the dock can render live in its embedded Web pane. */
function isWebExt(path: string): boolean {
  const name = path.substring(path.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  if (dot <= 0) {
    return false
  }
  const ext = name.substring(dot + 1).toLowerCase()
  return ext === 'html' || ext === 'htm' || ext === 'svg'
}

/**
 * The artifact dock under the transcript: everything this conversation
 * produced or referenced, as a horizontally scrollable strip. Tapping a card
 * expands it into an embedded Web pane (or image/text pane) that scrolls
 * internally; 全屏 hands the same file to the full-screen viewer.
 *
 * This is the phone analogue of the desktop session's file panel — the
 * transcript itself stays text, and previews live in one predictable place
 * at the bottom instead of being duplicated inline after every message.
 */
@Component
export struct ArtifactDock {
  @Prop items: ArtifactItem[] = []
  @State expandedPath: string = ''
  /** Whole-dock collapse; the default is the compressed header-only strip. */
  @State collapsed: boolean = false
  onOpenFull: (item: ArtifactItem) => void = () => {}
  private controller: webview.WebviewController = new webview.WebviewController()

  private current(): ArtifactItem | null {
    for (const item of this.items) {
      if (item.path === this.expandedPath) {
        return item
      }
    }
    return null
  }

  private expandedExists(): boolean {
    const item = this.current()
    return item === null ? false : item.exists
  }

  /** '' when nothing is expanded; otherwise the pane kind to render. */
  private expandedKind(): string {
    const item = this.current()
    if (item === null) {
      return ''
    }
    if (isWebExt(item.path)) {
      return 'web'
    }
    return this.isImage(item.path) ? 'image' : 'other'
  }

  private expandedSrc(): string {
    const item = this.current()
    return item === null ? '' : `file://${item.resolved}`
  }

  private toggle(item: ArtifactItem): void {
    if (this.expandedPath === item.path) {
      this.expandedPath = ''
      return
    }
    this.expandedPath = item.path
  }

  private refresh(): void {
    try {
      this.controller.refresh()
    } catch (error) {
      // Web not mounted yet; expanding mounts it with fresh content.
    }
  }

  @Builder
  card(item: ArtifactItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(isWebExt(item.path) ? '◍' : '▤')
          .fontSize(11)
          .fontColor(item.exists ? $r('app.color.brand') : $r('app.color.text_tertiary'))
        Text(item.name)
          .fontSize(11)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .fontColor(item.exists ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
      }
      .width('100%')

      Text(item.exists ? '点击预览' : '文件未找到')
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width(150)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.expandedPath === item.path ?
      $r('app.color.surface_muted') : $r('app.color.surface'))
    .borderRadius(10)
    .borderWidth(1)
    .borderColor(this.expandedPath === item.path ? $r('app.color.brand') : $r('app.color.divider'))
    .onClick(() => this.toggle(item))
  }

  build() {
    if (this.items.length > 0) {
      Column({ space: 8 }) {
        Row() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(13)
              .fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.collapsed ? -90 : 0 })
              .animation({ curve: curves.springMotion(0.35, 0.85) })
            Text(`产物 · ${this.items.length}`)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
              this.collapsed = !this.collapsed
            })
          })

          if (this.current() !== null) {
            Text('刷新')
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => this.refresh())
            Text('全屏')
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => {
                const item = this.current()
                if (item !== null) {
                  this.onOpenFull(item)
                }
              })
            Text('收起预览')
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => {
                this.expandedPath = ''
              })
          }
        }
        .width('100%')

        if (!this.collapsed) {
          Column({ space: 8 }) {
            if (this.items.length === 1) {
              // 单产物：直接靠左渲染，不进横向滚动容器。
              this.card(this.items[0])
            } else {
              Scroll() {
                Row({ space: 8 }) {
                  ForEach(this.items, (item: ArtifactItem) => {
                    this.card(item)
                  }, (item: ArtifactItem) => `${item.path}.${item.exists}`)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
            }

            if (this.current() !== null) {
              if (!this.expandedExists()) {
                Text('该文件当前不在应用沙箱内：可能在别的项目工作区，或已被清理。')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              } else if (this.expandedKind() === 'web') {
                Web({ src: this.expandedSrc(), controller: this.controller })
                  .fileAccess(true)
                  .domStorageAccess(true)
                  .width('100%')
                  .height(320)
                  .borderRadius(12)
                  .backgroundColor($r('app.color.surface'))
              } else if (this.expandedKind() === 'image') {
                Scroll() {
                  Image(this.expandedSrc())
                    .objectFit(ImageFit.Contain)
                    .width('100%')
                }
                .width('100%')
                .height(320)
                .borderRadius(12)
                .backgroundColor($r('app.color.surface'))
              } else {
                Text('该类型请在「全屏」中查看。')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: -6 }))
            .animation({ duration: 220, curve: Curve.EaseOut }))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.background'))
    }
  }

  private isImage(path: string): boolean {
    const name = path.substring(path.lastIndexOf('/') + 1)
    const dot = name.lastIndexOf('.')
    if (dot <= 0) {
      return false
    }
    const ext = name.substring(dot + 1).toLowerCase()
    return ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'webp' ||
      ext === 'gif' || ext === 'bmp'
  }
}

/** One slice of the merged thinking+trace timeline: a thought run or a tool call. */
interface ThinkPart {
  kind: string
  text: string
  entry: ToolTrace | null
  /** 1-based ordinal within the current consecutive tool run (activity-bar shade); a thought run resets it; 0 for thought runs. */
  toolIndex: number
}

/** One command step of the run timeline: status dot, name, duration, detail. */
@Component
struct TraceEntryRow {
  @ObjectLink entry: ToolTrace
  /** Entry detail (arguments + result) is one tap behind the row. */
  @State expanded: boolean = false

  private summary(): string {
    const lines = this.entry.input.split('\n')
    for (const line of lines) {
      const flat = line.trim()
      if (flat.length > 0) {
        return flat
      }
    }
    return ''
  }

  /** Elapsed time between call start and settle; '' while still running. */
  private durationLabel(): string {
    if (this.entry.doneAt <= 0) {
      return ''
    }
    const seconds = Math.max(0, this.entry.doneAt - this.entry.at) / 1000
    if (seconds < 60) {
      return `${seconds.toFixed(1)}s`
    }
    const minutes = Math.floor(seconds / 60)
    return `${minutes}m${Math.round(seconds - minutes * 60)}s`
  }

  private dotColor(): ResourceColor {
    if (this.entry.status === 'failed') {
      return $r('app.color.status_danger')
    }
    if (this.entry.status === 'in_progress') {
      return $r('app.color.brand')
    }
    return $r('app.color.status_success')
  }

  build() {
    Row({ space: 0 }) {
      Column() {
        Column()
          .height(7)
          .width(2)
          .backgroundColor($r('app.color.divider'))
        Circle({ width: 10, height: 10 })
          .fill(Color.White)
          .stroke(this.dotColor())
          .strokeWidth(2.5)
        Column()
          .layoutWeight(1)
          .width(2)
          .backgroundColor($r('app.color.divider'))
      }
      .width(14)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(this.entry.name)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.entry.status === 'failed' ?
              $r('app.color.status_danger') : $r('app.color.text_primary'))

          if (this.entry.status === 'failed') {
            Text('失败')
              .fontSize(10)
              .fontColor($r('app.color.status_danger'))
          }
          if (this.durationLabel().length > 0) {
            Text(this.durationLabel())
              .fontSize(10)
              .fontFamily('monospace')
              .fontColor($r('app.color.text_tertiary'))
          } else if (this.entry.status === 'in_progress') {
            LoadingProgress()
              .width(12)
              .height(12)
              .color($r('app.color.brand'))
          }

          if (!this.expanded && this.summary().length > 0) {
            Text(this.summary())
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }

          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(11)
            .fontColor([$r('app.color.text_tertiary')])
            .rotate({ angle: this.expanded ? 0 : -90 })
            .animation({ curve: curves.springMotion(0.35, 0.85) })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.expanded) {
          if (this.entry.input.length > 0) {
            Scroll() {
              Text(this.entry.input)
                .fontSize(12)
                .fontFamily('monospace')
                .lineHeight(18)
                .fontColor($r('app.color.text_primary'))
                .wordBreak(WordBreak.BREAK_ALL)
                .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 220 })
            .scrollBar(BarState.Auto)
            .padding(8)
            .backgroundColor($r('app.color.code_background'))
            .borderRadius(8)
          }
          if (this.entry.output.length > 0) {
            Scroll() {
              Text(this.entry.output)
                .fontSize(12)
                .fontFamily('monospace')
                .lineHeight(18)
                .fontColor($r('app.color.text_secondary'))
                .wordBreak(WordBreak.BREAK_ALL)
                .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 220 })
            .scrollBar(BarState.Auto)
            .padding(8)
            .backgroundColor($r('app.color.surface_muted'))
            .borderRadius(8)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8, top: 5, bottom: 5 })
    }
    .width('100%')
    .onClick(() => {
      this.expanded = !this.expanded
    })
  }
}

@Component
export struct MessageItem {
  @ObjectLink message: ChatMessage
  /** True only while this message is the live turn the runtime is working on. */
  @Prop running: boolean = false
  /** Tool calls render collapsed by default; tapping the row expands the full payload. */
  @State toolExpanded: boolean = false
  /** Thinking renders collapsed by default; it is long and secondary. */
  @State reasoningExpanded: boolean = false
  /** Thought segments the user opened inside the 轨迹 drawer (by part index). */
  @State expandedThoughts: Set<number> = new Set<number>()
  /** Timeline viewport: fade edges appear only where content overflows the box. */
  @State timelineOverflow: boolean = false
  @State timelineAtTop: boolean = true
  @State timelineAtEnd: boolean = false
  private timelineContentHeight: number = 0
  private timelineViewportHeight: number = 0
  onOpenFile: (ref: FileRef) => void = () => {}
  onResolveFile: (ref: FileRef) => string = () => ''
  private previewController: webview.WebviewController = new webview.WebviewController()

  /** Memoized on the message text: streaming re-renders rescan once per chunk. */
  private refsCache: FileRef[] = []
  private refsKey: string = ''

  private refs(): FileRef[] {
    if (this.refsKey !== this.message.text) {
      this.refsCache = refsFromText(this.message.text, 4, makeExists(this.onResolveFile))
      this.refsKey = this.message.text
    }
    return this.refsCache
  }

  /**
   * The one existing html/svg artifact this reply references, else an empty
   * item. Drives the proactive inline preview: a single produced document
   * renders live in the conversation (assistant side, left-aligned) instead
   * of waiting for a tap on the dock. Two or more candidates stay dock-only
   * so the bubble is never crowded. Memoized on the message text: build
   * calls it twice and streaming re-renders every chunk.
   */
  private webArtifactCache: ArtifactItem = { path: '', name: '', resolved: '', exists: false }
  private webArtifactKey: string = ''

  private webArtifactOrEmpty(): ArtifactItem {
    if (this.webArtifactKey !== this.message.text) {
      this.webArtifactCache = this.scanWebArtifact()
      this.webArtifactKey = this.message.text
    }
    return this.webArtifactCache
  }

  private scanWebArtifact(): ArtifactItem {
    const empty: ArtifactItem = { path: '', name: '', resolved: '', exists: false }
    if (this.message.role !== Role.ASSISTANT) {
      return empty
    }
    const text = this.message.text
    if (text.indexOf('.htm') < 0 && text.indexOf('.svg') < 0) {
      return empty
    }
    let found: ArtifactItem | null = null
    for (const ref of this.refs()) {
      if (!isWebExt(ref.path)) {
        continue
      }
      const resolved = this.onResolveFile(ref)
      if (resolved.length === 0) {
        continue
      }
      let exists = false
      try {
        exists = fs.accessSync(resolved)
      } catch (error) {
        exists = false
      }
      if (!exists) {
        continue
      }
      if (found !== null) {
        return empty
      }
      found = { path: ref.path, name: ref.name, resolved: resolved, exists: true }
    }
    return found === null ? empty : found
  }

  @Builder
  inlineArtifactPreview(item: ArtifactItem) {
    if (item.path.length > 0) {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(item.name)
            .fontSize(11)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .fontColor($r('app.color.text_secondary'))
          Text('全屏')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.surface_muted'))
            .borderRadius(8)
            .onClick(() => {
              const ref: FileRef = { path: item.path, name: item.name }
              this.onOpenFile(ref)
            })
        }
        .width('100%')

        Web({ src: `file://${item.resolved}`, controller: this.previewController })
          .fileAccess(true)
          .domStorageAccess(true)
          .width('100%')
          .height(300)
          .borderRadius(12)
          .backgroundColor($r('app.color.surface'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  private hasBubble(): boolean {
    return this.message.role === Role.USER
  }

  private bubblePadding(): Padding {
    if (this.hasBubble()) {
      return { left: 14, right: 14, top: 10, bottom: 10 }
    }
    return { left: 0, right: 0, top: 0, bottom: 0 }
  }

  private bubbleAlign(): HorizontalAlign {
    return this.message.role === Role.USER ? HorizontalAlign.End : HorizontalAlign.Start
  }

  private toolLabel(): string {
    return this.message.note.length > 0 ? this.message.note : '工具调用'
  }

  /** First readable line of the tool arguments, for the collapsed row. */
  private toolSummary(): string {
    const lines = this.message.toolInput.split('\n')
    for (const line of lines) {
      const flat = line.trim()
      if (flat.length > 0) {
        return flat
      }
    }
    return ''
  }

  private toolStatusLabel(): string {
    if (this.message.toolStatus === 'in_progress') {
      return '执行中'
    }
    if (this.message.toolStatus === 'failed') {
      return '失败'
    }
    if (this.message.toolStatus === 'completed') {
      return '完成'
    }
    return ''
  }

  private toolStatusColor(): ResourceColor {
    if (this.message.toolStatus === 'failed') {
      return '#C0392B'
    }
    return this.message.toolStatus === 'in_progress' ?
      $r('app.color.brand') : $r('app.color.text_tertiary')
  }

  /** Deepening blue ramp for consecutive tool calls (a thought run restarts it); clamps at the deepest shade. */
  private toolShade(ordinal: number): string {
    const shades: string[] = ['#8FA4FF', '#6E87FD', '#4D6BFE', '#3A55D9', '#2B40A8', '#1F2F7A']
    return shades[Math.min(Math.max(ordinal, 1), shades.length) - 1]
  }

  /** Leading digit run of a usage note number; -1 when there is none. */
  private parseCount(text: string): number {
    let value = 0
    let seen = false
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i)
      if (code >= 48 && code <= 57) {
        seen = true
        value = value * 10 + (code - 48)
      } else {
        break
      }
    }
    return seen ? value : -1
  }

  /** Context occupancy parsed from the usage note (「上下文 used/size」); 0 when unknown. */
  private contextRatio(): number {
    const prefix = '上下文 '
    if (!this.message.note.startsWith(prefix)) {
      return 0
    }
    const rest = this.message.note.substring(prefix.length)
    const slash = rest.indexOf('/')
    if (slash <= 0) {
      return 0
    }
    const used = this.parseCount(rest.substring(0, slash))
    const size = this.parseCount(rest.substring(slash + 1))
    if (used < 0 || size <= 0) {
      return 0
    }
    return Math.min(1, Math.max(0, used / size))
  }

  private hex2(value: number): string {
    const digits = '0123456789ABCDEF'
    return digits.charAt((value >> 4) & 0xF) + digits.charAt(value & 0xF)
  }

  /** Thought tint: light mint at low context occupancy, deepening toward forest green as the window fills. */
  private thoughtColor(): string {
    const ratio = this.contextRatio()
    const r = Math.round(111 + (30 - 111) * ratio)
    const g = Math.round(207 + (132 - 207) * ratio)
    const b = Math.round(151 + (73 - 151) * ratio)
    return `#${this.hex2(r)}${this.hex2(g)}${this.hex2(b)}`
  }

  /** Color of one activity-bar segment: tool calls deepen call by call, thought runs carry context pressure. */
  private segmentColor(part: ThinkPart): ResourceColor {
    if (part.kind === 'tool' && part.entry !== null) {
      return part.entry.status === 'failed' ?
        $r('app.color.status_danger') : this.toolShade(part.toolIndex)
    }
    return this.thoughtColor()
  }

  /** Fade masks track measured heights: only an overflowing viewport gets edges. */
  private recomputeTimelineOverflow(): void {
    this.timelineOverflow = this.timelineViewportHeight > 0 &&
      this.timelineContentHeight > this.timelineViewportHeight + 1
  }

  /** Width of the whole activity bar: hugging the segments, capped so long runs stay compact. */
  private barWidth(): number {
    const count = this.thinkParts().length
    if (count <= 0) {
      return 0
    }
    return Math.min(200, count * 6 + (count - 1) * 3)
  }

  /** Single-line preview of a thought run: the first non-empty line. */
  private firstLineOf(text: string): string {
    const lines = text.split('\n')
    for (const line of lines) {
      const flat = line.trim()
      if (flat.length > 0) {
        return flat
      }
    }
    return ''
  }

  /**
   * Interleave the thinking stream with the tool calls: every trace entry
   * carries the reasoning length at attach time, so slicing at those offsets
   * rebuilds the chronology — thought run, call, thought run, call… Legacy
   * rows without offsets (reasonOffset -1) render their calls after the text.
   */
  private thinkParts(): ThinkPart[] {
    const reasoning = this.message.reasoning
    const out: ThinkPart[] = []
    let cursor = 0
    let toolCount = 0
    for (const entry of this.message.trace) {
      const raw = entry.reasonOffset < 0 ? reasoning.length : entry.reasonOffset
      const at = Math.min(Math.max(raw, cursor), reasoning.length)
      if (at > cursor) {
        out.push({ kind: 'text', text: reasoning.substring(cursor, at), entry: null, toolIndex: 0 })
        toolCount = 0
      }
      toolCount++
      out.push({ kind: 'tool', text: '', entry: entry, toolIndex: toolCount })
      cursor = at
    }
    if (cursor < reasoning.length) {
      out.push({ kind: 'text', text: reasoning.substring(cursor), entry: null, toolIndex: 0 })
    }
    return out
  }

  /**
   * The run timeline: a summary strip whose activity bar shows the shape of
   * the whole turn at a glance — one segment per thought run or command —
   * expanding into a rail timeline that interleaves thinking previews with
   * command rows in the order they actually happened.
   */
  @Builder
  traceBlock() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Row({ space: 3 }) {
          ForEach(this.thinkParts(), (part: ThinkPart, index: number) => {
            Column()
              .height(14)
              .layoutWeight(1)
              .constraintSize({ maxWidth: 6 })
              .borderRadius(2)
              .backgroundColor(this.segmentColor(part))
          }, (part: ThinkPart, index: number) =>
            `${index}.${part.kind}.${part.text.length}.${part.entry === null ? '' : part.entry.status}.${this.message.note}`)
        }
        .width(this.barWidth())
        .height(14)
        .alignItems(VerticalAlign.Center)

        if (this.running) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.brand'))
        }

        Text(`${this.thinkParts().length} 步`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))

        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.reasoningExpanded ? 0 : -90 })
          .animation({ curve: curves.springMotion(0.35, 0.85) })
      }
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minWidth: 132, maxWidth: '100%' })
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.surface_muted'))
      .borderRadius(12)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
          this.reasoningExpanded = !this.reasoningExpanded
          if (!this.reasoningExpanded) {
            this.expandedThoughts.clear()
          }
        })
      })

      if (this.reasoningExpanded) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Stack({ alignContent: Alignment.TopStart }) {
            Scroll() {
              Column() {
                ForEach(this.thinkParts(), (part: ThinkPart, index: number) => {
                  if (part.kind === 'tool' && part.entry !== null) {
                    TraceEntryRow({ entry: part.entry })
                  } else if (part.text.length > 0) {
                    this.thoughtStep(index, part.text)
                  }
                }, (part: ThinkPart, index: number) =>
                  `${index}.${part.kind}.${part.text.length}.${this.expandedThoughts.has(index) ? 1 : 0}`)
              }
              .width('100%')
              .onAreaChange((oldArea: Area, newArea: Area) => {
                const raw = newArea.height
                this.timelineContentHeight = typeof raw === 'number' ? raw : 0
                this.recomputeTimelineOverflow()
              })
            }
            .width('100%')
            .constraintSize({ maxHeight: 280 })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .onAreaChange((oldArea: Area, newArea: Area) => {
              const raw = newArea.height
              this.timelineViewportHeight = typeof raw === 'number' ? raw : 0
              this.recomputeTimelineOverflow()
            })
            .onScroll((xOffset: number, yOffset: number) => {
              if (yOffset > 0) {
                this.timelineAtTop = false
              } else if (yOffset < 0) {
                this.timelineAtEnd = false
              }
            })
            .onScrollEdge((side: Edge) => {
              if (side === Edge.Top) {
                this.timelineAtTop = true
              } else if (side === Edge.Bottom) {
                this.timelineAtEnd = true
              }
            })

            if (this.timelineOverflow && !this.timelineAtTop) {
              Column()
                .width('100%')
                .height(14)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.background'), 0], ['rgba(255,255,255,0)', 1]]
                })
            }
          }

          if (this.timelineOverflow && !this.timelineAtEnd) {
            Column()
              .width('100%')
              .height(14)
              .linearGradient({
                angle: 180,
                colors: [['rgba(255,255,255,0)', 0], [$r('app.color.background'), 1]]
              })
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.background'))
        .borderRadius(12)
        .clip(true)
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -8 }))
          .animation({ duration: 220, curve: Curve.EaseOut }))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** One thought run on the rail: a preview line that expands to the full text. */
  @Builder
  thoughtStep(index: number, text: string) {
    Row({ space: 0 }) {
      Column() {
        Column()
          .height(7)
          .width(2)
          .backgroundColor($r('app.color.divider'))
        Circle({ width: 8, height: 8 })
          .fill(Color.White)
          .stroke(this.thoughtColor())
          .strokeWidth(2)
        Column()
          .layoutWeight(1)
          .width(2)
          .backgroundColor($r('app.color.divider'))
      }
      .width(14)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 4 }) {
        Text('思考')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_tertiary'))

        if (this.expandedThoughts.has(index)) {
          Text(text)
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
            .wordBreak(WordBreak.BREAK_ALL)
            .width('100%')
        } else {
          Text(this.firstLineOf(text).length > 0 ? this.firstLineOf(text) : '…')
            .fontSize(12)
            .lineHeight(17)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8, top: 5, bottom: 5 })
    }
    .width('100%')
    .onClick(() => {
      if (this.expandedThoughts.has(index)) {
        this.expandedThoughts.delete(index)
      } else {
        this.expandedThoughts.add(index)
      }
    })
  }

  /** One tool call: name + argument digest collapsed, full input/result expanded. */
  @Builder
  toolRow() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.toolExpanded ? 0 : -90 })
          .animation({ curve: curves.springMotion(0.35, 0.85) })
        Text(this.toolLabel())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        if (this.toolStatusLabel().length > 0) {
          Text(this.toolStatusLabel())
            .fontSize(10)
            .fontColor(this.toolStatusColor())
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(6)
        }
        if (!this.toolExpanded && this.toolSummary().length > 0) {
          Text(this.toolSummary())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
      }
      .width('100%')

      if (this.toolExpanded) {
        if (this.message.toolInput.length > 0) {
          Scroll() {
            Text(this.message.toolInput)
              .fontSize(12)
              .fontFamily('monospace')
              .lineHeight(18)
              .fontColor($r('app.color.text_primary'))
              .wordBreak(WordBreak.BREAK_ALL)
              .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 220 })
          .scrollBar(BarState.Auto)
          .padding(8)
          .backgroundColor($r('app.color.code_background'))
          .borderRadius(8)
        }
        if (this.message.toolOutput.length > 0) {
          Scroll() {
            Text(this.message.toolOutput)
              .fontSize(12)
              .fontFamily('monospace')
              .lineHeight(18)
              .fontColor($r('app.color.text_secondary'))
              .wordBreak(WordBreak.BREAK_ALL)
              .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 220 })
          .scrollBar(BarState.Auto)
          .padding(8)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(8)
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.surface_muted'))
    .borderRadius(10)
    .onClick(() => {
      this.toolExpanded = !this.toolExpanded
    })
  }

  /** Long-press a bubble to copy the full raw message text onto the clipboard. */
  private copyMessage(): void {
    copyTextToClipboard(this.message.text)
      .then(() => {
        this.getUIContext().getPromptAction().showToast({ message: '已复制全文', duration: 1500 })
      })
      .catch((error: BusinessError) => {
        this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1500 })
      })
  }

  build() {
    Column({ space: 6 }) {
      if (this.message.role === Role.TOOL) {
        this.toolRow()
      } else {
        if (this.message.note.length > 0) {
          Text(this.message.note)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        if (this.message.images.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.message.images, (path: string) => {
              Image(`file://${path}`)
                .width(140)
                .height(105)
                .objectFit(ImageFit.Cover)
                .borderRadius(12)
                .margin(4)
            }, (path: string) => path)
          }
          .width('100%')
        } else if (this.message.image.length > 0) {
          Image(`file://${this.message.image}`)
            .width(200)
            .height(150)
            .objectFit(ImageFit.Cover)
            .borderRadius(14)
        }

        if (this.message.reasoning.length > 0 || this.message.trace.length > 0) {
          this.traceBlock()
        }

        if (this.message.text.length > 0) {
          Column({ space: 8 }) {
            if (this.message.role === Role.ASSISTANT) {
              MdText({ raw: this.message.text })
            } else {
              ForEach(segmentsOf(this.message.text), (segment: Segment) => {
                if (segment.code) {
                  Text(segment.text)
                    .fontSize(13)
                    .fontFamily('monospace')
                    .fontColor($r('app.color.text_primary'))
                    .wordBreak(WordBreak.BREAK_ALL)
                    .padding(10)
                    .backgroundColor($r('app.color.code_background'))
                    .borderRadius(8)
                } else {
                  Text(segment.text)
                    .fontSize(15)
                    .lineHeight(22)
                    .fontColor($r('app.color.text_primary'))
                    .wordBreak(WordBreak.BREAK_ALL)
                }
              }, (segment: Segment, index: number) => `${index}.${segment.code}.${segment.text.length}`)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .padding(this.bubblePadding())
          .backgroundColor(this.hasBubble() ? $r('app.color.bubble_user') : Color.Transparent)
          .borderRadius(this.hasBubble() ? 16 : 0)
          .constraintSize({ maxWidth: '92%' })
          .gesture(LongPressGesture().onAction(() => this.copyMessage()))
        }

        if (this.refs().length > 0) {
          Column({ space: 6 }) {
            ForEach(this.refs(), (ref: FileRef) => {
              Text(`◍ ${ref.name}`)
                .fontSize(11)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 180 })
                .fontColor($r('app.color.brand'))
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor($r('app.color.surface_muted'))
                .borderRadius(8)
                .onClick(() => this.onOpenFile(ref))
            }, (ref: FileRef) => ref.path)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        if (this.webArtifactOrEmpty().path.length > 0) {
          this.inlineArtifactPreview(this.webArtifactOrEmpty())
        }
      }
    }
    .width('100%')
    .alignItems(this.bubbleAlign())
    .margin({ bottom: 12 })
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: 14 }))
        .animation({ duration: 260, curve: Curve.EaseOut }),
      TransitionEffect.OPACITY.animation({ duration: 120 })
    ))
  }
}

/** Conversation pane: transcript plus composer. */
@Component
export struct ChatView {
  @Link @Watch('onCountChange') messages: ChatMessage[]
  @Prop @Watch('onRunningChange') running: boolean = false
  /** Dock contents, recomputed when the transcript settles (not per frame). */
  @State artifacts: ArtifactItem[] = []
  @Prop title: string = '新会话'
  @Prop projectName: string = ''
  @Prop showModelPicker: boolean = false
  @Prop modelLabel: string = ''
  @Prop canStop: boolean = false
  @State draft: string = ''
  @State titleExpanded: boolean = false
  @State titlePressed: boolean = false
  /** Composer polish: focus ring and pressed send/image feedback. */
  @State composerFocused: boolean = false
  @State sendPressed: boolean = false
  @State imagePressed: boolean = false
  @State modelPressed: boolean = false
  /** Typing indicator: index of the dot currently at the top of its breath. */
  @State typingDot: number = 0
  private typingTimer: number = -1
  /** Share prefill pushed by the shell; absorbed into the draft once. */
  @Prop @Watch('onShareText') shareText: string = ''
  @Prop attachPaths: string[] = []
  /** Phones have no rail: show a top-bar entry that opens the sessions sheet. */
  showSessionsEntry: boolean = false
  onSend: (text: string, attachPaths: string[]) => void = () => {}
  onNewSession: () => void = () => {}
  onOpenSettings: () => void = () => {}
  onOpenSessions: () => void = () => {}
  /** Opens the project files browser (workspace tree sheet). */
  onOpenFiles: () => void = () => {}
  onOpenFile: (ref: FileRef) => void = () => {}
  onResolveFile: (ref: FileRef) => string = () => ''
  onPickModel: () => void = () => {}
  onStop: () => void = () => {}
  onShareTextConsumed: () => void = () => {}
  onRemoveAttachment: () => void = () => {}
  onPickImage: () => void = () => {}
  private scroller: Scroller = new Scroller()

  /** Circular icon button carrying one of the hand-drawn SVG logos. */
  @Builder
  topIcon(resource: Resource, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Image(resource)
        .width(18)
        .height(18)
        .fillColor($r('app.color.text_primary'))
    }
    .width(34)
    .height(34)
    .borderRadius(17)
    .backgroundColor($r('app.color.surface_muted'))
    .onClick(() => action())
  }

  aboutToAppear(): void {
    this.refreshArtifacts()
    this.syncTypingTimer()
  }

  aboutToDisappear(): void {
    if (this.typingTimer >= 0) {
      clearInterval(this.typingTimer)
      this.typingTimer = -1
    }
  }

  /** Start the breathing dots only while a turn is running, and stop on idle. */
  private syncTypingTimer(): void {
    if (this.running && this.typingTimer < 0) {
      this.typingTimer = setInterval(() => {
        this.typingDot = (this.typingDot + 1) % 3
      }, 320)
    } else if (!this.running && this.typingTimer >= 0) {
      clearInterval(this.typingTimer)
      this.typingTimer = -1
      this.typingDot = 0
    }
  }

  /** One dot of the typing indicator; the active dot lifts and darkens. */
  @Builder
  typingDotAt(index: number) {
    Circle({ width: 6, height: 6 })
      .fill(this.typingDot === index ? $r('app.color.brand') : $r('app.color.text_tertiary'))
      .opacity(this.typingDot === index ? 1 : 0.45)
      .translate({ y: this.typingDot === index ? -2 : 0 })
      .animation({ duration: 240, curve: Curve.EaseOut })
  }

  /** A finished turn is when the produced files actually exist. */
  onRunningChange(): void {
    this.refreshArtifacts()
    this.syncTypingTimer()
  }

  onShareText(): void {
    if (this.shareText.length > 0) {
      this.draft = this.shareText
      this.onShareTextConsumed()
    }
  }

  /**
   * Artifacts for the dock, newest first. Both the prose and the tool
   * arguments are scanned: a file the agent wrote usually appears in the
   * `path` argument before the answer ever mentions it, and that argument is
   * the authoritative spelling of the path.
   */
  private dockItems(): ArtifactItem[] {
    const out: ArtifactItem[] = []
    const seen = new Set<string>()
    const probe = makeExists(this.onResolveFile)
    const oldest = Math.max(0, this.messages.length - 30)
    for (let index = this.messages.length - 1; index >= oldest && out.length < 12; index--) {
      const message = this.messages[index]
      const hay = message.toolInput.length > 0 ? `${message.text}\n${message.toolInput}` : message.text
      if (hay.length === 0) {
        continue
      }
      for (const ref of refsFromText(hay, 6, probe)) {
        if (seen.has(ref.path)) {
          continue
        }
        seen.add(ref.path)
        const resolved = this.onResolveFile(ref)
        let exists = false
        try {
          exists = resolved.length > 0 && fs.accessSync(resolved)
        } catch (error) {
          exists = false
        }
        out.push({ path: ref.path, name: ref.name, resolved: resolved, exists: exists })
      }
    }
    return out
  }

  private refreshArtifacts(): void {
    this.artifacts = this.dockItems()
  }

  onCountChange(): void {
    this.refreshArtifacts()
    if (this.messages.length > 0) {
      this.scroller.scrollToIndex(this.messages.length - 1, true)
    }
  }

  /** The stored title is a 24-char cut; the first user message holds the full line. */
  private fullTitle(): string {
    for (let index = 0; index < this.messages.length; index++) {
      if (this.messages[index].role === Role.USER) {
        const flat = this.messages[index].text.replace(/\s+/g, ' ').trim()
        if (flat.length > 0) {
          return flat
        }
      }
    }
    return this.title
  }

  private metaLine(): string {
    const count = this.messages.length
    if (count === 0) {
      return this.projectName
    }
    const countLabel = count === 1 ? '1 条消息' : `${count} 条消息`
    return this.projectName.length > 0 ? `${this.projectName} · ${countLabel}` : countLabel
  }

  @Builder
  titleOverlay() {
    if (this.titleExpanded) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.2)')
          .transition(TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut }))
          .onClick(() => {
            this.titleExpanded = false
          })

        Column({ space: 8 }) {
          Text(this.fullTitle())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .lineHeight(22)
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .copyOption(CopyOptions.LocalDevice)
          if (this.metaLine().length > 0) {
            Text(this.metaLine())
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .constraintSize({ maxWidth: '84%' })
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .backgroundColor($r('app.color.surface'))
        .borderRadius(16)
        .shadow({ radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 })
        .margin({ left: 16, top: 52 })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: '0%', centerY: '0%' }))
            .animation({ curve: curves.springMotion(0.35, 0.85) }),
          TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.97, y: 0.97, centerX: '0%', centerY: '0%' }))
            .animation({ duration: 120, curve: Curve.EaseIn })
        ))
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Row({ space: 2 }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(13)
              .fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.titleExpanded ? 180 : 0 })
              .animation({ curve: curves.springMotion(0.35, 0.85) })

            Text(this.title)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          .scale({
            x: this.titlePressed ? 0.98 : 1,
            y: this.titlePressed ? 0.98 : 1
          })
          .animation({ duration: 120, curve: Curve.EaseOut })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.titlePressed = true
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.titlePressed = false
            }
          })
          .onClick(() => {
            this.titleExpanded = !this.titleExpanded
          })

          Row({ space: 6 }) {
            if (this.showSessionsEntry) {
              this.topIcon($r('app.media.icon_sessions'), (): void => {
                this.onOpenSessions()
              })
            }

            this.topIcon($r('app.media.icon_files'), (): void => {
              this.onOpenFiles()
            })

            this.topIcon($r('app.media.icon_settings'), (): void => {
              this.onOpenSettings()
            })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        Divider().color($r('app.color.divider'))

        if (this.messages.length === 0) {
          Column() {
            Column({ space: 10 }) {
              Row({ space: 8 }) {
                Circle({ width: 10, height: 10 }).fill($r('app.color.brand'))
                Text('dsh 已就绪')
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
              }
              if (this.projectName.length > 0) {
                Text(`当前项目：${this.projectName}`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
              }
              Text('后端运行在本机应用进程内。\n可以让我读文件、改代码、检索网页。\n生成的网页与图片会直接在对话中展示，可点开全屏查看。')
                .fontSize(13)
                .lineHeight(20)
                .textAlign(TextAlign.Center)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Center)
            .padding({ left: 32, right: 32, top: 28, bottom: 28 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(20)
            .constraintSize({ maxWidth: 420 })
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.05)', offsetY: 4 })
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY
                .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
                .animation({ duration: 280, curve: Curve.EaseOut }),
              TransitionEffect.OPACITY.animation({ duration: 120 })
            ))
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 32, right: 32 })
        } else {
          List({ space: 0, scroller: this.scroller }) {
            ForEach(this.messages, (item: ChatMessage, index: number) => {
              ListItem() {
                MessageItem({
                  message: item,
                  running: this.running && index === this.messages.length - 1,
                  onOpenFile: this.onOpenFile,
                  onResolveFile: this.onResolveFile
                })
              }
            }, (item: ChatMessage) => item.id)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .edgeEffect(EdgeEffect.Spring)
        }

        ArtifactDock({
          items: this.artifacts,
          onOpenFull: (item: ArtifactItem) => {
            const ref: FileRef = { path: item.path, name: item.name }
            this.onOpenFile(ref)
          }
        })

        if (this.running) {
          Row({ space: 8 }) {
            Row({ space: 3 }) {
              this.typingDotAt(0)
              this.typingDotAt(1)
              this.typingDotAt(2)
            }
            .width(24)
            .height(14)
            .alignItems(VerticalAlign.Center)

            Text('dsh 正在执行…').fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
            if (this.canStop) {
              Button('停止')
                .fontSize(12)
                .height(28)
                .padding({ left: 12, right: 12 })
                .backgroundColor($r('app.color.surface_muted'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => this.onStop())
            }
          }
          .width('100%')
          .padding({ left: 14, right: 8, top: 6, bottom: 6 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)
          .shadow({ radius: 16, color: 'rgba(0,0,0,0.08)', offsetY: 4 })
          .margin({ left: 16, right: 16, bottom: 4 })
          .justifyContent(FlexAlign.Start)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 10 }))
            .animation({ duration: 220, curve: Curve.EaseOut }))
        }

        if (this.attachPaths.length > 0) {
          Column({ space: 6 }) {
            Row({ space: 8 }) {
              Scroll() {
                Row({ space: 8 }) {
                  ForEach(this.attachPaths, (path: string) => {
                    Image(`file://${path}`)
                      .width(40)
                      .height(40)
                      .borderRadius(10)
                      .objectFit(ImageFit.Cover)
                  }, (path: string) => path)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .align(Alignment.Start)
              .layoutWeight(1)

              Text('✕')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .onClick(() => this.onRemoveAttachment())
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(`${this.attachPaths.length} 张图片将随下一条消息发送`)
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor($r('app.color.surface_muted'))
          .borderRadius(12)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 8 }))
            .animation({ duration: 220, curve: Curve.EaseOut }))
        }

        Row({ space: 10 }) {
          Stack({ alignContent: Alignment.End }) {
            TextArea({ text: this.draft })
              .width('100%')
              .fontSize(15)
              .padding({ left: 12, right: this.showModelPicker ? 118 : 48, top: 8, bottom: 8 })
              .constraintSize({ minHeight: 44, maxHeight: 132 })
              .backgroundColor($r('app.color.surface_muted'))
              .borderRadius(14)
              .border({
                width: 1,
                color: this.composerFocused ? 'rgba(77,107,254,0.45)' : Color.Transparent
              })
              .animation({ duration: 160, curve: Curve.EaseOut })
              .onFocus(() => {
                this.composerFocused = true
              })
              .onBlur(() => {
                this.composerFocused = false
              })
              .onChange((value: string) => {
                this.draft = value
              })

            Row({ space: 6 }) {
              if (this.showModelPicker) {
                Text(this.modelLabel)
                  .fontSize(10)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 72 })
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .fontColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.surface'))
                  .borderRadius(12)
                  .scale({
                    x: this.modelPressed ? 0.94 : 1,
                    y: this.modelPressed ? 0.94 : 1
                  })
                  .animation({ duration: 120, curve: Curve.EaseOut })
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.modelPressed = true
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.modelPressed = false
                    }
                  })
                  .onClick(() => this.onPickModel())
              }

              Button({ type: ButtonType.Circle }) {
                Image($r('app.media.icon_image'))
                  .width(16)
                  .height(16)
                  .fillColor($r('app.color.text_secondary'))
              }
              .width(34)
              .height(34)
              .backgroundColor($r('app.color.surface'))
              .scale({
                x: this.imagePressed ? 0.92 : 1,
                y: this.imagePressed ? 0.92 : 1
              })
              .animation({ duration: 120, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.imagePressed = true
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.imagePressed = false
                }
              })
              .onClick(() => this.onPickImage())
            }
            .margin({ right: 6 })
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)

          Button('发送', { type: ButtonType.Capsule })
            .height(44)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.draft.trim().length > 0 || this.attachPaths.length > 0 ?
              $r('app.color.brand') : $r('app.color.surface_muted'))
            .fontColor(this.draft.trim().length > 0 || this.attachPaths.length > 0 ?
              Color.White : $r('app.color.text_tertiary'))
            .scale({
              x: this.sendPressed ? 0.96 : 1,
              y: this.sendPressed ? 0.96 : 1
            })
            .animation({ duration: 120, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.sendPressed = true
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.sendPressed = false
              }
            })
            .enabled(this.draft.trim().length > 0 || this.attachPaths.length > 0)
            .onClick(() => {
              const text = this.draft.trim()
              if (text.length === 0 && this.attachPaths.length === 0) {
                return
              }
              this.draft = ''
              this.onSend(text, this.attachPaths)
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.background'))

      this.titleOverlay()
    }
    .width('100%')
    .height('100%')
  }
}
