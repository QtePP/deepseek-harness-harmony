import { pasteboard, BusinessError } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { webview } from '@kit.ArkWeb'

/** Block kinds produced by the Markdown block parser. */
export enum MdKind {
  Paragraph = 0,
  Heading = 1,
  Code = 2,
  ListItem = 3,
  Quote = 4,
  Rule = 5,
  Table = 6
}

/** One block-level element of a rendered message. */
export class MdBlock {
  kind: MdKind = MdKind.Paragraph
  text: string = ''
  /** Fence language tag, code blocks only. */
  lang: string = ''
  /** Heading level 1-6. */
  level: number = 0
  /** List nesting depth. */
  indent: number = 0
  /** List bullet or ordinal label. */
  marker: string = ''
  /** Raw table rows, table blocks only. */
  lines: string[] = []
}

/** One styled inline fragment inside a block. */
export class MdSpan {
  text: string = ''
  bold: boolean = false
  italic: boolean = false
  strike: boolean = false
  code: boolean = false
  link: string = ''
}

/** Accumulates blocks while the line scanner walks the message. */
class BlockCollector {
  blocks: MdBlock[] = []
  para: string[] = []

  flushParagraph(): void {
    if (this.para.length > 0) {
      const block = new MdBlock()
      block.kind = MdKind.Paragraph
      block.text = this.para.join('\n')
      this.blocks.push(block)
      this.para = []
    }
  }
}

function stripLead(line: string): string {
  let start = 0
  while (start < line.length && (line.charAt(start) === ' ' || line.charAt(start) === '\t')) {
    start++
  }
  return line.substring(start)
}

function leadingSpaces(line: string): number {
  let count = 0
  while (count < line.length && (line.charAt(count) === ' ' || line.charAt(count) === '\t')) {
    count++
  }
  return count
}

/** Copy plain text onto the system clipboard; resolves when the write lands. */
export function copyTextToClipboard(text: string): Promise<void> {
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
  return pasteboard.getSystemPasteboard().setData(data)
}

/** Stable 32-bit hash so re-rendering the same block reuses one temp file. */
function hashOf(text: string): number {
  let hash = 5381
  for (let index = 0; index < text.length; index++) {
    hash = (hash * 33 + text.charCodeAt(index)) | 0
  }
  return Math.abs(hash)
}

/** Split one raw table line into trimmed cells; edge pipes dropped. */
function splitTableRow(line: string): string[] {
  let body = line.trim()
  if (body.startsWith('|')) {
    body = body.substring(1)
  }
  if (body.endsWith('|')) {
    body = body.substring(0, body.length - 1)
  }
  const cells: string[] = []
  for (const cell of body.split('|')) {
    cells.push(cell.trim())
  }
  return cells
}

/** Whether a row is the `---|:---:` separator under the header. */
function isSeparatorRow(cells: string[]): boolean {
  if (cells.length === 0) {
    return false
  }
  for (const cell of cells) {
    if (!/^:?-+:?$/.test(cell)) {
      return false
    }
  }
  return true
}

/**
 * Block-level Markdown parser: fenced code, ATX headings, bullet and ordered
 * lists (one block per item, nesting by leading spaces), block quotes, rules,
 * pipe tables (two or more adjacent rows) and paragraphs. Inline markup stays
 * literal here and is expanded later by parseInlines().
 */
