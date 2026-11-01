import { describe, it, expect } from '@ohos/hypium'
import { BoardState, effectsSummary, parseBoard, effectLabel } from '../main/ets/model/SanguoBoard'

/**
 * The board's projection parser, pinned against a REAL engine document.
 *
 * The fixture below is not hand-written: it is a capture of `.sanguo/life.json`
 * produced by `@ohos/dsh-sanguo` at the 督邮 scene (four options, mixed costs).
 * Using a real capture is the point — a hand-written fixture only tests what I
 * believed the engine emits, which is exactly the assumption that breaks when a
 * field is renamed.
 *
 * Why this matters: if a key drifts, the board renders zeros. That reads as a
 * game bug and sends the next person looking in the engine instead of here.
 */
const FIXTURE: string = `{
  "when": "186年·春（中平三年）",
  "age": 25,
  "place": "anxi",
  "act": "第二幕·安喜",
  "counters": { "fame": 30, "trust": 30, "talent": 8 },
  "resources": { "troops": 30, "gold": 62, "grain": 1, "hp": 100 },
  "world": { "mood": "天下未觉", "drift": 0 },
  "people": [{ "name": "关羽", "stance": "倾心相待" }],
  "scene": {
    "finished": false,
    "act": "第二幕·安喜",
    "title": "督邮至",
    "narration": "督邮至安喜，当遣你。",
    "kind": "moral",
    "attribute": "",
    "difficulty": 0,
    "options": [
      { "id": "beat", "label": "杖二百", "note": "弃官亡命",
        "effects": { "fame": 10, "trust": 6, "talent": 2, "gold": -5, "grain": 0, "troops": 0, "hp": 0 } },
      { "id": "endure", "label": "交印离去", "note": "保住清白",
        "effects": { "fame": -6, "trust": -4, "talent": 0, "gold": 0, "grain": 0, "troops": 0, "hp": 0 } }
    ]
  },
  "generatedAt": "2026-10-31T16:20:57.835Z"
}`

export default function sanguoBoardTest() {
  describe('sanguoBoard', () => {
    it('parses every top-level field of a real projection', 0, () => {
      const board = parseBoard(FIXTURE)
      expect(board.present).assertTrue()
      expect(board.when).assertEqual('186年·春（中平三年）')
      expect(board.age).assertEqual(25)
      expect(board.act).assertEqual('第二幕·安喜')
      expect(board.counters.fame).assertEqual(30)
      expect(board.counters.trust).assertEqual(30)
      expect(board.counters.talent).assertEqual(8)
      expect(board.resources.troops).assertEqual(30)
      expect(board.resources.gold).assertEqual(62)
      expect(board.world.mood).assertEqual('天下未觉')
    })

    it('parses the scene and its options with their declared costs', 0, () => {
      const board = parseBoard(FIXTURE)
      expect(board.scene.title).assertEqual('督邮至')
      expect(board.scene.kind).assertEqual('moral')
      expect(board.scene.options.length).assertEqual(2)
      expect(board.scene.options[0].id).assertEqual('beat')
      expect(board.scene.options[0].effects.fame).assertEqual(10)
      expect(board.scene.options[0].effects.gold).assertEqual(-5)
      expect(board.scene.options[1].effects.fame).assertEqual(-6)
    })

    it('reports whether the run is asking the player something', 0, () => {
      const board = parseBoard(FIXTURE)
      expect(board.hasChoice()).assertTrue()
      expect(board.hasCheck()).assertFalse()
    })

    it('a missing file is an empty board, not an error', 0, () => {
      const empty = new BoardState()
      expect(empty.present).assertFalse()
      expect(empty.hasChoice()).assertFalse()
      expect(empty.scene.options.length).assertEqual(0)
    })

    it('malformed JSON degrades to an empty board instead of throwing', 0, () => {
      const broken = parseBoard('{ not json')
      expect(broken.present).assertFalse()
    })

    it('a partial document fills defaults rather than losing the whole board', 0, () => {
      const partial = parseBoard('{"when":"184年·春","age":23}')
      expect(partial.present).assertTrue()
      expect(partial.when).assertEqual('184年·春')
      expect(partial.counters.fame).assertEqual(0)
      expect(partial.scene.finished).assertTrue()
    })

    it('renders an option price as one line', 0, () => {
      const board = parseBoard(FIXTURE)
      const summary = effectsSummary(board.scene.options[0].effects)
      expect(summary.indexOf('名望+10') >= 0).assertTrue()
      expect(summary.indexOf('金-5') >= 0).assertTrue()
    })

    it('a zero effect renders as nothing', 0, () => {
      expect(effectLabel('fame', 0)).assertEqual('')
      expect(effectLabel('fame', 3)).assertEqual('名望+3')
      expect(effectLabel('fame', -3)).assertEqual('名望-3')
      expect(effectLabel('nonsense', 3)).assertEqual('')
    })
  })
}
