import { fileIo as fs } from '@kit.CoreFileKit'

/**
 * The board's view of one run of the Sanguo engine.
 *
 * Everything here is a READ of `.sanguo/life.json`, which the engine rewrites on
 * every turn. The board never invents state and never writes the file: the
 * engine is the referee, and a second writer would be a second source of truth.
 * The only thing this side does is display, and send the player's choice back
 * through the same chat prompt path everything else uses.
 *
 * A missing file is a normal state, not an error: it means no run has started in
 * this workspace yet, and the board shows an empty state instead of zeros.
 */

/** One declared option at a moral node. */
export interface SceneOption {
  id: string
  label: string
  note: string
  /** Declared effects, so the board can show the price before the click. */
  effects: SceneEffects
}

/** Effects as the engine writes them: all seven keys always present. */
export interface SceneEffects {
  fame: number
  trust: number
  talent: number
  gold: number
  grain: number
  troops: number
  hp: number
}

/** The pending scene: what the player is being asked right now. */
export interface SceneView {
  finished: boolean
  act: string
  title: string
  narration: string
  /** 'moral' (pick an option) or 'ability' (free action, engine rolls). */
  kind: string
  attribute: string
  difficulty: number
  options: SceneOption[]
}

/** One person the player has met, with the engine's derived stance. */
export interface PersonView {
  name: string
  stance: string
}

/** The three counters that compound, plus the world's reading of the player. */
export interface BoardCounters {
  fame: number
  trust: number
  talent: number
}

export interface BoardResources {
  troops: number
  gold: number
  grain: number
  hp: number
}

export interface BoardWorld {
  mood: string
  drift: number
}

/** One complete read of the projection file. */
export class BoardState {
  present: boolean = false
  when: string = ''
  age: number = 0
  place: string = ''
  act: string = ''
  counters: BoardCounters = { fame: 0, trust: 0, talent: 0 }
  resources: BoardResources = { troops: 0, gold: 0, grain: 0, hp: 0 }
  world: BoardWorld = { mood: '', drift: 0 }
  people: PersonView[] = []
  scene: SceneView = {
    finished: true, act: '', title: '', narration: '', kind: '', attribute: '', difficulty: 0, options: []
  }
  /** Epoch ms of the projection write; 0 when absent. Used for staleness. */
  generatedAt: number = 0

  /** True when there is a run and it is asking the player something. */
  hasChoice(): boolean {
    return this.present && !this.scene.finished && this.scene.options.length > 0
  }

  /** True when the run exists but the current scene is a free-action check. */
  hasCheck(): boolean {
    return this.present && !this.scene.finished && this.scene.kind === 'ability'
  }
}

/** Path of the projection for one workspace. Mirrors the engine's SAVE_DIR. */
export function boardPath(workspace: string): string {
  return `${workspace}/.sanguo/life.json`
}

/**
 * Whether this workspace is a Sanguo workspace at all — including one where no
 * run has started yet.
 *
 * This exists to break a deadlock: the board's empty state is what offers
 * "开始这一局", but the control that opens the board must not depend on a run
 * already existing. So availability is "looks like a sanguo workspace", which is
 * true when the engine has ever written here (`.sanguo/`) or when the pack's
 * `agent.json` declares the sanguo-life agent.
 *
 * Cheap: two `accessSync` calls and at most one small file read.
 */
export function boardAvailable(workspace: string): boolean {
  if (workspace.length === 0) {
    return false
  }
  try {
    if (fs.accessSync(`${workspace}/.sanguo`)) {
      return true
    }
  } catch (error) {
    // fall through to the agent.json probe
  }
  try {
    const manifest = `${workspace}/agent.json`
    if (!fs.accessSync(manifest)) {
      return false
    }
    const text = fs.readTextSync(manifest)
    return text.includes('sanguo-life') || text.includes('汉末人生')
  } catch (error) {
    return false
  }
}

/** Read a numeric field defensively: a hand-edited file must not crash the board. */
function num(source: Record<string, Object> | undefined, key: string): number {
  if (source === undefined) {
    return 0
  }
  const raw = source[key]
  return typeof raw === 'number' && !Number.isNaN(raw) ? raw as number : 0
}

/** Read a string field defensively. */
function str(source: Record<string, Object> | undefined, key: string): string {
  if (source === undefined) {
    return ''
  }
  const raw = source[key]
  return typeof raw === 'string' ? raw as string : ''
}

/**
 * Parse one projection document.
 *
 * Deliberately total: every field has a default, and an unrecognised shape
 * yields `present: false` rather than throwing. A board that crashes on a
 * half-written file is worse than a board that shows "还没开局".
 */
