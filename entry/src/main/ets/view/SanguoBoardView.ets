import { ATTRIBUTE_LABELS, BoardState, PersonView, SceneOption, effectsSummary } from '../model/SanguoBoard'
import { DriftPoint, RunStats } from '../model/SanguoRun'

/** Plot height for the drift trail; also the scale for one bar. */
const TRAIL_HEIGHT = 24

/**
 * The board: a native surface for one run of the Sanguo engine.
 *
 * Design notes worth keeping, because each one is a decision rather than taste:
 *
 * · PAPER, NOT GLASS. The rest of the app is a neutral tool surface. This is a
 *   chronicle, so it uses warm paper and ink instead of the app's cool greys —
 *   a distinct surface is how the user knows they are in a different mode. The
 *   palette still comes from tokens, so dark mode works without a second file.
 *
 * · NUMBERS ARE TABULAR. Troops, gold, grain and the three counters all change
 *   under the player's eyes. Proportional digits make them jitter; tabular
 *   figures keep the column still.
 *
 * · THE PRICE IS VISIBLE BEFORE THE CLICK. Every option shows its declared
 *   effects. This is the whole reason the engine returns them: a choice whose
 *   cost is hidden is a guess, not a decision.
 *
 * · NO OPTIMISTIC UPDATE. Tapping an option sends a prompt and waits. The board
 *   re-reads the projection when the turn settles. Painting the new state first
 *   would mean two sources of truth for the same number, and the engine would
 *   eventually disagree with the screen.
 *
 * · EMPTY IS A STATE, NOT AN ERROR. No projection file means no run yet, so the
 *   board offers to start one instead of rendering zeros.
 */
@Component
export struct SanguoBoard {
  @Prop board: BoardState
  @Prop running: boolean
  @Prop busy: boolean
  /**
   * Counters and the drift trail, read from the save and the append-only
   * history rather than from the projection. The projection answers "where am
   * I"; this answers "how far have I walked off the road" — which is the whole
   * premise of the mode.
   */
  @Prop run: RunStats = new RunStats()
  onChoose: (option: SceneOption) => void = () => {}
  onFreeAction: () => void = () => {}
  onWait: () => void = () => {}
  onStart: () => void = () => {}