export function parseBlocks(raw: string): MdBlock[] {
  const collector = new BlockCollector()
  const lines = raw.replace(/\r\n/g, '\n').split('\n')
  let index = 0
  while (index < lines.length) {
    const line = lines[index]
    const stripped = line.trim()

    if (stripped.startsWith('```')) {
      collector.flushParagraph()
      const lang = stripped.substring(3).trim()
      const codeLines: string[] = []
      index++
      while (index < lines.length && !lines[index].trim().startsWith('```')) {
        codeLines.push(lines[index])
        index++
      }
      if (index < lines.length) {
        index++
      }
      const block = new MdBlock()
      block.kind = MdKind.Code
      block.text = codeLines.join('\n')
      block.lang = lang
      collector.blocks.push(block)
      continue
    }

    if (stripped.length === 0) {
      collector.flushParagraph()
      index++
      continue
    }

    const heading = stripped.match(/^(#{1,6})\s+(.+)$/)
    if (heading !== null) {
      collector.flushParagraph()
      const block = new MdBlock()
      block.kind = MdKind.Heading
      block.level = heading[1].length
      block.text = heading[2]
      collector.blocks.push(block)
      index++
      continue
    }

    if (/^(-{3,}|\*{3,}|_{3,})$/.test(stripped)) {
      collector.flushParagraph()
      const block = new MdBlock()
      block.kind = MdKind.Rule
      collector.blocks.push(block)
      index++
      continue
    }

    if (stripped.startsWith('>')) {
      collector.flushParagraph()
      const quoteLines: string[] = []
      while (index < lines.length) {
        const quoteLine = lines[index].trim()
        if (!quoteLine.startsWith('>')) {
          break
        }
        quoteLines.push(quoteLine.startsWith('> ') ? quoteLine.substring(2) : quoteLine.substring(1))
        index++
      }
      const block = new MdBlock()
      block.kind = MdKind.Quote
      block.text = quoteLines.join('\n')
      collector.blocks.push(block)
      continue
    }

    if (stripped.startsWith('|') && index + 1 < lines.length && lines[index + 1].trim().startsWith('|')) {
      collector.flushParagraph()
      const rows: string[] = []
      while (index < lines.length && lines[index].trim().startsWith('|')) {
        rows.push(lines[index].trim())
        index++
      }
      const block = new MdBlock()
      block.kind = MdKind.Table
      block.lines = rows
      collector.blocks.push(block)
      continue
    }

    const rest = stripLead(line)
    const unordered = rest.match(/^([-*+])\s+(.+)$/)
    const ordered = rest.match(/^(\d{1,3})[.)]\s+(.+)$/)
    if (unordered !== null) {
      collector.flushParagraph()
      const block = new MdBlock()
      block.kind = MdKind.ListItem
      block.indent = Math.min(Math.floor(leadingSpaces(line) / 2), 3)
      block.marker = '•'
      block.text = unordered[2]
      collector.blocks.push(block)
      index++
      continue
    }
    if (ordered !== null) {
      collector.flushParagraph()
      const block = new MdBlock()
      block.kind = MdKind.ListItem
      block.indent = Math.min(Math.floor(leadingSpaces(line) / 2), 3)
      block.marker = `${ordered[1]}.`
      block.text = ordered[2]
      collector.blocks.push(block)
      index++
      continue
    }

    collector.para.push(stripped)
    index++
  }
  collector.flushParagraph()
  return collector.blocks
}

function cloneSpan(span: MdSpan): MdSpan {
  const copy = new MdSpan()
  copy.text = span.text
  copy.bold = span.bold
  copy.italic = span.italic
  copy.strike = span.strike
  copy.code = span.code
  copy.link = span.link
  return copy
}

/**
 * Second pass over a styled span: `code` pairs inside bold/italic/strike
 * become code fragments that keep the outer style, so "**`x`**" renders
 * both effects instead of leaving literal backticks.
 */
function expandCodeInto(base: MdSpan): MdSpan[] {
  if (!base.text.includes('`')) {
    return [base]
  }
  const out: MdSpan[] = []
  const pattern = /`([^`\n]+)`/g
  let last = 0
  let match = pattern.exec(base.text)
  while (match !== null) {
    if (match.index > last) {
      const piece = cloneSpan(base)
      piece.text = base.text.substring(last, match.index)
      out.push(piece)
    }
    const codePiece = cloneSpan(base)
    codePiece.text = match[1]
    codePiece.code = true
    out.push(codePiece)
    last = pattern.lastIndex
    match = pattern.exec(base.text)
  }
  if (last < base.text.length) {
    const piece = cloneSpan(base)
    piece.text = base.text.substring(last)
    out.push(piece)
  }
  return out
}

/**
 * Inline Markdown parser: `code`, **bold**, __bold__, *italic*, ~~strike~~,
 * [text](url) and ![alt](url). One pass, alternation ordered so bold wins
 * over italic. Bold content may contain underscores (NOTES_LIMIT style);
 * code pairs nested in bold/italic/strike expand in a second pass.
 * Unmatched markers stay literal.
 */
export function parseInlines(raw: string): MdSpan[] {
  const out: MdSpan[] = []
  const pattern = /`([^`\n]+)`|(\*\*)([^*\n]+)\2|(__)([^_\n]+)\4|\*([^*\n]+)\*|~~([^~\n]+)~~|!\[([^\]]*)\]\(([^)\s]+)\)|\[([^\]]+)\]\(([^)\s]+)\)/g
  let last = 0
  let match = pattern.exec(raw)
  while (match !== null) {
    if (match.index > last) {
      const span = new MdSpan()
      span.text = raw.substring(last, match.index)
      out.push(span)
    }
    if (match[1] !== undefined) {
      const span = new MdSpan()
      span.text = match[1]
      span.code = true
      out.push(span)
    } else if (match[2] !== undefined) {
      const base = new MdSpan()
      base.text = match[3]
      base.bold = true
      for (const piece of expandCodeInto(base)) {
        out.push(piece)
      }
    } else if (match[4] !== undefined) {
      const base = new MdSpan()
      base.text = match[5]
      base.bold = true
      for (const piece of expandCodeInto(base)) {
        out.push(piece)
      }
    } else if (match[6] !== undefined) {
      const base = new MdSpan()
      base.text = match[6]
      base.italic = true
      for (const piece of expandCodeInto(base)) {
        out.push(piece)
      }
    } else if (match[7] !== undefined) {
      const base = new MdSpan()
      base.text = match[7]
      base.strike = true
      for (const piece of expandCodeInto(base)) {
        out.push(piece)
      }
    } else if (match[8] !== undefined) {
      const span = new MdSpan()
      span.text = match[8].length > 0 ? `（图：${match[8]}）` : '（图）'
      span.link = match[9]
      out.push(span)
    } else {
      const span = new MdSpan()
      span.text = match[10]
      span.link = match[11]
      out.push(span)
    }
    last = pattern.lastIndex
    match = pattern.exec(raw)
  }
  if (last < raw.length) {
    const span = new MdSpan()
    span.text = raw.substring(last)
    out.push(span)
  }
  return out
}

