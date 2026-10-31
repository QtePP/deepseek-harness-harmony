import { curves } from '@kit.ArkUI'
import { BootPhase } from '../host/NodeHost'

/** Splash / failure surface shown until the runtime answers. */
@Component
export struct BootView {
  @Prop @Watch('onPhaseChanged') phase: BootPhase = BootPhase.IDLE
  @Prop detail: string = ''
  @Prop diagnostics: string = ''
  /** Breathing opacity of the footer attribution. */
  @State tagOpacity: number = 1
  /** Staged entrance: the hero rises in — logo springs, then the title. */
  @State logoScale: number = 0.72
  @State logoOpacity: number = 0
  @State titleOpacity: number = 0
  @State titleRise: number = 16
  @State tagIntro: number = 0
  /** Orb pulse while the runtime is being reached: 0 = bright, 1 = dim. */
  @State orbPhase: number = 0
  private orbTimer: number = -1
  onRetry: () => void = () => {}
  onShowDiagnostics: () => void = () => {}

  aboutToAppear(): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.82) }, () => {
      this.logoScale = 1
      this.logoOpacity = 1
    })
    this.getUIContext().animateTo({ duration: 420, curve: Curve.EaseOut, delay: 140 }, () => {
      this.titleOpacity = 1
      this.titleRise = 0
    })
    this.getUIContext().animateTo({ duration: 420, curve: Curve.EaseOut, delay: 280 }, () => {
      this.tagIntro = 1
    })
    this.getUIContext().animateTo({
      duration: 1600,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate,
      delay: 1000
    }, () => {
      this.tagOpacity = 0.35
    })
    this.syncOrb()
  }

  aboutToDisappear(): void {
    if (this.orbTimer >= 0) {
      clearInterval(this.orbTimer)
      this.orbTimer = -1
    }
  }

  /** Terminal phases stop the pulse; a retry restarts it. */
  onPhaseChanged(): void {
    this.syncOrb()
  }

  /** Pulse the orb only while a non-terminal phase is on screen. */
  private syncOrb(): void {
    const active = !this.isFailure() && this.phase !== BootPhase.READY
    if (active && this.orbTimer < 0) {
      this.orbTimer = setInterval(() => {
        this.orbPhase = this.orbPhase === 0 ? 1 : 0
      }, 620)
    } else if (!active && this.orbTimer >= 0) {
      clearInterval(this.orbTimer)
      this.orbTimer = -1
      this.orbPhase = 0
    }
  }

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
      Image($r('app.media.logo'))
        .width(96)
        .height(96)
        .scale({ x: this.logoScale, y: this.logoScale })
        .opacity(this.logoOpacity)

      Text('TA Harness')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .opacity(this.titleOpacity)
        .translate({ y: this.titleRise })

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
        // The brand bolt inside a soft orb, pulsing while the runtime is
        // reached. A spinner says "wait"; this says "the app is starting", and
        // it keeps the splash consistent with the in-app thinking indicator.
        Stack() {
          Circle()
            .width(56)
            .height(56)
            .fill($r('app.color.surface_muted'))
            .opacity(this.orbPhase === 0 ? 1 : 0.55)
            .animation({ duration: 620, curve: Curve.EaseInOut })

          Image($r('app.media.bolt'))
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.brand'))
            .opacity(this.orbPhase === 0 ? 1 : 0.7)
            .scale({
              x: this.orbPhase === 0 ? 1 : 0.92,
              y: this.orbPhase === 0 ? 1 : 0.92
            })
            .animation({ duration: 620, curve: Curve.EaseInOut })
        }
        .width(56)
        .height(56)
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
        .margin({ bottom: 10 })

      // Attribution sits at the very bottom, not under the title: the hero
      // block should carry the product name alone, and the credit reads as a
      // footer rather than as a subtitle competing with it.
      Text('Powered by DeepSeek Harness')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .opacity(this.tagIntro * this.tagOpacity)
        .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.background'))
  }
}
