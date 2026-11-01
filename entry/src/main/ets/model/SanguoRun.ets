import { fileIo as fs } from '@kit.CoreFileKit'

/**
 * The run's own arithmetic: how many turns, how many departures, and how far
 * the world has drifted.
 *
 * Why this reads files the projection already covers: `.sanguo/save.json` and
 * `.sanguo/history.jsonl` are the engine's durable record, and both are designed
 * to be read by humans (the save is auditable by construction, the history is
 * append-only). `life.json` is a per-turn projection of the same facts, so a
 * board that only reads the projection can show "now" but never "how you got
 * here" — which is exactly the question a deviation-driven game is about.
 *
 * Read-only. The engine stays the only writer.
 */

/** One resolved turn, as the history log records it. */
export interface DriftPoint {
  /** 0-based position in the capped series, for bar spacing. */
  index: number
  drift: number
  /** True when this turn's choice departed from the recorded history. */
  departure: boolean
}

/** Everything the board needs that the projection does not carry. */
export class RunStats {
  present: boolean = false
  /** Turns the clock has advanced. */
  turns: number = 0
  /** Choices actually made at moral nodes. */
  choices: number = 0
  /** Departures from the recorded history, as the engine counted them. */
  deviations: number = 0
  age: number = 0
  drift: number = 0
  titles: string[] = []
  /** Oldest-first drift values, capped; empty when nothing has been played. */
  series: DriftPoint[] = []

  /** True once there is something to plot — one point is not a trail. */
  hasTrail(): boolean {
    return this.series.length > 1
  }

  /** Highest drift reached this run, for scaling the trail. */
  peak(): number {
    let high = 0
    for (const point of this.series) {
      if (point.drift > high) {
        high = point.drift
      }
    }
    return high
  }
}

/** Cap on plotted turns: a 200-turn run must not become 200 bars. */
const MAX_POINTS = 28

function readText(path: string): string {
  try {
    if (!fs.accessSync(path)) {
      return ''
    }
    return fs.readTextSync(path)
  } catch (error) {
    return ''
  }
}

function asRecord(value: Object | undefined): Record<string, Object> | undefined {
  if (value === undefined || value === null) {
    return undefined
  }
  if (Array.isArray(value)) {
    return undefined
  }
  return value as Record<string, Object>
}

function numberOf(source: Record<string, Object> | undefined, key: string): number {
  if (source === undefined) {
    return 0
  }
  const raw = source[key]
  return typeof raw === 'number' && !Number.isNaN(raw) ? raw as number : 0
}

function stringsOf(source: Record<string, Object> | undefined, key: string): string[] {
  const out: string[] = []
  if (source === undefined) {
    return out
  }
  const raw = source[key]
  if (!Array.isArray(raw)) {
    return out
  }
  for (const entry of raw as Object[]) {
    if (typeof entry === 'string') {
      out.push(entry as string)
    }
  }
  return out
}

/**
 * Parse one `history.jsonl` body into a drift series.
 *
 * Records without a numeric `drift` are skipped rather than defaulted: a zero
 * would read as "the world forgot", which is a different claim from "this
 * record does not price drift".
 */
function parseTrail(text: string): DriftPoint[] {
  const points: DriftPoint[] = []
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (trimmed.length === 0) {
      continue
    }
    let record: Record<string, Object>
    try {
      record = JSON.parse(trimmed) as Record<string, Object>
    } catch (error) {
      // A torn final line is expected after a crash; the save is authoritative.
      continue
    }
    const raw = record['drift']
    if (typeof raw !== 'number' || Number.isNaN(raw as number)) {
      continue
    }
    const point: DriftPoint = {
      index: points.length,
      drift: raw as number,
      departure: record['departure'] === true
    }
    points.push(point)
  }
  if (points.length <= MAX_POINTS) {
    return points
  }
  const tail = points.slice(points.length - MAX_POINTS)
  const reindexed: DriftPoint[] = []
  for (const point of tail) {
    reindexed.push({ index: reindexed.length, drift: point.drift, departure: point.departure })
  }
  return reindexed
}

/** Read one workspace's run statistics. Never throws; absence is a state. */
export function readRunStats(workspace: string): RunStats {
  const stats = new RunStats()
  if (workspace.length === 0) {
    return stats
  }

  const saveText = readText(`${workspace}/.sanguo/save.json`)
  if (saveText.length === 0) {
    return stats
  }
  let save: Record<string, Object>
  try {
    save = JSON.parse(saveText) as Record<string, Object>
  } catch (error) {
    // A corrupt save is the engine's problem to report, not the board's to
    // guess at: show the projection and leave the counters at zero.
    return stats
  }

  stats.present = true
  stats.age = numberOf(save, 'age')
  stats.drift = numberOf(save, 'drift')
  const counters = asRecord(save['counters'])
  stats.turns = numberOf(counters, 'turnsPlayed')
  stats.choices = numberOf(counters, 'choicesMade')
  stats.deviations = numberOf(counters, 'deviations')
  const player = asRecord(save['player'])
  stats.titles = stringsOf(player, 'titles')

  stats.series = parseTrail(readText(`${workspace}/.sanguo/history.jsonl`))
  return stats
}