/** One lexed fragment of a fenced code block. */
export class CodeToken {
  text: string = ''
  /** 'plain' | 'comment' | 'string' | 'keyword' | 'number' | 'tag' | 'attr' */
  kind: string = 'plain'
}

function pushToken(out: CodeToken[], text: string, kind: string): void {
  if (text.length === 0) {
    return
  }
  const token = new CodeToken()
  token.text = text
  token.kind = kind
  out.push(token)
}

const KEYWORD_JS = 'const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|implements|interface|enum|struct|import|export|from|as|async|await|try|catch|finally|throw|typeof|instanceof|in|of|delete|void|this|super|public|private|protected|static|readonly|null|undefined|true|false|yield|default'
const KEYWORD_PY = 'def|class|return|if|elif|else|for|while|import|from|as|with|try|except|finally|raise|lambda|pass|break|continue|global|nonlocal|assert|yield|async|await|and|or|not|in|is|None|True|False|self|print|range|len'
const KEYWORD_SH = 'if|then|else|elif|fi|for|while|until|do|done|case|esac|function|return|export|local|source|echo|cd|exit'

/** Highlight family for a fence tag; '' means plain monospace. */
function codeFamily(lang: string): string {
  const tag = lang.trim().toLowerCase()
  if (tag === 'js' || tag === 'javascript' || tag === 'jsx' || tag === 'mjs' || tag === 'cjs' ||
    tag === 'ts' || tag === 'typescript' || tag === 'tsx' || tag === 'ets' ||
    tag === 'java' || tag === 'kt' || tag === 'kotlin' || tag === 'c' || tag === 'cpp' ||
    tag === 'go' || tag === 'rs' || tag === 'rust' || tag === 'swift' || tag === 'dart') {
    return 'js'
  }
  if (tag === 'py' || tag === 'python') {
    return 'py'
  }
  if (tag === 'sh' || tag === 'bash' || tag === 'zsh' || tag === 'shell' || tag === 'console') {
    return 'sh'
  }
  if (tag === 'json') {
    return 'json'
  }
  if (tag === 'yml' || tag === 'yaml') {
    return 'yaml'
  }
  if (tag === 'html' || tag === 'htm' || tag === 'xhtml' || tag === 'xml' || tag === 'svg') {
    return 'markup'
  }
  if (tag === 'css' || tag === 'scss' || tag === 'less') {
    return 'css'
  }
  return ''
}

