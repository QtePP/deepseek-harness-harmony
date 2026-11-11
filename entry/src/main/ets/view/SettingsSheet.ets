import { PluginRow } from '../model/PluginCatalog'
import { AppConfig } from '../common/AppConfig'
import { THEMES, ThemeOption } from '../common/Theme'

/** Settings sheet: credentials, model route, capability toggles, diagnostics. */
@Component
export struct SettingsSheet {
  /** Accent bound to AppStorage; every theme switch repaints without a restart. */
  @StorageLink('accent') accent: string = '#4D6BFE'

  @State apiKey: string = ''
  @State model: string = ''
  @State profile: string = 'sdk'
  @State permissionMode: string = 'workspace-write'
  @State accentId: string = 'blue'
  @State appearance: string = 'system'
  @State showDiagnostics: boolean = false
  @State showLocked: boolean = false
  @Prop initialKey: string = ''
  @Prop initialModel: string = ''
  @Prop initialProfile: string = 'sdk'
  @Prop initialPermission: string = 'workspace-write'
  @Prop initialAccent: string = 'blue'
  @Prop initialAppearance: string = 'system'
  @Prop diagnostics: string = ''
  @Prop pluginRows: PluginRow[] = []
  onSave: (key: string, model: string) => void = () => {}
  onProfileChange: (profile: string, permissionMode: string) => void = () => {}
  onRefreshDiagnostics: () => void = () => {}
  onResetPayload: () => void = () => {}
  onTogglePlugin: (id: string, enabled: boolean) => void = () => {}
  /** Accent id; the shell persists it and republishes the colour. */
  onAccentChange: (id: string) => void = () => {}
  /** Ask the system for the notification switch (background turn results). */
  onEnableNotifications: () => void = () => {}
  /** 'system' | 'light' | 'dark'; the shell persists and applies it. */
  onAppearanceChange: (mode: string) => void = () => {}

  aboutToAppear(): void {
    this.apiKey = this.initialKey
    this.model = this.initialModel
    this.profile = this.initialProfile === 'acp' ? 'acp' : 'sdk'
    this.permissionMode = AppConfig.normalizePermissionMode(this.initialPermission)
    this.accentId = this.initialAccent
    this.appearance = this.initialAppearance
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

  private togglableRows(): PluginRow[] {
    const out: PluginRow[] = []
    for (const row of this.pluginRows) {
      if (!row.locked) {
        out.push(row)
      }
    }
    return out
  }

  private lockedRows(): PluginRow[] {
    const out: PluginRow[] = []
    for (const row of this.pluginRows) {
      if (row.locked) {
        out.push(row)
      }
    }
    return out
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

        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('后台通知').fontSize(14).fontColor($r('app.color.text_primary'))
              Text('切到后台后，一轮完成 / 出错 / 等待审批时提醒')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('开启')
              .fontSize(12)
              .height(32)
              .backgroundColor($r('app.color.surface_muted'))
              .fontColor($r('app.color.text_primary'))
              .onClick(() => this.onEnableNotifications())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 6 }) {
          Text('外观').fontSize(12).fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Button('跟随系统')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.appearance === 'system' ? this.accent : $r('app.color.surface_muted'))
              .fontColor(this.appearance === 'system' ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.appearance = 'system'
                this.onAppearanceChange('system')
              })
            Button('浅色')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.appearance === 'light' ? this.accent : $r('app.color.surface_muted'))
              .fontColor(this.appearance === 'light' ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.appearance = 'light'
                this.onAppearanceChange('light')
              })
            Button('深色')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.appearance === 'dark' ? this.accent : $r('app.color.surface_muted'))
              .fontColor(this.appearance === 'dark' ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.appearance = 'dark'
                this.onAppearanceChange('dark')
              })
          }
          .width('100%')
          Text('切换后需重启应用生效（运行中改配色会重建窗口）')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 8 }) {
          Text('主题色').fontSize(12).fontColor($r('app.color.text_secondary'))
          Row({ space: 10 }) {
            ForEach(THEMES, (theme: ThemeOption) => {
              Stack() {
                Circle({ width: 28, height: 28 })
                  .fill(theme.value)
                if (theme.id === this.accentId) {
                  Circle({ width: 34, height: 34 })
                    .fill(Color.Transparent)
                    .stroke(theme.value)
                    .strokeWidth(2)
                }
              }
              .width(36)
              .height(36)
              .accessibilityText(`主题色：${theme.label}`)
              .onClick(() => {
                this.accentId = theme.id
                this.onAccentChange(theme.id)
              })
            }, (theme: ThemeOption) => theme.id)
          }
          .width('100%')
          Text('只改强调色：按钮、链接、选中行与上下文环；背景与气泡保持中性色。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 6 }) {
          Text('对话协议（实验）').fontSize(12).fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Button('SDK（默认）')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.profile === 'sdk' ? this.accent : $r('app.color.surface_muted'))
              .fontColor(this.profile === 'sdk' ? Color.White : $r('app.color.text_primary'))
              .onClick(() => {
                this.profile = 'sdk'
                this.onProfileChange(this.profile, this.permissionMode)
              })
            Button('ACP（流式/审批/取消）')
              .layoutWeight(1)
              .fontSize(13)
              .backgroundColor(this.profile === 'acp' ? this.accent : $r('app.color.surface_muted'))
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
                this.accent : $r('app.color.surface_muted'))
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
                this.accent : $r('app.color.surface_muted'))
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
                this.accent : $r('app.color.surface_muted'))
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
            // Follows the accent like every other primary action; the default
            // system blue was the one control that ignored the theme.
            .backgroundColor(this.accent)
            .fontColor(Color.White)
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
          ForEach(this.togglableRows(), (row: PluginRow) => {
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

              Toggle({ type: ToggleType.Switch, isOn: row.enabled })
                .selectedColor(this.accent)
                .onChange((isOn: boolean) => {
                  this.onTogglePlugin(row.id, isOn)
                })
            }
            .width('100%')
          }, (row: PluginRow) => `${row.id}.${row.enabled}`)

          Row() {
            Text(`平台受限能力（${this.lockedRows().length}）`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Text(this.showLocked ? '收起' : '展开')
              .fontSize(12)
              .fontColor(this.accent)
          }
          .width('100%')
          .padding({ top: 4 })
          .onClick(() => {
            this.showLocked = !this.showLocked
          })

          if (this.showLocked) {
            ForEach(this.lockedRows(), (row: PluginRow) => {
              Column({ space: 2 }) {
                Text(row.label)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Text(row.description)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ top: 4 })
            }, (row: PluginRow) => row.id)
          }

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
