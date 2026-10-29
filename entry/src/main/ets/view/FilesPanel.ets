import { fileIo as fs } from '@kit.CoreFileKit'

/** One visible row of the flattened workspace tree. */
interface FileRow {
  name: string
  path: string
  isDir: boolean
  depth: number
  expanded: boolean
  sizeLabel: string
}

const MAX_ROWS = 500
const MAX_DEPTH = 4

/** Byte count to a short human label. */
function sizeLabelOf(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`
}

function byName(a: FileRow, b: FileRow): number {
  return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
}

/** One directory level: dirs first, then files; dotfiles skipped. */
function listChildren(dir: string): FileRow[] {
  const dirs: FileRow[] = []
  const files: FileRow[] = []
  let names: string[] = []
  try {
    names = fs.listFileSync(dir)
  } catch (error) {
    return []
  }
  for (const name of names) {
    if (name.length === 0 || name.startsWith('.')) {
      continue
    }
    const path = `${dir}/${name}`
    let stat: fs.Stat | null = null
    try {
      stat = fs.statSync(path)
    } catch (error) {
      continue
    }
    if (stat.isDirectory()) {
      const row: FileRow = { name: name, path: path, isDir: true, depth: 0, expanded: false, sizeLabel: '' }
      dirs.push(row)
    } else {
      const row: FileRow = {
        name: name, path: path, isDir: false, depth: 0, expanded: false,
        sizeLabel: sizeLabelOf(stat.size)
      }
      files.push(row)
    }
  }
  dirs.sort(byName)
  files.sort(byName)
  return dirs.concat(files)
}

/**
 * Project files browser: a tree of the current project's workspace — either
 * its sandbox dir or the user-granted bound directory (both are plain POSIX
 * paths). Dirs expand in place; tapping a file opens the viewer.
 */
@Component
export struct FilesPanel {
  @Prop projectName: string = ''
  @Prop workspacePath: string = ''
  @Prop @Watch('onTick') refreshTick: number = 0
  @State rows: FileRow[] = []
  @State missing: boolean = false
  onOpenFile: (path: string, name: string) => void = () => {}
  private expanded: Set<string> = new Set()

  aboutToAppear(): void {
    this.rescan()
  }

  private onTick(): void {
    this.rescan()
  }

  private rescan(): void {
    const out: FileRow[] = []
    if (this.workspacePath.length === 0) {
      this.missing = true
      this.rows = out
      return
    }
    this.missing = !fs.accessSync(this.workspacePath)
    if (!this.missing) {
      this.scanLevel(this.workspacePath, 0, out)
    }
    this.rows = out
  }

  /** Walk one level; recursion only follows expanded dirs, within the caps. */
  private scanLevel(dir: string, depth: number, out: FileRow[]): void {
    const children = listChildren(dir)
    for (const child of children) {
      if (out.length >= MAX_ROWS) {
        return
      }
      const isExpanded = this.expanded.has(child.path)
      const row: FileRow = {
        name: child.name, path: child.path, isDir: child.isDir, depth: depth,
        expanded: isExpanded, sizeLabel: child.sizeLabel
      }
      out.push(row)
      if (child.isDir && isExpanded && depth < MAX_DEPTH) {
        this.scanLevel(child.path, depth + 1, out)
      }
    }
  }

  private toggle(row: FileRow): void {
    if (this.expanded.has(row.path)) {
      this.expanded.delete(row.path)
    } else {
      this.expanded.add(row.path)
    }
    this.rescan()
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('项目文件')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          Text(`${this.projectName} · ${this.workspacePath}`)
            .fontSize(11)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
          .onClick(() => this.rescan())
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 18, bottom: 10 })

      Divider().color($r('app.color.divider'))

      if (this.missing) {
        Column({ space: 8 }) {
          Text('工作区目录不存在')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text(this.workspacePath)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.rows.length === 0) {
        Column({ space: 8 }) {
          Text('工作区暂无文件')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text('对话中让 dsh 创建的文件会出现在这里')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.rows, (row: FileRow) => {
            ListItem() {
              Row({ space: 6 }) {
                if (row.isDir) {
                  SymbolGlyph($r('sys.symbol.chevron_down'))
                    .fontSize(11)
                    .fontColor([$r('app.color.text_tertiary')])
                    .rotate({ angle: row.expanded ? 90 : 0 })
                    .animation({ duration: 140, curve: Curve.EaseOut })
                } else {
                  Row().width(11)
                }

                SymbolGlyph(row.isDir ? $r('sys.symbol.folder_fill') : $r('sys.symbol.doc_text'))
                  .fontSize(16)
                  .fontColor([row.isDir ? $r('app.color.brand') : $r('app.color.text_secondary')])

                Text(row.name)
                  .fontSize(14)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .fontColor($r('app.color.text_primary'))

                if (!row.isDir && row.sizeLabel.length > 0) {
                  Text(row.sizeLabel)
                    .fontSize(11)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .width('100%')
              .padding({ left: 14 + row.depth * 14, right: 14, top: 9, bottom: 9 })
              .borderRadius(10)
              .onClick(() => {
                if (row.isDir) {
                  this.toggle(row)
                } else {
                  this.onOpenFile(row.path, row.name)
                }
              })
            }
          }, (row: FileRow) => `${row.path}.${row.expanded}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 12 })
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.surface'))
  }
}