/** Token color per kind; palette tuned for the light code background. */
/**
 * Syntax palette. GitHub-light hues, nudged darker so every token clears
 * 4.5:1 against the #F6F8FA panel — the old comment grey (#6E7781) sat right
 * at the edge and read as disabled text on a phone screen.
 */
function codeTokenColor(kind: string): ResourceColor {
  if (kind === 'comment') {
    return '#57606A'
  }
  if (kind === 'string') {
    return '#0A3069'
  }
  if (kind === 'keyword') {
    return '#B3122B'
  }
  if (kind === 'number') {
    return '#0550AE'
  }
  if (kind === 'tag') {
    return '#0F5323'
  }
  if (kind === 'attr') {
    return '#7D3C00'
  }
  return $r('app.color.text_primary')
}

const FAMILY_PATTERN_CACHE: Map<string, RegExp> = new Map<string, RegExp>()

/** Cached per-family line pattern: string | comment | number | keyword. */
function familyPattern(family: string): RegExp {
  const cached = FAMILY_PATTERN_CACHE.get(family)
  if (cached !== undefined) {
    return cached
  }
  const hashComment = family === 'py' || family === 'sh' || family === 'yaml'
  const keywords = family === 'py' ? KEYWORD_PY :
    (family === 'sh' ? KEYWORD_SH : (family === 'json' ? 'true|false|null' : KEYWORD_JS))
  // Strings come first so a quote inside a comment or a `//` inside a URL
  // string do not swallow the rest of the line as a comment.
  let source = '("(?:[^"\\\\]|\\\\.)*"|\'(?:[^\'\\\\]|\\\\.)*\'|`(?:[^`\\\\]|\\\\.)*`)'
  source += hashComment ? '|(#.*$)' : '|(\\/\\/.*$)'
  source += '|\\b(\\d+(?:\\.\\d+)?)\\b'
  if (keywords.length > 0) {
    source += `|\\b(${keywords})\\b`
  }
  const pattern = new RegExp(source, 'g')
  FAMILY_PATTERN_CACHE.set(family, pattern)
  return pattern
}

/** js/py/sh/json/yaml line: string, comment, number, keyword. */
function tokenizeFamilyLine(line: string, family: string, out: CodeToken[]): void {
  const pattern = familyPattern(family)
  let last = 0
  let match = pattern.exec(line)
  while (match !== null) {
    pushToken(out, line.substring(last, match.index), 'plain')
    if (match[1] !== undefined) {
      pushToken(out, match[1], 'string')
    } else if (match[2] !== undefined) {
      pushToken(out, match[2], 'comment')
    } else if (match[3] !== undefined) {
      pushToken(out, match[3], 'number')
    } else if (match[4] !== undefined) {
      pushToken(out, match[4], 'keyword')
    }
    last = pattern.lastIndex
    match = pattern.exec(line)
  }
  pushToken(out, line.substring(last), 'plain')
}

/** html/xml line: comment, tag, attribute, quoted value. */
const MARKUP_LINE_RE = /(<!--.*-->|<!--.*$)|(<\/?[A-Za-z][\w-]*|\/?>)|("(?:[^"]*)")|([A-Za-z-]+)(?==)/g

function tokenizeMarkupLine(line: string, out: CodeToken[]): void {
  let last = 0
  let match = MARKUP_LINE_RE.exec(line)
  while (match !== null) {
    pushToken(out, line.substring(last, match.index), 'plain')
    if (match[1] !== undefined) {
      pushToken(out, match[1], 'comment')
    } else if (match[2] !== undefined) {
      pushToken(out, match[2], 'tag')
    } else if (match[3] !== undefined) {
      pushToken(out, match[3], 'string')
    } else if (match[4] !== undefined) {
      pushToken(out, match[4], 'attr')
    }
    last = MARKUP_LINE_RE.lastIndex
    match = MARKUP_LINE_RE.exec(line)
  }
  pushToken(out, line.substring(last), 'plain')
}

