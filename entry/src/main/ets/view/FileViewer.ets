import { webview } from '@kit.ArkWeb'
import { fileIo as fs } from '@kit.CoreFileKit'
import { MdText } from './Markdown'

/** How a referenced file renders. */
enum PreviewKind {
  WEB = 'web',
  IMAGE = 'image',
  MARKDOWN = 'markdown',
  TEXT = 'text'
}

const WEB_EXTS: string[] = ['html', 'htm', 'svg']
const IMAGE_EXTS: string[] = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp']
const MD_EXTS: string[] = ['md', 'markdown']
const MAX_TEXT_BYTES: number = 1048576

function extOf(path: string): string {
  const name = path.substring(path.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  if (dot <= 0) {
    return ''
  }
  return name.substring(dot + 1).toLowerCase()
}

function kindOf(path: string): PreviewKind {
  const ext = extOf(path)
  for (const item of WEB_EXTS) {
    if (item === ext) {
      return PreviewKind.WEB
    }
  }
  for (const item of IMAGE_EXTS) {
    if (item === ext) {
      return PreviewKind.IMAGE
    }
  }
  for (const item of MD_EXTS) {
    if (item === ext) {
      return PreviewKind.MARKDOWN
    }
  }
  return PreviewKind.TEXT
}

/**
 * Full-screen preview for files dsh creates or mentions in chat.
 *
 * HTML/SVG render in an embedded Web component (file:// from the app
 * sandbox), images in an Image, Markdown through the chat renderer, and
 * everything else as capped monospace text. Mounted per open through
 * bindContentCover; @Watch re-opens it if the cover component is reused
 * for a different file.
 */
@Component
export struct FileViewer {
  @Prop @Watch('onSourceChange') filePath: string = ''
  @Prop fileName: string = ''
  @State kind: PreviewKind = PreviewKind.TEXT
  @State text: string = ''
  @State truncated: boolean = false
  @State failed: string = ''
  onClose: () => void = () => {}
  private controller: webview.WebviewController = new webview.WebviewController()

  aboutToAppear(): void {
    this.open()
  }

  onSourceChange(): void {
    this.open()
  }

  private open(): void {
    this.failed = ''
    this.text = ''
    this.truncated = false
    try {
      if (this.filePath.length === 0) {
        this.failed = '没有可打开的文件路径。'
        return
      }
      if (!fs.accessSync(this.filePath)) {
        // Name the actual path: the usual cause is an external directory whose
        // grant lapsed, not a deleted file, and the user cannot tell those
        // apart from a vague message.
        this.failed = `找不到该文件：${this.filePath}\n外部目录的访问授权可能已失效，重新绑定项目目录后可恢复。`
        return
      }
      this.kind = kindOf(this.filePath)
      if (this.kind === PreviewKind.TEXT || this.kind === PreviewKind.MARKDOWN) {
        const size = fs.statSync(this.filePath).size
        this.truncated = size > MAX_TEXT_BYTES
        this.text = fs.readTextSync(this.filePath, { length: MAX_TEXT_BYTES })
      }
    } catch (error) {
      this.failed = `无法读取文件：${(error as Error).message}`
    }
  }

  private fileUrl(): string {
    return `file://${this.filePath}`
  }

  build() {
    Column() {
      Row() {
        Button('关闭')
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.onClose())

        Text(this.fileName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12, right: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      Divider().color($r('app.color.divider'))

      if (this.failed.length > 0) {
        Column({ space: 8 }) {
          Text(this.failed)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Text(this.filePath)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_tertiary'))
            .copyOption(CopyOptions.LocalDevice)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 32, right: 32 })
      } else if (this.kind === PreviewKind.WEB) {
        Web({ src: this.fileUrl(), controller: this.controller })
          .fileAccess(true)
          .domStorageAccess(true)
          .layoutWeight(1)
          .width('100%')
      } else if (this.kind === PreviewKind.IMAGE) {
        Scroll() {
          Image(this.fileUrl())
            .objectFit(ImageFit.Contain)
            .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
      } else if (this.kind === PreviewKind.MARKDOWN) {
        Scroll() {
          Column({ space: 6 }) {
            if (this.truncated) {
              Text('文件超过 1MB，仅显示开头部分。')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
            }
            MdText({ raw: this.text })
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .constraintSize({ minHeight: '100%' })
          .width('100%')
          .padding(12)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      } else {
        Scroll() {
          Column({ space: 6 }) {
            if (this.truncated) {
              Text('文件超过 1MB，仅显示开头部分。')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
            }
            Text(this.text)
              .fontSize(13)
              .fontFamily('monospace')
              .lineHeight(19)
              .fontColor($r('app.color.text_primary'))
              .copyOption(CopyOptions.LocalDevice)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .constraintSize({ minHeight: '100%' })
          .width('100%')
          .padding(12)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }
}
