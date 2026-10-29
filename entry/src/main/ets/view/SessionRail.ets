import { SessionSummary } from '../model/ChatModel'
import { ProjectStore, ProjectSummary } from '../model/ProjectModel'

/**
 * Session rail: a horizontal project strip on top, the session list below.
 * Shown inline on wide windows and inside a sheet on phones. Projects are
 * conversation categories, each with its own workspace — either a sandbox
 * dir or a user-granted directory (folder icon on the chip); long-press a
 * chip to bind, rename or delete it (the default project is fixed).
 * Long-press a session row for an anchored bubble: rename in place or
 * confirm the destructive delete.
 */
@Component
export struct SessionRail {
  @Prop sessions: SessionSummary[] = []
  @Prop currentId: string = ''
  @Prop projects: ProjectSummary[] = []
  @Prop currentProjectId: string = ProjectStore.DEFAULT_ID
  /** '' shows the strip; 'create' and 'rename' swap it for a naming form. */
  @State namingMode: string = ''
  @State nameDraft: string = ''
  /** Session row whose long-press bubble is open. */
  @State menuSessionId: string = ''
  /** Finger press point (row-relative) where the long-press bubble anchors. */
  @State menuPressX: number = 0
  @State menuPressY: number = 0
  /** Session row swapped for its inline rename form. */
  @State renamingSessionId: string = ''
  @State sessionNameDraft: string = ''
  onSelect: (id: string) => void = () => {}
  onNew: () => void = () => {}
  onDeleteSession: (id: string) => void = () => {}
  onRenameSession: (id: string, title: string) => void = () => {}
  onSelectProject: (id: string) => void = () => {}
  onNewProject: (name: string) => void = () => {}
  onRenameProject: (id: string, name: string) => void = () => {}
  onDeleteProject: (id: string) => void = () => {}
  onBindProjectDir: (id: string) => void = () => {}
  onUnbindProjectDir: (id: string) => void = () => {}
  private renamingId: string = ''
  /** Session row under the finger; drives the pressed scale feedback. */
  @State pressedSessionId: string = ''
  @State newPressed: boolean = false

  private label(at: number): string {
    const date = new Date(at)
    const month = `${date.getMonth() + 1}`.padStart(2, '0')
    const day = `${date.getDate()}`.padStart(2, '0')
    const hour = `${date.getHours()}`.padStart(2, '0')
    const minute = `${date.getMinutes()}`.padStart(2, '0')
    return `${month}-${day} ${hour}:${minute}`
  }

  private isCurrentProject(id: string): boolean {
    return id === this.currentProjectId
  }

  private isBound(project: ProjectSummary): boolean {
    return project.boundPath !== undefined && project.boundPath.length > 0
  }

  private startCreate(): void {
    this.renamingId = ''
    this.nameDraft = ''
    this.namingMode = 'create'
  }

  private startRename(id: string, name: string): void {
    this.renamingId = id
    this.nameDraft = name
    this.namingMode = 'rename'
  }

  private resetNaming(): void {
    this.namingMode = ''
    this.nameDraft = ''
    this.renamingId = ''
  }

  private confirmNaming(): void {
    const name = this.nameDraft.trim()
    if (name.length === 0) {
      return
    }
    if (this.namingMode === 'create') {
      this.onNewProject(name)
    } else if (this.namingMode === 'rename' && this.renamingId.length > 0) {
      this.onRenameProject(this.renamingId, name)
    }
    this.resetNaming()
  }

