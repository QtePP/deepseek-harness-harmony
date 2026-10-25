import { SessionSummary } from '../model/ChatModel'
import { ProjectStore, ProjectSummary } from '../model/ProjectModel'

/**
 * Session rail: a horizontal project strip on top, the session list below.
 * Shown inline on wide windows and inside a sheet on phones. Projects are
 * conversation categories, each with its own workspace; long-press a chip
 * to rename or delete it (the default project is fixed).
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
  onSelect: (id: string) => void = () => {}
  onNew: () => void = () => {}
  onSelectProject: (id: string) => void = () => {}
  onNewProject: (name: string) => void = () => {}
  onRenameProject: (id: string, name: string) => void = () => {}
  onDeleteProject: (id: string) => void = () => {}
  private renamingId: string = ''

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

  /** Long-press menu: rename / delete / cancel; the default project is fixed. */
  private manageProject(project: ProjectSummary): void {
    if (project.id === ProjectStore.DEFAULT_ID) {
      return
    }
    AlertDialog.show({
      message: `项目「${project.name}」`,
      buttons: [
        { value: '重命名', action: () => this.startRename(project.id, project.name) },
        { value: '删除项目', action: () => this.confirmDelete(project) },
        { value: '取消', action: () => {} }
      ]
    })
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

  build() {
    Column({ space: 4 }) {
      if (this.namingMode === '') {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.projects, (project: ProjectSummary) => {
              Text(project.name)
                .fontSize(12)
                .maxLines(1)
                .constraintSize({ maxWidth: 120 })
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .fontColor(this.isCurrentProject(project.id) ? Color.White : $r('app.color.text_primary'))
                .backgroundColor(this.isCurrentProject(project.id)
                  ? $r('app.color.brand')
                  : $r('app.color.surface_muted'))
                .borderRadius(14)
                .onClick(() => this.onSelectProject(project.id))
                .gesture(LongPressGesture().onAction(() => this.manageProject(project)))
            }, (project: ProjectSummary) => project.id)

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
        Button('+')
          .width(28)
          .height(28)
          .fontSize(16)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.onNew())
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 8 })

      List() {
        ForEach(this.sessions, (row: SessionSummary) => {
          ListItem() {
            Column({ space: 2 }) {
              Text(row.title)
                .fontSize(14)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(row.id === this.currentId ? $r('app.color.brand') : $r('app.color.text_primary'))
              Text(this.label(row.updatedAt))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius(10)
            .backgroundColor(row.id === this.currentId ? $r('app.color.surface_selected') : Color.Transparent)
            .onClick(() => this.onSelect(row.id))
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