  /** One stat with a label and a tabular figure. */
  @Builder
  stat(label: string, value: string) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.ink_faint'))
      Text(value)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink'))
        .fontFeature('"tnum" 1')
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  /** A 0-100 counter with a thin rule under it. Reads as a gauge, not a chart. */
  @Builder
  meter(label: string, value: number) {
    Column({ space: 6 }) {
      Row() {
        Text(label)
          .fontSize(12)
          .fontColor($r('app.color.ink_soft'))
        Blank()
        Text(`${value}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .fontFeature('"tnum" 1')
      }
      .width('100%')

      // A 3vp track: heavy enough to read at a glance, light enough not to
      // compete with the scene text below it.
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(3)
          .borderRadius(2)
          .backgroundColor($r('app.color.rule'))
        Row()
          .width(`${Math.min(100, Math.max(0, value))}%`)
          .height(3)
          .borderRadius(2)
          .backgroundColor($r('app.color.seal'))
      }
      .width('100%')
      .height(3)
    }
    .layoutWeight(1)
  }

  /**
   * The drift trail: one bar per resolved turn, oldest first.
   *
   * A departure is drawn in the seal colour, everything else in the rule
   * colour, so the trail reads as "where I left the road" rather than as a
   * generic sparkline. Height is the absolute drift, not the delta — drift is
   * cumulative and decays slowly, and a delta plot would hide exactly the
   * ratchet the player needs to see.
   */
  @Builder
  trail() {
    Row({ space: 2 }) {
      ForEach(this.run.series, (point: DriftPoint) => {
        Column() {
          Row()
            .width('100%')
            .height(this.barHeight(point.drift))
            .borderRadius(1)
            .backgroundColor(point.departure ? $r('app.color.seal') : $r('app.color.rule'))
        }
        .height(TRAIL_HEIGHT)
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }, (point: DriftPoint) => `${point.index}.${point.drift}.${point.departure}`)
    }
    .width('100%')
    .height(TRAIL_HEIGHT)
    .alignItems(VerticalAlign.Bottom)
  }

  /** Bar height for one drift value: a 3vp floor keeps a zero readable. */
  private barHeight(drift: number): number {
    const clamped = Math.min(100, Math.max(0, drift))
    return 3 + Math.round((clamped / 100) * (TRAIL_HEIGHT - 3))
  }

  /** One tappable option: label, declared price, and the note. */
  @Builder
  optionRow(option: SceneOption) {
    Column({ space: 4 }) {
      Text(option.label)
        .fontSize(15)
        .fontColor($r('app.color.ink'))
        .width('100%')
        .textAlign(TextAlign.Start)
      if (effectsSummary(option.effects).length > 0) {
        Text(effectsSummary(option.effects))
          .fontSize(11)
          .fontColor($r('app.color.bronze'))
          .fontFeature('"tnum" 1')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      if (option.note.length > 0) {
        Text(option.note)
          .fontSize(11)
          .fontColor($r('app.color.ink_faint'))
          .lineHeight(16)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
    .backgroundColor($r('app.color.paper_raised'))
    .borderRadius(10)
    .border({ width: 1, color: $r('app.color.rule') })
    // 44vp minimum hit area: the whole card is the target, not the text.
    .constraintSize({ minHeight: 44 })
    .enabled(!this.busy)
    .opacity(this.busy ? 0.5 : 1)
    .onClick(() => this.onChoose(option))
  }

  /** Empty state: no run in this workspace yet. */
  @Builder
  emptyState() {
    Column({ space: 14 }) {
      Text('还没有开局')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink'))
      Text('从 161 年涿县出生开始，走完刘备这一生。\n你可以照史载走，也可以随时离开它。')
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('app.color.ink_soft'))
        .textAlign(TextAlign.Center)
      Button('开始这一局')
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.seal'))
        .fontColor(Color.White)
        .fontSize(15)
        .enabled(!this.busy)
        .opacity(this.busy ? 0.5 : 1)
        .onClick(() => this.onStart())
    }
    .width('100%')
    .padding({ top: 64, left: 32, right: 32 })
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      if (!this.board.present) {
        this.emptyState()
      } else {
        Scroll() {
          Column({ space: 0 }) {
            // ---- header: when, where, who -------------------------------
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text(this.board.when)
                  .fontSize(12)
                  .fontColor($r('app.color.ink_faint'))
                  .fontFeature('"tnum" 1')
                Text('·')
                  .fontSize(12)
                  .fontColor($r('app.color.ink_faint'))
                Text(`${this.board.age}岁`)
                  .fontSize(12)
                  .fontColor($r('app.color.ink_faint'))
                  .fontFeature('"tnum" 1')
                Blank()
                Text(`势 ${this.board.world.drift}`)
                  .fontSize(12)
                  .fontColor(this.board.world.drift > 35 ? $r('app.color.seal') : $r('app.color.ink_soft'))
                  .fontFeature('"tnum" 1')
              }
              .width('100%')

              Text(this.board.act)
                .fontSize(19)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.ink'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 18, bottom: 14 })

            Divider().color($r('app.color.rule')).margin({ left: 20, right: 20 })

            // ---- the three counters -------------------------------------
            Column({ space: 12 }) {
              Row({ space: 16 }) {
                this.meter('名望', this.board.counters.fame)
                this.meter('信义', this.board.counters.trust)
                this.meter('人才', this.board.counters.talent)
              }
              .width('100%')

              Row({ space: 16 }) {
                this.stat('兵', `${this.board.resources.troops}`)
                this.stat('金', `${this.board.resources.gold}`)
                this.stat('粮', `${this.board.resources.grain}`)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 14, bottom: 16 })

            // ---- 势: the price of leaving the road -----------------------
            // The number alone reads as one more stat. The trail is what makes
            // it legible: same data, but it answers "how far did I walk off"
            // instead of "where am I standing".
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Text('势')
                  .fontSize(11)
                  .fontColor($r('app.color.ink_faint'))
                Text(this.board.world.mood)
                  .fontSize(11)
                  .fontColor(this.board.world.drift > 35 ? $r('app.color.seal') : $r('app.color.ink_soft'))
                Blank()
                Text(this.run.deviations > 0 ? `偏离 ${this.run.deviations} 次` : '未离史载')
                  .fontSize(11)
                  .fontColor(this.run.deviations > 0 ? $r('app.color.seal') : $r('app.color.ink_faint'))
                  .fontFeature('"tnum" 1')
              }
              .width('100%')

              // Inline rather than `run.hasTrail()`: @Prop deep-copies the
              // object, and a copied instance must not be relied on to keep
              // its prototype methods.
              if (this.run.series.length > 1) {
                this.trail()
              }

              Text(`已行 ${this.run.turns} 手 · 抉择 ${this.run.choices} 次`)
                .fontSize(10)
                .fontColor($r('app.color.ink_faint'))
                .fontFeature('"tnum" 1')
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 0, bottom: 16 })
            .alignItems(HorizontalAlign.Start)

            // ---- the scene ----------------------------------------------
            if (!this.board.scene.finished) {
              Column({ space: 14 }) {
                Text(this.board.scene.title)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.ink'))
                  .width('100%')
                  .textAlign(TextAlign.Start)

                Text(this.board.scene.narration)
                  .fontSize(14)
                  .lineHeight(23)
                  .fontColor($r('app.color.ink_soft'))
                  .width('100%')
                  .textAlign(TextAlign.Start)

                if (this.board.scene.kind === 'ability') {
                  Text(
                    `此局需判定：${ATTRIBUTE_LABELS.get(this.board.scene.attribute) ?? this.board.scene.attribute}` +
                    `　难度 ${this.board.scene.difficulty}`
                  )
                    .fontSize(11)
                    .fontColor($r('app.color.bronze'))
                    .fontFeature('"tnum" 1')
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }

                if (this.board.scene.options.length > 0) {
                  Column({ space: 8 }) {
                    ForEach(this.board.scene.options, (option: SceneOption) => {
                      this.optionRow(option)
                    }, (option: SceneOption) => option.id)
                  }
                  .width('100%')
                } else if (this.board.scene.kind === 'ability') {
                  Button('去做')
                    .width('100%')
                    .height(44)
                    .backgroundColor($r('app.color.seal'))
                    .fontColor(Color.White)
                    .enabled(!this.busy)
                    .opacity(this.busy ? 0.5 : 1)
                    .onClick(() => this.onFreeAction())
                }
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 4, bottom: 16 })
            }

            // ---- the act is spent ---------------------------------------
            // Not an ending: the engine reports that this act has no scenes
            // left, and time can still pass. Leaving the middle of the screen
            // empty here read as a bug rather than as a lull.
            if (this.board.scene.finished) {
              Column({ space: 8 }) {
                Text('本幕已尽')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.ink'))
                  .width('100%')
                  .textAlign(TextAlign.Start)
                Text('让时间继续走，或者直接说你想做什么。')
                  .fontSize(13)
                  .lineHeight(20)
                  .fontColor($r('app.color.ink_soft'))
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 4, bottom: 16 })
              .alignItems(HorizontalAlign.Start)
            }

            // ---- people -------------------------------------------------
            if (this.board.people.length > 0) {
              Column({ space: 8 }) {
                Text('相关的人')
                  .fontSize(11)
                  .fontColor($r('app.color.ink_faint'))
                  .width('100%')
                  .textAlign(TextAlign.Start)
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.board.people, (person: PersonView) => {
                    Row({ space: 5 }) {
                      Text(person.name)
                        .fontSize(12)
                        .fontColor($r('app.color.ink'))
                      Text(person.stance)
                        .fontSize(11)
                        .fontColor($r('app.color.ink_faint'))
                    }
                    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                    .margin({ right: 6, bottom: 6 })
                    .backgroundColor($r('app.color.paper_sunken'))
                    .borderRadius(6)
                  }, (person: PersonView) => person.name)
                }
                .width('100%')
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 4, bottom: 16 })
            }

            Divider().color($r('app.color.rule')).margin({ left: 20, right: 20 })

            // ---- wait ---------------------------------------------------
            Row({ space: 8 }) {
              Button('等一等')
                .layoutWeight(1)
                .height(40)
                .backgroundColor($r('app.color.paper_sunken'))
                .fontColor($r('app.color.ink'))
                .fontSize(13)
                .enabled(!this.busy)
                .opacity(this.busy ? 0.5 : 1)
                .onClick(() => this.onWait())
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 14, bottom: 24 })
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
      }

      // A turn in flight owns the screen: the engine has not decided yet, so
      // there is nothing honest to show but a quiet line.
      if (this.running) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.seal'))
          Text('正在推演…')
            .fontSize(12)
            .fontColor($r('app.color.ink_faint'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 8, bottom: 12 })
        .backgroundColor($r('app.color.paper'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.paper'))
  }
}
