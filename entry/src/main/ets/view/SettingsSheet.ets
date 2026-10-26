import { PluginRow } from '../model/PluginCatalog'
import { AppConfig } from '../common/AppConfig'

/** Settings sheet: credentials, model route, capability toggles, diagnostics. */
@Component
export struct SettingsSheet {
  @State apiKey: string = ''
  @State model: string = ''
  @State profile: string = 'sdk'
  @State permissionMode: string = 'workspace-write'
  @State showDiagnostics: boolean = false
  @Prop initialKey: string = ''
  @Prop initialModel: string = ''
  @Prop initialProfile: string = 'sdk'
  @Prop initialPermission: string = 'workspace-write'
  @Prop diagnostics: string = ''
  @Prop pluginRows: PluginRow[] = []
  onSave: (key: string, model: string) => void = () => {}
  onProfileChange: (profile: string, permissionMode: string) => void = () => {}
  onRefreshDiagnostics: () => void = () => {}
  onResetPayload: () => void = () => {}
  onTogglePlugin: (id: string, enabled: boolean) => void = () => {}

  aboutToAppear(): void {
    this.apiKey = this.initialKey
    this.model = this.initialModel
    this.profile = this.initialProfile === 'acp' ? 'acp' : 'sdk'
    this.permissionMode = AppConfig.normalizePermissionMode(this.initialPermission)
  }

  private permissionHint(mode: string): string {
    if (mode === AppConfig.PERMISSION_READONLY) {
      return '只读：写入先被沙箱拒绝，智能体申请升级后弹审批'
    }
    if (mode === AppConfig.PERMISSION_DANGER) {
      return '宽松：完全访问，不再弹任何审批'
    }
    return '平衡：工作区内直接读写，越区升级弹审批（默认）'
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .width('100%')

        Column({ space: 6 }) {
          Text('DeepSeek API Key').fontSize(12).fontColor($r('app.color.text_secondary'))
          TextInput({ text: this.apiKey, placeholder: 'sk-...' })
            .type(InputType.Password)
            .fontSize(14)
            .height(44)
            .onChange((value: string) => {
              this.apiKey = value
            })
          Text('仅保存在本机应用沙箱内').fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 6 }) {
          Text('模型').fontSize(12).fontColor($r('app.color.text_secondary'))
          TextInput({ text: this.model, placeholder: 'deepseek-v4-flash' })
            .fontSize(14)
            .height(44)
            .onChange((value: string) => {
              this.model = value
            })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 6 }) {
          Text('对话协议（实验）').fontSize(12).fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Button('SDK（默认）')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.profile === 'sdk' ? $r('app.color.brand') : $r('app.color.surface_muted'))
              .fontColor(this.profile === 'sdk' ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.profile = 'sdk'
                this.onProfileChange(this.profile, this.permissionMode)
              })
            Button('ACP（流式/审批/取消）')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.profile === 'acp' ? $r('app.color.brand') : $r('app.color.surface_muted'))
              .fontColor(this.profile === 'acp' ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.profile = 'acp'
                this.onProfileChange(this.profile, this.permissionMode)
              })
          }
          .width('100%')

          Text('权限模式（参考 dsh 预设）').fontSize(12).fontColor($r('app.color.text_secondary'))

          Row({ space: 8 }) {
            Button('只读')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.permissionMode === AppConfig.PERMISSION_READONLY ?
                $r('app.color.brand') : $r('app.color.surface_muted'))
              .fontColor(this.permissionMode === AppConfig.PERMISSION_READONLY ?
                Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.permissionMode = AppConfig.PERMISSION_READONLY
                this.onProfileChange(this.profile, this.permissionMode)
              })
            Button('平衡')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.permissionMode === AppConfig.PERMISSION_WORKSPACE ?
                $r('app.color.brand') : $r('app.color.surface_muted'))
              .fontColor(this.permissionMode === AppConfig.PERMISSION_WORKSPACE ?
                Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.permissionMode = AppConfig.PERMISSION_WORKSPACE
                this.onProfileChange(this.profile, this.permissionMode)
              })
            Button('宽松')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.permissionMode === AppConfig.PERMISSION_DANGER ?
                $r('app.color.brand') : $r('app.color.surface_muted'))
              .fontColor(this.permissionMode === AppConfig.PERMISSION_DANGER ?
                Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.permissionMode = AppConfig.PERMISSION_DANGER
                this.onProfileChange(this.profile, this.permissionMode)
              })
          }
          .width('100%')

          Text(this.permissionHint(this.permissionMode))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))

          Text('协议与权限档位由启动期环境变量决定：切换后需彻底退出并重新打开应用才会生效（Node 每进程仅启动一次）；档位在会话创建时固化，重启后仅新会话生效。ACP 会话的服务端 id 与 SDK 会话互不通用。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Row({ space: 10 }) {
          Button('保存')
            .layoutWeight(1)
            .onClick(() => this.onSave(this.apiKey, this.model))
          Button('诊断')
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => {
              this.showDiagnostics = !this.showDiagnostics
              if (this.showDiagnostics) {
                this.onRefreshDiagnostics()
              }
            })
        }
        .width('100%')

        if (this.showDiagnostics) {
          Scroll() {
            Text(this.diagnostics)
              .fontSize(11)
              .fontFamily('monospace')
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .constraintSize({ maxHeight: 240 })
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.code_background'))
          .borderRadius(10)

          Button('重建运行时载荷（下次启动生效）')
            .width('100%')
            .fontSize(13)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => this.onResetPayload())
        }

        Divider().color($r('app.color.divider')).width('100%')

        Column({ space: 6 }) {
          Text('dsh 能力开关').fontSize(12).fontColor($r('app.color.text_secondary'))
          ForEach(this.pluginRows, (row: PluginRow) => {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(row.label)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                Text(row.description)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (row.locked) {
                Text('平台受限')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
              } else {
                Toggle({ type: ToggleType.Switch, isOn: row.enabled })
                  .selectedColor($r('app.color.brand'))
                  .onChange((isOn: boolean) => {
                    this.onTogglePlugin(row.id, isOn)
                  })
              }
            }
            .width('100%')
          }, (row: PluginRow) => `${row.id}.${row.enabled}`)
          Text('修改能力开关后，需彻底退出并重新打开应用才会生效（Node 每进程仅启动一次）。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }
}
