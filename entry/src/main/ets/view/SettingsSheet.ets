import { PluginRow } from '../model/PluginCatalog'

/** Settings sheet: credentials, model route, capability toggles, diagnostics. */
@Component
export struct SettingsSheet {
  @State apiKey: string = ''
  @State model: string = ''
  @State showDiagnostics: boolean = false
  @Prop initialKey: string = ''
  @Prop initialModel: string = ''
  @Prop diagnostics: string = ''
  @Prop pluginRows: PluginRow[] = []
  onSave: (key: string, model: string) => void = () => {}
  onRefreshDiagnostics: () => void = () => {}
  onResetPayload: () => void = () => {}
  onTogglePlugin: (id: string, enabled: boolean) => void = () => {}

  aboutToAppear(): void {
    this.apiKey = this.initialKey
    this.model = this.initialModel
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
