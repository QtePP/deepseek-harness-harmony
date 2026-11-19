import { ChannelStatus, ChannelKind, ClipboardChannel, InteropEnvelope, LanChannel, ProbeResult,
  WebSocketChannel, INTEROP_PORT, localLanAddress, localPeerName, makeEnvelope, probeChannels,
  probeNearLink, probeDataShare } from '../common/Interop'

/**
 * The interop panel: what this device can talk to, and one working channel.
 *
 * The layout follows one rule — a channel the user cannot use right now still
 * appears, greyed, with the reason. Hiding it would leave them wondering
 * whether the app can do this at all; and the reason is usually actionable
 * ("pull the phone closer", "same account", "type the address").
 */
@Component
export struct InteropSheet {
  @State channels: ChannelStatus[] = probeChannels()
  @State selfAddress: string = ''
  @State peerAddress: string = ''
  @State peer: string = ''
  @State log: InteropEnvelope[] = []
  @State draft: string = ''
  @State hosting: boolean = false
  @State busy: boolean = false
  @State hint: string = ''
  @State relayUrl: string = ''
  @State nearLinkResult: ProbeResult | null = null
  @State dataShareResult: ProbeResult | null = null
  @State probing: string = ''
  private lan: LanChannel | null = null
  private ws: WebSocketChannel | null = null
  private me: string = localPeerName()

  aboutToAppear(): void {
    this.lan = new LanChannel({
      onPeer: (who: string) => {
        this.peer = who
        this.hosting = who.length > 0 && this.hosting
      },
      onMessage: (envelope: InteropEnvelope) => {
        this.log = [envelope].concat(this.log).slice(0, 30)
      },
      onError: (reason: string) => {
        this.hint = reason
      }
    })
    void localLanAddress().then((address: string) => {
      this.selfAddress = address.length > 0 ? `${address}:${INTEROP_PORT}` : ''
    })
  }

  aboutToDisappear(): void {
    void this.lan?.close()
    void this.ws?.close()
  }

  private async startHost(): Promise<void> {
    if (this.lan === null || this.busy) {
      return
    }
    this.busy = true
    try {
      await this.lan.host()
      this.hosting = true
      this.hint = this.selfAddress.length > 0
        ? `把 ${this.selfAddress} 告诉对方，让他在下面点「加入」`
        : '房间已开，但没取到本机地址——请确认连着 WiFi'
    } catch (error) {
      this.hint = `开房失败：${(error as Error).message}`
    }
    this.busy = false
  }

  private async join(): Promise<void> {
    if (this.lan === null || this.busy || this.peerAddress.trim().length === 0) {
      return
    }
    this.busy = true
    try {
      await this.lan.join(this.peerAddress.trim())
      this.hint = ''
    } catch (error) {
      this.hint = `连不上：${(error as Error).message}`
    }
    this.busy = false
  }

  private async send(): Promise<void> {
    const text = this.draft.trim()
    if (text.length === 0) {
      return
    }
    const envelope = makeEnvelope(this.me, text, Date.now())
    try {
      if (this.lan !== null && this.lan.connected()) {
        await this.lan.send(envelope)
      } else if (this.ws !== null) {
        await this.ws.send(envelope)
      } else {
        this.hint = '还没有连接——先开房间或加入'
        return
      }
      this.log = [envelope].concat(this.log).slice(0, 30)
      this.draft = ''
      this.hint = ''
    } catch (error) {
      this.hint = `发送失败：${(error as Error).message}`
    }
  }

  private async connectRelay(): Promise<void> {
    const url = this.relayUrl.trim()
    if (url.length === 0 || this.busy) {
      return
    }
    this.busy = true
    this.ws = new WebSocketChannel({
      onPeer: (who: string) => {
        this.peer = who
      },
      onMessage: (envelope: InteropEnvelope) => {
        this.log = [envelope].concat(this.log).slice(0, 30)
      },
      onError: (reason: string) => {
        this.hint = `中继错误：${reason}`
      }
    })
    try {
      await this.ws.connect(url)
    } catch (error) {
      this.hint = `连不上中继：${(error as Error).message}`
      this.ws = null
    }
    this.busy = false
  }

  @Builder
  card(status: ChannelStatus) {
    Row({ space: 10 }) {
      Circle({ width: 8, height: 8 })
        .fill(status.available ? '#3FBF74' : $r('app.color.divider'))
      Column({ space: 2 }) {
        Text(status.label)
          .fontSize(13)
          .fontColor(status.available ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
        Text(status.note)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 6, bottom: 6 })
  }

  build() {
    Column({ space: 10 }) {
      Text('互联')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Text('这一版真做通的是「同一 WiFi 直连」与「中继」两条线；其余通道先把可用性照实列出来。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      // -- 房间 --
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(this.selfAddress.length > 0 ? `本机 ${this.selfAddress}` : '本机地址取不到')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Button(this.hosting ? '房间已开' : '开房间')
            .fontSize(12)
            .height(30)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.hosting && !this.busy)
            .onClick(() => {
              void this.startHost()
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: this.peerAddress, placeholder: '对方地址，如 192.168.1.5' })
            .fontSize(12)
            .height(34)
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface'))
            .onChange((value: string) => {
              this.peerAddress = value
            })
          Button('加入')
            .fontSize(12)
            .height(30)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.busy)
            .onClick(() => {
              void this.join()
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: this.relayUrl, placeholder: '中继地址 wss://…（可留空）' })
            .fontSize(12)
            .height(34)
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface'))
            .onChange((value: string) => {
              this.relayUrl = value
            })
          Button('连中继')
            .fontSize(12)
            .height(30)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.busy)
            .onClick(() => {
              void this.connectRelay()
            })
        }
        .width('100%')

