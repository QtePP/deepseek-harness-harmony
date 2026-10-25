import { BootPhase } from '../host/NodeHost'

/** Splash / failure surface shown until the runtime answers. */
@Component
export struct BootView {
  @Prop phase: BootPhase = BootPhase.IDLE
  @Prop detail: string = ''
  @Prop diagnostics: string = ''
  onRetry: () => void = () => {}
  onShowDiagnostics: () => void = () => {}

  private isFailure(): boolean {
    return this.phase === BootPhase.FAILED
  }

  private label(): string {
    switch (this.phase) {
      case BootPhase.EXTRACTING:
        return '正在准备运行时'
      case BootPhase.STARTING:
        return '正在启动 Node'
      case BootPhase.WAITING:
        return '正在连接 dsh'
      case BootPhase.READY:
        return '已就绪'
      case BootPhase.FAILED:
        return '启动失败'
      default:
        return '准备中'
    }
  }

  build() {
    Column({ space: 16 }) {
      Text('dsh')
        .fontSize(44)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.brand'))

      Text('DeepSeek Harness · HarmonyOS')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))

      if (this.isFailure()) {
        Text(this.label())
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 24 })

        Scroll() {
          Text(this.detail)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .constraintSize({ maxHeight: 160 })
        .width('86%')
        .padding(12)
        .backgroundColor($r('app.color.surface_muted'))
        .borderRadius(12)

        Row({ space: 12 }) {
          Button('重试')
            .onClick(() => this.onRetry())
          Button('诊断信息')
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => this.onShowDiagnostics())
        }
        .margin({ top: 8 })
      } else {
        LoadingProgress()
          .width(48)
          .height(48)
          .color($r('app.color.brand'))
          .margin({ top: 24 })

        Text(this.label())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)

        Text(this.detail)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })
      }

      Blank()

      Text('后端运行在本机应用进程内，不依赖电脑')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.background'))
  }
}