  /** Long-press menu: bind dir / rename / delete / cancel; the default project is fixed. */
  private manageProject(project: ProjectSummary): void {
    if (project.id === ProjectStore.DEFAULT_ID) {
      return
    }
    const bound = this.isBound(project)
    const message = bound
      ? `项目「${project.name}」\n已绑定目录：${project.boundLabel === undefined ? '' : project.boundLabel}`
      : `项目「${project.name}」\n未绑定用户目录（工作区在应用沙箱内）`
    const buttons: AlertDialogButtonOptions[] = []
    if (bound) {
      buttons.push({ value: '解绑用户目录', action: () => this.onUnbindProjectDir(project.id) })
    } else {
      buttons.push({ value: '绑定用户目录', action: () => this.onBindProjectDir(project.id) })
    }
    buttons.push({ value: '重命名', action: () => this.startRename(project.id, project.name) })
    buttons.push({ value: '删除项目', action: () => this.confirmDelete(project) })
    buttons.push({ value: '取消', action: () => {} })
    AlertDialog.show({ message: message, buttons: buttons })
  }

  private confirmDelete(project: ProjectSummary): void {
    AlertDialog.show({
      message: `删除项目「${project.name}」？\n其中会话将移入「${ProjectStore.DEFAULT_NAME}」，工作区文件保留。`,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        action: () => this.onDeleteProject(project.id)
      },
      cancel: () => {}
    })
  }

  /** Swap one session row for its inline rename form. */
  private startSessionRename(row: SessionSummary): void {
    this.menuSessionId = ''
    this.renamingSessionId = row.id
    this.sessionNameDraft = row.title
  }

  /** Commit the inline rename: empty names are rejected, the form stays open. */
  private confirmSessionRename(): void {
    const name = this.sessionNameDraft.trim()
    if (name.length === 0 || this.renamingSessionId.length === 0) {
      return
    }
    this.onRenameSession(this.renamingSessionId, name)
    this.renamingSessionId = ''
    this.sessionNameDraft = ''
  }

  /**
   * Long-press bubble on a session row: rename (brand), cancel (muted) and
   * confirm delete (red) as three distinct buttons so the destructive path
   * needs an explicit choice.
   */
  @Builder
  sessionMenuPopup(row: SessionSummary) {
    Column({ space: 10 }) {
      Text(`删除会话「${row.title}」？`)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text('本地记录与服务端日志将一并删除，工作区文件保留。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      Row({ space: 8 }) {
        Button('取消')
          .fontSize(12)
          .height(30)
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.menuSessionId = ''
          })
        Button('重命名')
          .fontSize(12)
          .height(30)
          .layoutWeight(1)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => this.startSessionRename(row))
        Button('删除')
          .fontSize(12)
          .height(30)
          .layoutWeight(1)
          .backgroundColor('#C0392B')
          .onClick(() => {
            this.menuSessionId = ''
            this.onDeleteSession(row.id)
          })
      }
      .width('100%')
    }
    .width(280)
    .padding(14)
  }

  build() {
    Column({ space: 4 }) {
      if (this.namingMode === '') {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.projects, (project: ProjectSummary) => {
              Row({ space: 4 }) {
                if (this.isBound(project)) {
                  SymbolGlyph($r('sys.symbol.folder_fill'))
                    .fontSize(12)
                    .fontColor([this.isCurrentProject(project.id) ? Color.White : $r('app.color.brand')])
                }
                Text(project.name)
                  .fontSize(12)
                  .maxLines(1)
                  .constraintSize({ maxWidth: 120 })
                  .fontColor(this.isCurrentProject(project.id) ? Color.White : $r('app.color.text_primary'))
              }
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.isCurrentProject(project.id)
                ? $r('app.color.brand')
                : $r('app.color.surface_muted'))
              .borderRadius(14)
              .onClick(() => this.onSelectProject(project.id))
              .gesture(LongPressGesture().onAction(() => this.manageProject(project)))
            }, (project: ProjectSummary) => `${project.id}.${this.isBound(project)}`)

            Text('+')
              .fontSize(16)
              .padding({ left: 12, right: 12, top: 3, bottom: 5 })
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.surface_muted'))
              .borderRadius(14)
              .onClick(() => this.startCreate())
          }
          .padding({ left: 16, right: 12, top: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      } else {
        Row({ space: 8 }) {
          TextInput({
            text: this.nameDraft,
            placeholder: this.namingMode === 'create' ? '新项目名称' : '项目名称'
          })
            .fontSize(13)
            .height(34)
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface_muted'))
            .borderRadius(10)
            .onChange((value: string) => {
              this.nameDraft = value
            })

          Button('确定')
            .fontSize(13)
            .height(34)
            .backgroundColor($r('app.color.brand'))
            .onClick(() => this.confirmNaming())

          Button('取消')
            .fontSize(13)
            .height(34)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => this.resetNaming())
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 12 })
      }

      Row() {
        Text('会话')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.plus_circle_fill'))
          .fontSize(30)
          .fontColor([$r('app.color.brand')])
          .scale({ x: this.newPressed ? 0.88 : 1, y: this.newPressed ? 0.88 : 1 })
          .animation({ duration: 120, curve: Curve.EaseOut })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.newPressed = true
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.newPressed = false
            }
          })
          .onClick(() => this.onNew())
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 8 })

      List() {
        ForEach(this.sessions, (row: SessionSummary) => {
          ListItem() {
            if (this.renamingSessionId === row.id) {
              Row({ space: 8 }) {
                TextInput({
                  text: this.sessionNameDraft,
                  placeholder: '会话名称'
                })
                  .fontSize(13)
                  .height(34)
                  .layoutWeight(1)
                  .backgroundColor($r('app.color.surface_muted'))
                  .borderRadius(10)
                  .onChange((value: string) => {
                    this.sessionNameDraft = value
                  })

                Button('确定')
                  .fontSize(13)
                  .height(34)
                  .backgroundColor($r('app.color.brand'))
                  .onClick(() => this.confirmSessionRename())

                Button('取消')
                  .fontSize(13)
                  .height(34)
                  .backgroundColor($r('app.color.surface_muted'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick(() => {
                    this.renamingSessionId = ''
                    this.sessionNameDraft = ''
                  })
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 4, bottom: 4 })
            } else {
              Stack() {
                Row({ space: 8 }) {
                  Column()
                    .width(3)
                    .height(30)
                    .borderRadius(2)
                    .backgroundColor(row.id === this.currentId ?
                      $r('app.color.brand') : Color.Transparent)

                  Column({ space: 2 }) {
                    Text(row.title)
                      .fontSize(14)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor($r('app.color.text_primary'))
                    Text(this.label(row.updatedAt))
                      .fontSize(11)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 10, right: 12, top: 10, bottom: 10 })
                .borderRadius(10)
                .backgroundColor(row.id === this.currentId ?
                  $r('app.color.surface_selected') : Color.Transparent)
                .scale({
                  x: this.pressedSessionId === row.id ? 0.98 : 1,
                  y: this.pressedSessionId === row.id ? 0.98 : 1
                })
                .animation({ duration: 120, curve: Curve.EaseOut })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressedSessionId = row.id
                    if (event.touches.length > 0) {
                      this.menuPressX = event.touches[0].x
                      this.menuPressY = event.touches[0].y
                    }
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressedSessionId = ''
                  }
                })
                .onClick(() => this.onSelect(row.id))
                .gesture(LongPressGesture().onAction(() => {
                  this.menuSessionId = row.id
                }))

                Column()
                  .width(1)
                  .height(1)
                  .position({ x: this.menuPressX, y: this.menuPressY })
                  .hitTestBehavior(HitTestMode.None)
                  .bindPopup(this.menuSessionId === row.id, {
                    builder: (): void => {
                      this.sessionMenuPopup(row)
                    },
                    placement: Placement.Bottom,
                    popupColor: $r('app.color.surface'),
                    enableArrow: true,
                    autoCancel: true,
                    onStateChange: (state: PopupStateChangeParam) => {
                      if (!state.isVisible) {
                        this.menuSessionId = ''
                      }
                    }
                  })
              }
              .width('100%')
            }
          }
        }, (row: SessionSummary) => row.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 8, right: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.surface'))
  }
}
