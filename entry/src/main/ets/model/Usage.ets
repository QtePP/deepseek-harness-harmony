import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'

/** One day of usage: how many tokens the turns added, and how many turns. */
export interface UsageDay {
  /** `YYYY-MM-DD` in local time; the key, and what the ledger sorts on. */
  day: string
  tokens: number
  turns: number
}

/** How many days the ledger keeps. Older rows are dropped on write. */
export const USAGE_RETENTION_DAYS: number = 60

/** `YYYY-MM-DD` for a Date, in local time (not UTC — a day is what the user lived). */
export function dayKey(when: Date): string {
  const month = when.getMonth() + 1
  const day = when.getDate()
  return `${when.getFullYear()}-${month < 10 ? '0' : ''}${month}-${day < 10 ? '0' : ''}${day}`
}

/**
 * Add one turn's tokens to the ledger.
 *
 * Pure so it can be tested without preferences: it returns a new array, keeps
 * one row per day, and never mutates the input. A non-positive delta is
 * ignored — the context note reports a delta only when it is a real increase,
 * and a zero would otherwise create an empty row for a day with no usage.
 */
export function mergeUsage(rows: UsageDay[], day: string, tokens: number): UsageDay[] {
  const out: UsageDay[] = []
  let found = false
  for (const row of rows) {
    if (row.day === day) {
      out.push({ day: day, tokens: row.tokens + (tokens > 0 ? tokens : 0), turns: row.turns + 1 })
      found = true
    } else {
      out.push(row)
    }
  }
  if (!found) {
    out.push({ day: day, tokens: tokens > 0 ? tokens : 0, turns: 1 })
  }
  out.sort((a: UsageDay, b: UsageDay) => a.day < b.day ? 1 : (a.day > b.day ? -1 : 0))
  return out.slice(0, USAGE_RETENTION_DAYS)
}

/** Tokens summed over the newest `days` rows. */
export function usageTotal(rows: UsageDay[], days: number): number {
  let total = 0
  const limit = Math.min(days, rows.length)
  for (let index = 0; index < limit; index++) {
    total += rows[index].tokens
  }
  return total
}

/** `1234` → `1.2k`; the same compaction the context note uses. */
export function compactCount(value: number): string {
  if (value >= 1000000) {
    return `${(value / 1000000).toFixed(1)}M`
  }
  if (value >= 1000) {
    return `${(value / 1000).toFixed(1)}k`
  }
  return `${value}`
}

/**
 * The ledger itself: one JSON blob in preferences.
 *
 * Deliberately not tied to a session: the question "how much did I use today"
 * is asked across conversations, and a per-session ledger would answer a
 * question nobody asks on a phone.
 */
export class UsageStore {
  static readonly STORE: string = 'dsh_usage'
  static readonly KEY: string = 'ledger'

  private store: preferences.Preferences | null = null

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: UsageStore.STORE })
    } catch (error) {
      this.store = null
    }
  }

  rows(): UsageDay[] {
    if (this.store === null) {
      return []
    }
    const raw = this.store.getSync(UsageStore.KEY, '') as string
    if (raw.length === 0) {
      return []
    }
    try {
      const parsed = JSON.parse(raw) as UsageDay[]
      const out: UsageDay[] = []
      for (const row of parsed) {
        if (typeof row.day === 'string' && typeof row.tokens === 'number') {
          out.push({
            day: row.day,
            tokens: row.tokens,
            turns: typeof row.turns === 'number' ? row.turns : 0
          })
        }
      }
      return out
    } catch (error) {
      return []
    }
  }

  /** Record one settled turn; callers pass the delta reported by the runtime. */
  record(tokens: number, when: Date = new Date()): void {
    if (this.store === null) {
      return
    }
    const merged = mergeUsage(this.rows(), dayKey(when), tokens)
    this.store.putSync(UsageStore.KEY, JSON.stringify(merged))
    this.store.flush()
  }

  today(): number {
    const key = dayKey(new Date())
    for (const row of this.rows()) {
      if (row.day === key) {
        return row.tokens
      }
    }
    return 0
  }

  week(): number {
    return usageTotal(this.rows(), 7)
  }

  /** 「今天 +1.2k · 近 7 天 +8.4k」 for the settings row. */
  summary(): string {
    const today = this.today()
    const week = this.week()
    if (week === 0) {
      return '还没有记录'
    }
    return `今天 +${compactCount(today)} · 近 7 天 +${compactCount(week)}`
  }
}