/** css line: comment, string, hex/number, property name. */
const CSS_LINE_RE = /(\/\*.*?(?:\*\/|$))|("(?:[^"]*)"|'(?:[^']*)')|(#[0-9a-fA-F]{3,8}\b)|\b(\d+(?:\.\d+)?(?:px|em|rem|vh|vw|s|ms|%)?)\b|([a-zA-Z-]+)(?=\s*:)/g

function tokenizeCssLine(line: string, out: CodeToken[]): void {
  let last = 0
  let match = CSS_LINE_RE.exec(line)
  while (match !== null) {
    pushToken(out, line.substring(last, match.index), 'plain')
    if (match[1] !== undefined) {
      pushToken(out, match[1], 'comment')
    } else if (match[2] !== undefined) {
      pushToken(out, match[2], 'string')
    } else if (match[3] !== undefined) {
      pushToken(out, match[3], 'number')
    } else if (match[4] !== undefined) {
      pushToken(out, match[4], 'number')
    } else if (match[5] !== undefined) {
      pushToken(out, match[5], 'attr')
    }
    last = CSS_LINE_RE.lastIndex
    match = CSS_LINE_RE.exec(line)
  }
  pushToken(out, line.substring(last), 'plain')
}

/** Lex fenced code into colored tokens; unknown languages stay plain. */
export function tokenize(code: string, lang: string): CodeToken[] {
  const family = codeFamily(lang)
  const out: CodeToken[] = []
  const lines = code.split('\n')
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    if (family === 'markup') {
      tokenizeMarkupLine(line, out)
    } else if (family === 'css') {
      tokenizeCssLine(line, out)
    } else if (family.length > 0) {
      tokenizeFamilyLine(line, family, out)
    } else {
      pushToken(out, line, 'plain')
    }
    if (index < lines.length - 1) {
      pushToken(out, '\n', 'plain')
    }
  }
  return out
}

/** One block's inline content rendered as a styled Span tree. */
@Component
struct InlineText {
  @Prop content: string = ''
  @Prop baseSize: number = 15
  @Prop lineH: number = 22
  @Prop strongAll: boolean = false
  @Prop muted: boolean = false

  build() {
    Text() {
      ForEach(parseInlines(this.content), (span: MdSpan, index: number) => {
        Span(span.text)
          .fontWeight(span.bold || this.strongAll ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration(span.strike ? { type: TextDecorationType.LineThrough } :
            (span.link.length > 0 ? { type: TextDecorationType.Underline } : { type: TextDecorationType.None }))
          .fontColor(span.code || span.link.length > 0 ? $r('app.color.brand') :
            (this.muted ? $r('app.color.text_secondary') : $r('app.color.text_primary')))
          .fontFamily(span.code ? 'monospace' : 'HarmonyOS Sans')
      }, (span: MdSpan, index: number) => `${index}.${span.text.length}.${span.bold}.${span.code}.${span.link.length}`)
    }
    .fontSize(this.baseSize)
    .lineHeight(this.lineH)
    .wordBreak(WordBreak.BREAK_ALL)
  }
}

/** A fenced code block body with per-language keyword coloring. */
@Component
struct CodeText {
  @Prop code: string = ''
  @Prop lang: string = ''

  build() {
    Text() {
      ForEach(tokenize(this.code, this.lang), (token: CodeToken, index: number) => {
        Span(token.text)
          .fontColor(codeTokenColor(token.kind))
      }, (token: CodeToken, index: number) => `${index}.${token.kind}.${token.text.length}`)
    }
    .fontSize(13)
    .lineHeight(19)
    .fontFamily('monospace')
    .wordBreak(WordBreak.BREAK_ALL)
  }
}

/** Renders one parsed Markdown block with the style of its kind. */
@Component
struct MdBlockView {
  @Prop block: MdBlock = new MdBlock()
  /** HTML/SVG fenced blocks can be rendered live instead of shown as source. */
  @State previewing: boolean = false
  @State previewPath: string = ''
  /** `markdown` fences render as content first; the raw text is one tap away. */
  @State showSource: boolean = false
  private controller: webview.WebviewController = new webview.WebviewController()
  /** Pending auto-preview timer; cancelled when the block unmounts. */
  private previewTimer: number = -1