        if (this.peer.length > 0) {
          Text(`已连接：${this.peer}`)
            .fontSize(12)
            .fontColor('#3FBF74')
            .width('100%')
        }
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
      }
      .width('100%')
      .padding(10)
      .backgroundColor($r('app.color.surface_muted'))
      .borderRadius(10)

      // -- 收发 --
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: '发一句话给对方' })
          .fontSize(12)
          .height(34)
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .onChange((value: string) => {
            this.draft = value
          })
          .onSubmit(() => {
            void this.send()
          })
        Button('发送')
          .fontSize(12)
          .height(30)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            void this.send()
          })
      }
      .width('100%')

      if (this.log.length > 0) {
        Column({ space: 4 }) {
          ForEach(this.log, (item: InteropEnvelope) => {
            Row({ space: 6 }) {
              Text(item.from === this.me ? '我' : item.from)
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
                .width(52)
              Text(item.text)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (item: InteropEnvelope) => item.id)
        }
        .width('100%')
        .padding(10)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(10)
      }

      // -- 剪贴板：不需要连接的那条路 --
      Row({ space: 8 }) {
        Button('复制本机地址')
          .fontSize(12)
          .height(30)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .enabled(this.selfAddress.length > 0)
          .onClick(() => {
            void ClipboardChannel.copy(this.selfAddress).then(() => {
              this.hint = '地址已复制，发给你想连的人'
            })
          })
        Button('从剪贴板粘贴')
          .fontSize(12)
          .height(30)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            void ClipboardChannel.paste().then((text: string) => {
              this.peerAddress = text.trim()
            })
          })
      }
      .width('100%')

      // -- 能力清单 --
      Column({ space: 2 }) {
        ForEach(this.channels, (status: ChannelStatus) => {
          this.card(status)
        }, (status: ChannelStatus) => status.kind as string)
      }
      .width('100%')
      .padding(10)
      .backgroundColor($r('app.color.surface_muted'))
      .borderRadius(10)

      // 实测：canIUse 说「系统声明了这项能力」，不等于「这个应用真能打开它」。
      // 唯一诚实的分辨办法是真的调一次，把返回码原样说出来。
      Column({ space: 6 }) {
        Text('实测两条「说了没有」的通道')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Row({ space: 8 }) {
          Button(this.probing === 'nearlink' ? '试星闪…' : '试星闪')
            .fontSize(12)
            .height(30)
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.text_primary'))
            .enabled(this.probing.length === 0)
            .onClick(() => {
              this.probing = 'nearlink'
              void probeNearLink().then((result: ProbeResult) => {
                this.nearLinkResult = result
                this.probing = ''
              })
            })
          Button(this.probing === 'datashare' ? '试数据代理…' : '试数据代理')
            .fontSize(12)
            .height(30)
            .layoutWeight(1)
            .backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.text_primary'))
            .enabled(this.probing.length === 0)
            .onClick(() => {
              this.probing = 'datashare'
              void probeDataShare('com.qtepp.taharness').then((result: ProbeResult) => {
                this.dataShareResult = result
                this.probing = ''
              })
            })
        }
        .width('100%')

        if (this.nearLinkResult !== null) {
          Text(`星闪：${(this.nearLinkResult as ProbeResult).ok ? '可用' : '不可用'} — ${(this.nearLinkResult as ProbeResult).detail}`)
            .fontSize(11)
            .fontColor((this.nearLinkResult as ProbeResult).ok ? '#3FBF74' : $r('app.color.text_tertiary'))
            .width('100%')
        }
        if (this.dataShareResult !== null) {
          Text(`数据代理：${(this.dataShareResult as ProbeResult).ok ? '可用' : '不可用'} — ${(this.dataShareResult as ProbeResult).detail}`)
            .fontSize(11)
            .fontColor((this.dataShareResult as ProbeResult).ok ? '#3FBF74' : $r('app.color.text_tertiary'))
            .width('100%')
        }
        Text('星闪只建端口不配对；数据代理只读我们自己的共享配置。两条都不写数据、不改设置。')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .width('100%')
      .padding(10)
      .backgroundColor($r('app.color.surface_muted'))
      .borderRadius(10)

      Text('蓝牙要双方都装本应用并配对，比 WiFi 直连没有任何优势；等有明确场景再做。')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }
}
