import { ChatMessage, Role } from '../model/ChatModel'

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
 * Extract previewable file references from message text. The pattern only
 * accepts ASCII path characters, so it finds paths embedded in Chinese prose
 * without word separators; the extension whitelist filters versions, URLs
 * without files, and other dot noise. Results are de-duplicated, capped.
 */
export function refsFromText(text: string): FileRef[] {
  const out: FileRef[] = []
  const seen = new Set<string>()
  const matches = text.match(/[A-Za-z0-9_\-./~@]+\.[A-Za-z]{1,6}/g)
  if (matches === null) {
    return out
  }
  for (const match of matches) {
    const dot = match.lastIndexOf('.')
    const ext = match.substring(dot + 1).toLowerCase()
    if (!isPreviewExt(ext)) {
      continue
    }
    if (seen.has(match)) {
      continue
    }
    seen.add(match)
    out.push({ path: match, name: basenameOf(match) })
    if (out.length >= 4) {
      break
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

@Component
export struct MessageItem {
  @ObjectLink message: ChatMessage
  onOpenFile: (ref: FileRef) => void = () => {}

  private refs(): FileRef[] {
    return refsFromText(this.message.text)
  }

  private bubbleColor(): ResourceColor {
    if (this.message.role === Role.USER) {
      return $r('app.color.bubble_user')
    }
    if (this.message.role === Role.TOOL) {
      return $r('app.color.bubble_tool')
    }
    if (this.message.role === Role.SYSTEM) {
      return $r('app.color.surface_muted')
    }
    return $r('app.color.bubble_assistant')
  }

  private bubbleAlign(): HorizontalAlign {
    return this.message.role === Role.USER ? HorizontalAlign.End : HorizontalAlign.Start
  }

  build() {
    Column({ space: 6 }) {
      if (this.message.note.length > 0) {
        Text(this.message.note)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Column({ space: 8 }) {
        ForEach(segmentsOf(this.message.text), (segment: Segment) => {
          if (segment.code) {
            Text(segment.text)
              .fontSize(13)
              .fontFamily('monospace')
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding(10)
              .backgroundColor($r('app.color.code_background'))
              .borderRadius(8)
          } else {
            Text(segment.text)
              .fontSize(15)
              .lineHeight(22)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
        })
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(this.bubbleColor())
      .borderRadius(16)
      .constraintSize({ maxWidth: '86%' })

      if (this.refs().length > 0) {
        Row({ space: 6 }) {
          ForEach(this.refs(), (ref: FileRef) => {
            Text(ref.name)
              .fontSize(11)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 140 })
              .fontColor($r('app.color.brand'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.surface_muted'))
              .borderRadius(8)
              .onClick(() => this.onOpenFile(ref))
          }, (ref: FileRef) => ref.path)
        }
      }
    }
    .width('100%')
    .alignItems(this.bubbleAlign())
    .margin({ bottom: 12 })
  }
}

/** Conversation pane: transcript plus composer. */
@Component
export struct ChatView {
  @Link @Watch('onCountChange') messages: ChatMessage[]
  @Prop running: boolean = false
  @Prop title: string = '新会话'
  @Prop projectName: string = ''
  @State draft: string = ''
  /** Phones have no rail: show a top-bar entry that opens the sessions sheet. */
  showSessionsEntry: boolean = false
  onSend: (text: string) => void = () => {}
  onNewSession: () => void = () => {}
  onOpenSettings: () => void = () => {}
  onOpenSessions: () => void = () => {}
  onOpenFile: (ref: FileRef) => void = () => {}
  private scroller: Scroller = new Scroller()

  onCountChange(): void {
    if (this.messages.length > 0) {
      this.scroller.scrollToIndex(this.messages.length - 1, true)
    }
  }

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.showSessionsEntry) {
          Button('会话')
            .fontSize(13)
            .height(32)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => this.onOpenSessions())
        }

        Button('新会话')
          .fontSize(13)
          .height(32)
          .margin({ left: this.showSessionsEntry ? 8 : 0 })
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.onNewSession())

        Button('设置')
          .fontSize(13)
          .height(32)
          .margin({ left: 8 })
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.onOpenSettings())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Divider().color($r('app.color.divider'))

      if (this.messages.length === 0) {
        Column({ space: 10 }) {
          Text('dsh 已就绪')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
          if (this.projectName.length > 0) {
            Text(`当前项目：${this.projectName}`)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
          }
          Text('后端运行在本机应用进程内。\n可以让我读文件、改代码、检索网页。\n生成的网页与图片可在对话中点开预览。')
            .fontSize(13)
            .lineHeight(20)
            .textAlign(TextAlign.Center)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 32, right: 32 })
      } else {
        List({ space: 0, scroller: this.scroller }) {
          ForEach(this.messages, (item: ChatMessage) => {
            ListItem() {
              MessageItem({ message: item, onOpenFile: this.onOpenFile })
            }
          }, (item: ChatMessage) => item.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
        .edgeEffect(EdgeEffect.Spring)
      }

      if (this.running) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color($r('app.color.brand'))
          Text('dsh 正在执行…').fontSize(12).fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ left: 16, bottom: 4 })
        .justifyContent(FlexAlign.Start)
      }

      Row({ space: 10 }) {
        TextArea({ text: this.draft, placeholder: '给 dsh 下指令…' })
          .layoutWeight(1)
          .fontSize(15)
          .constraintSize({ minHeight: 44, maxHeight: 132 })
          .backgroundColor($r('app.color.surface_muted'))
          .borderRadius(14)
          .onChange((value: string) => {
            this.draft = value
          })

        Button('发送')
          .height(44)
          .enabled(this.draft.trim().length > 0)
          .onClick(() => {
            const text = this.draft.trim()
            if (text.length === 0) {
              return
            }
            this.draft = ''
            this.onSend(text)
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }
}