  aboutToAppear(): void {
    if (!this.canPreview()) {
      return
    }
    // 主动渲染：文档型 html/svg 代码块在文本稳定半秒后自动挂内嵌预览；
    // 流式增长会重建本组件、重置计时，避免半截文档反复闪烁。
    const snapshot = this.block.text
    this.previewTimer = setTimeout(() => {
      this.previewTimer = -1
      if (!this.previewing && this.block.text === snapshot) {
        this.togglePreview()
      }
    }, 500)
  }

  aboutToDisappear(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer)
      this.previewTimer = -1
    }
  }

  private headingSize(level: number): number {
    if (level <= 1) {
      return 20
    }
    if (level === 2) {
      return 18
    }
    if (level === 3) {
      return 16
    }
    return 15
  }

  /**
   * Whether this block is a document rather than code: a `html`/`svg` fence,
   * or an untagged fence that opens with a document prologue. Models
   * frequently wrap whole pages in a bare fence, which used to render as an
   * unreadable wall of source with no way to see the result.
   */
  private canPreview(): boolean {
    const lang = this.block.lang.trim().toLowerCase()
    if (lang === 'html' || lang === 'htm' || lang === 'svg' || lang === 'xhtml') {
      return true
    }
    if (lang.length > 0) {
      return false
    }
    const head = this.block.text.trim().substring(0, 120).toLowerCase()
    return head.startsWith('<!doctype') || head.startsWith('<html') || head.startsWith('<svg')
  }

  /**
   * `md`/`markdown` fences carry a document the model wrote for the user —
   * a .md file's body. Rendering the source as a code box hid the actual
   * content behind a wall of markup, so these render as Markdown by default.
   */
  private isMarkdownDoc(): boolean {
    const lang = this.block.lang.trim().toLowerCase()
    return lang === 'md' || lang === 'markdown'
  }

  /** Materialise the block as a cache file and hand it to an embedded Web pane. */
  private togglePreview(): void {
    if (this.previewing) {
      this.previewing = false
      return
    }
    try {
      const context = getContext(this) as common.UIAbilityContext
      const path = `${context.cacheDir}/md-preview-${hashOf(this.block.text)}.html`
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      try {
        fs.writeSync(file.fd, this.block.text)
      } finally {
        fs.closeSync(file)
      }
      this.previewPath = path
      this.previewing = true
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({
        message: `预览失败：${(error as BusinessError).message}`,
        duration: 2000
      })
    }
  }

  private copyCode(): void {
    copyTextToClipboard(this.block.text)
      .then(() => {
        this.getUIContext().getPromptAction().showToast({ message: '代码已复制', duration: 1500 })
      })
      .catch((error: BusinessError) => {
        this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1500 })
      })
  }

  /** Header cells of the first table row. */
  private tableHeader(): string[] {
    if (this.block.lines.length === 0) {
      return []
    }
    return splitTableRow(this.block.lines[0])
  }

  /** Body rows with the separator skipped, short rows padded to the header width. */
  private tableBodyRows(): string[][] {
    const width = this.tableHeader().length
    const rows: string[][] = []
    for (let index = 1; index < this.block.lines.length; index++) {
      const cells = splitTableRow(this.block.lines[index])
      if (isSeparatorRow(cells)) {
        continue
      }
      while (cells.length < width) {
        cells.push('')
      }
      rows.push(cells)
    }
    return rows
  }

  build() {
    if (this.block.kind === MdKind.Code && this.isMarkdownDoc()) {
      Column() {
        Row({ space: 8 }) {
          Text(this.block.lang)
            .fontSize(10)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 240 })
            .layoutWeight(1)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.showSource ? '预览' : '源码')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(8)
            .onClick(() => {
              this.showSource = !this.showSource
            })
          Text('复制')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(8)
            .onClick(() => this.copyCode())
        }
        .width('100%')

        if (this.showSource) {
          CodeText({ code: this.block.text, lang: this.block.lang })
            .padding(10)
        } else {
          // The fenced Markdown is the content itself; render it inline.
          Column({ space: 6 }) {
            ForEach(parseBlocks(this.block.text), (sub: MdBlock, index: number) => {
              MdBlockView({ block: sub })
            }, (sub: MdBlock, index: number) => `${index}.${sub.kind}.${sub.text.length}.${sub.lines.join('').length}`)
          }
          .alignItems(HorizontalAlign.Start)
          .padding(10)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.code_background'))
      .borderRadius(10)
      .clip(true)
    } else if (this.block.kind === MdKind.Code) {
      Column() {
        // Header strip: language label on the left, actions pinned right.
        // The label must NOT take layoutWeight — that stretched it to the
        // full row and shoved the buttons to the far edge of the screen.
        Row() {
          Text(this.block.lang.length > 0 ? this.block.lang : '代码')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .letterSpacing(0.4)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 180 })
            .fontColor($r('app.color.text_secondary'))

          Blank()

          Row({ space: 6 }) {
            if (this.canPreview()) {
              Text(this.previewing ? '收起预览' : '预览')
                .fontSize(11)
                .fontColor($r('app.color.brand'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor($r('app.color.surface'))
                .borderRadius(7)
                .onClick(() => this.togglePreview())
            }
            Text('复制')
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.surface'))
              .borderRadius(7)
              .onClick(() => this.copyCode())
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 8, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.code_header'))

        if (this.previewing && this.previewPath.length > 0) {
          Web({ src: `file://${this.previewPath}`, controller: this.controller })
            .fileAccess(true)
            .domStorageAccess(true)
            .width('100%')
            .height(320)
            .borderRadius(8)
        } else {
          Scroll() {
            CodeText({ code: this.block.text, lang: this.block.lang })
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          }
          .width('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .backgroundColor($r('app.color.code_background'))
      .borderRadius(10)
      // A hairline border separates the block from the page; without it the
      // light-grey panel dissolved into the white transcript.
      .border({ width: 1, color: $r('app.color.code_border') })
      .clip(true)
    } else if (this.block.kind === MdKind.Heading) {
      InlineText({
        content: this.block.text,
        baseSize: this.headingSize(this.block.level),
        lineH: Math.round(this.headingSize(this.block.level) * 1.4),
        strongAll: true
      })
    } else if (this.block.kind === MdKind.ListItem) {
      Row({ space: 6 }) {
        Text(this.block.marker)
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
        InlineText({ content: this.block.text, baseSize: 15, lineH: 22 })
      }
      .alignItems(VerticalAlign.Top)
      .padding({ left: this.block.indent * 14 })
    } else if (this.block.kind === MdKind.Quote) {
      Row({ space: 8 }) {
        Column()
          .width(3)
          .borderRadius(2)
          .backgroundColor($r('app.color.brand'))
          .alignSelf(ItemAlign.Stretch)
        InlineText({ content: this.block.text, baseSize: 14, lineH: 20, muted: true })
      }
      .padding({ left: 6, right: 6 })
    } else if (this.block.kind === MdKind.Rule) {
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(1)
        .width(160)
    } else if (this.block.kind === MdKind.Table) {
      Column() {
        Row() {
          ForEach(this.tableHeader(), (cell: string, index: number) => {
            Column() {
              InlineText({ content: cell, baseSize: 13, lineH: 18, strongAll: true })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          }, (cell: string, index: number) => `${index}.${cell}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .backgroundColor($r('app.color.surface_muted'))

        ForEach(this.tableBodyRows(), (row: string[], rowIndex: number) => {
          Column() {
            if (rowIndex > 0) {
              Divider()
                .color($r('app.color.divider'))
                .strokeWidth(1)
            }
            Row() {
              ForEach(row, (cell: string, colIndex: number) => {
                Column() {
                  InlineText({ content: cell, baseSize: 13, lineH: 18 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              }, (cell: string, colIndex: number) => `${colIndex}.${cell}`)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
        }, (row: string[], rowIndex: number) => `${rowIndex}.${row.join('\u0001')}`)
      }
      .width('100%')
      .borderRadius(8)
      .clip(true)
    } else {
      InlineText({ content: this.block.text, baseSize: 15, lineH: 22 })
    }
  }
}

/** Renders a full assistant message as Markdown. Entry point for bubbles. */
@Component
export struct MdText {
  @Prop raw: string = ''

  build() {
    Column({ space: 6 }) {
      ForEach(parseBlocks(this.raw), (block: MdBlock, index: number) => {
        MdBlockView({ block: block })
      }, (block: MdBlock, index: number) => `${index}.${block.kind}.${block.text.length}.${block.lines.join('').length}`)
    }
    .alignItems(HorizontalAlign.Start)
  }
}