export function parseBoard(raw: string): BoardState {
  const state = new BoardState()
  let doc: Record<string, Object>
  try {
    doc = JSON.parse(raw) as Record<string, Object>
  } catch (error) {
    return state
  }
  if (doc === null || doc === undefined) {
    return state
  }

  state.present = true
  state.when = str(doc, 'when')
  state.age = num(doc, 'age')
  state.place = str(doc, 'place')
  state.act = str(doc, 'act')

  const counters = doc['counters'] as Record<string, Object> | undefined
  state.counters = {
    fame: num(counters, 'fame'),
    trust: num(counters, 'trust'),
    talent: num(counters, 'talent')
  }

  const resources = doc['resources'] as Record<string, Object> | undefined
  state.resources = {
    troops: num(resources, 'troops'),
    gold: num(resources, 'gold'),
    grain: num(resources, 'grain'),
    hp: num(resources, 'hp')
  }

  const world = doc['world'] as Record<string, Object> | undefined
  state.world = { mood: str(world, 'mood'), drift: num(world, 'drift') }

  const people = doc['people']
  if (Array.isArray(people)) {
    const rows: PersonView[] = []
    for (const entry of people as Record<string, Object>[]) {
      const name = str(entry, 'name')
      if (name.length === 0) {
        continue
      }
      rows.push({ name: name, stance: str(entry, 'stance') })
    }
    state.people = rows
  }

  const scene = doc['scene'] as Record<string, Object> | undefined
  if (scene !== undefined) {
    const options: SceneOption[] = []
    const rawOptions = scene['options']
    if (Array.isArray(rawOptions)) {
      for (const entry of rawOptions as Record<string, Object>[]) {
        const id = str(entry, 'id')
        if (id.length === 0) {
          continue
        }
        const effects = entry['effects'] as Record<string, Object> | undefined
        options.push({
          id: id,
          label: str(entry, 'label'),
          note: str(entry, 'note'),
          effects: {
            fame: num(effects, 'fame'),
            trust: num(effects, 'trust'),
            talent: num(effects, 'talent'),
            gold: num(effects, 'gold'),
            grain: num(effects, 'grain'),
            troops: num(effects, 'troops'),
            hp: num(effects, 'hp')
          }
        })
      }
    }
    state.scene = {
      finished: scene['finished'] === true,
      act: str(scene, 'act'),
      title: str(scene, 'title'),
      narration: str(scene, 'narration'),
      kind: str(scene, 'kind'),
      attribute: str(scene, 'attribute'),
      difficulty: num(scene, 'difficulty'),
      options: options
    }
  }

  const generated = doc['generatedAt']
  if (typeof generated === 'string') {
    const parsed = Date.parse(generated as string)
    state.generatedAt = Number.isNaN(parsed) ? 0 : parsed
  }

  return state
}

/**
 * Read the board for one workspace.
 *
 * Synchronous on purpose: the caller is a UI refresh triggered by a turn
 * settling, the file is a couple of kilobytes, and an async hop here would
 * introduce a frame where the board shows the previous turn's numbers.
 */
export function readBoard(workspace: string): BoardState {
  const path = boardPath(workspace)
  try {
    if (!fs.accessSync(path)) {
      return new BoardState()
    }
    return parseBoard(fs.readTextSync(path))
  } catch (error) {
    return new BoardState()
  }
}

/**
 * Display label for the five attributes, matching the engine's vocabulary.
 *
 * A Map rather than an object literal: ArkTS rejects untyped object literals
 * against `Record<...>` (arkts-no-untyped-obj-literals), and a Map keeps the
 * same lookup shape at the call site.
 */
export const ATTRIBUTE_LABELS: Map<string, string> = new Map<string, string>([
  ['wu', '武'],
  ['tong', '统'],
  ['zhi', '智'],
  ['zheng', '政'],
  ['mei', '魅']
])

/** Display label for one effect key. Same Map rationale as ATTRIBUTE_LABELS. */
export const EFFECT_LABELS: Map<string, string> = new Map<string, string>([
  ['fame', '名望'],
  ['trust', '信义'],
  ['talent', '人才'],
  ['gold', '金'],
  ['grain', '粮'],
  ['troops', '兵'],
  ['hp', '身']
])

/** Human label for one effect delta, or '' when it is zero. */
export function effectLabel(key: string, value: number): string {
  if (value === 0) {
    return ''
  }
  const label = EFFECT_LABELS.get(key)
  if (label === undefined) {
    return ''
  }
  return `${label}${value > 0 ? '+' : ''}${value}`
}

/** Compact "名望+3 信义+2" summary of one option's declared price. */
export function effectsSummary(effects: SceneEffects): string {
  const parts: string[] = []
  parts.push(effectLabel('fame', effects.fame))
  parts.push(effectLabel('trust', effects.trust))
  parts.push(effectLabel('talent', effects.talent))
  parts.push(effectLabel('gold', effects.gold))
  parts.push(effectLabel('grain', effects.grain))
  parts.push(effectLabel('troops', effects.troops))
  parts.push(effectLabel('hp', effects.hp))
  const kept: string[] = []
  for (const part of parts) {
    if (part.length > 0) {
      kept.push(part)
    }
  }
  return kept.join('　')
}
