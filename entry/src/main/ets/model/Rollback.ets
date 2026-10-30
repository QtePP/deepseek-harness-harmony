import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'

/**
 * File snapshots for turn rollback.
 *
 * The agent writes through the embedded Node runtime, so ArkTS cannot
 * intercept a write before it lands. What it *can* do is capture the file
 * after a turn settles and keep that copy until the turn is rolled back.
 * Rolling back a turn therefore means restoring every path the turn touched
 * to the bytes it had when the turn began:
 *
 *   - a file that existed before the turn gets its old bytes back;
 *   - a file the turn created did not exist before, so it is deleted.
 *
 * Snapshots live under `<filesDir>/snapshots/<turnKey>/` and are pruned once
 * a turn is committed, so the cost is bounded by the turns still on screen.
 */

/** What a turn did to one path. */
export enum FileChange {
  /** Existed before the turn; `before` holds its bytes. */
  MODIFIED = 'modified',
  /** Did not exist before the turn; rolling back deletes it. */
  CREATED = 'created',
  /** Existed before and no longer does; rolling back recreates it. */
  DELETED = 'deleted'
}

/** One path a turn touched, with enough state to undo it. */
export class FileTouch {
  path: string = ''
  change: FileChange = FileChange.MODIFIED
  /** Snapshot file holding the pre-turn bytes; '' when the file was created. */
  before: string = ''
  /** True when the pre-turn content was not text (binary snapshot kept). */
  binary: boolean = false

  constructor(path: string, change: FileChange) {
    this.path = path
    this.change = change
  }
}

/** Outcome of one rollback, surfaced to the user instead of silently swallowed. */
export class RollbackReport {
  restored: number = 0
  deleted: number = 0
  failed: number = 0
  /** Human lines for the paths that could not be rolled back. */
  problems: string[] = []
}

function dirnameOf(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash > 0 ? path.substring(0, slash) : ''
}

function basenameOf(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash >= 0 ? path.substring(slash + 1) : path
}

/**
 * Snapshot store. One instance per app shell; `root` is the sandbox snapshots
 * directory. Every method tolerates a missing directory rather than throwing,
 * because a rollback that half-works must still report what it did.
 */
export class SnapshotStore {
  private root: string = ''

  init(filesDir: string): void {
    this.root = `${filesDir}/snapshots`
    if (!fs.accessSync(this.root)) {
      try {
        fs.mkdirSync(this.root)
      } catch (error) {
        this.root = ''
      }
    }
  }

  ready(): boolean {
    return this.root.length > 0
  }

  /** Directory holding one turn's snapshots; created on first use. */
  private turnDir(turnKey: string): string {
    const dir = `${this.root}/${turnKey}`
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir)
    }
    return dir
  }

  /**
   * Capture the current state of `path` before the turn changes it. Called
   * when the turn is opened, so it must be cheap and must never throw: a file
   * we cannot read is recorded as untouched rather than aborting the turn.
   */
  capture(turnKey: string, path: string): FileTouch | null {
    if (!this.ready() || path.length === 0) {
      return null
    }
    let exists = false
    try {
      exists = fs.accessSync(path)
    } catch (error) {
      exists = false
    }
    if (!exists) {
      return new FileTouch(path, FileChange.CREATED)
    }
    const touch = new FileTouch(path, FileChange.MODIFIED)
    try {
      const dir = this.turnDir(turnKey)
      const dest = `${dir}/${util.generateRandomUUID(true)}.snap`
      fs.copyFileSync(path, dest)
      touch.before = dest
      touch.binary = !this.looksTextual(path)
    } catch (error) {
      // Without a snapshot we cannot promise a rollback for this path; report
      // it as a problem instead of pretending the turn is reversible.
      touch.change = FileChange.MODIFIED
      touch.before = ''
    }
    return touch
  }

  /** Cheap text sniff: a NUL byte in the first block means binary. */
  private looksTextual(path: string): boolean {
    try {
      const sample = fs.readTextSync(path)
      return sample.indexOf('\u0000') < 0
    } catch (error) {
      return false
    }
  }

  /**
   * Undo one touch. `MODIFIED` and `DELETED` restore the snapshot; `CREATED`
   * removes the file. Missing snapshot for a modified file is a failure, not a
   * silent success — the user asked for their bytes back.
   */
  revert(touch: FileTouch, report: RollbackReport): void {
    try {
      if (touch.change === FileChange.CREATED) {
        if (fs.accessSync(touch.path)) {
          fs.unlinkSync(touch.path)
          report.deleted++
        }
        return
      }
      if (touch.before.length === 0) {
        report.failed++
        report.problems.push(`${basenameOf(touch.path)}：没有回退前的快照`)
        return
      }
      const parent = dirnameOf(touch.path)
      if (parent.length > 0 && !fs.accessSync(parent)) {
        fs.mkdirSync(parent, true)
      }
      fs.copyFileSync(touch.before, touch.path)
      report.restored++
    } catch (error) {
      report.failed++
      report.problems.push(`${basenameOf(touch.path)}：${(error as Error).message}`)
    }
  }

  /** Drop a turn's snapshots once it can no longer be rolled back. */
  discard(turnKey: string): void {
    if (!this.ready()) {
      return
    }
    const dir = `${this.root}/${turnKey}`
    try {
      if (fs.accessSync(dir)) {
        fs.rmdirSync(dir)
      }
    } catch (error) {
      // A leftover directory only costs disk; never block the UI over it.
    }
  }
}

/**
 * Paths a tool call claims to write. Read-only tools return nothing, so a
 * rollback never touches a file the turn only inspected. The key set mirrors
 * the argument names dsh tools use across profiles.
 */
const WRITE_PATH_KEYS: string[] = [
  'path', 'file_path', 'filePath', 'target', 'targetPath', 'filename'
]

/** Tools whose arguments name a file they wrote. */
export function isWriteTool(name: string): boolean {
  const n = name.toLowerCase()
  if (n.indexOf('write') >= 0 || n.indexOf('edit') >= 0 || n.indexOf('create') >= 0) {
    return true
  }
  if (n.indexOf('delete') >= 0 || n.indexOf('remove') >= 0 || n.indexOf('mkdir') >= 0) {
    return true
  }
  if (n.indexOf('move') >= 0 || n.indexOf('rename') >= 0 || n.indexOf('copy') >= 0) {
    return true
  }
  return false
}

/**
 * dsh serialises some tool arguments as XML-ish blocks rather than raw
 * strings — a write call arrives as
 * `<path>/data/…/a.txt</path>\n<type>file</type>\n<content>…</content>`.
 * Take the inner text of `<path>` when present, and refuse anything that
 * still looks like markup: a path we cannot trust must not become a snapshot.
 */
function extractPath(value: string): string {
  const open = value.indexOf('<path>')
  if (open >= 0) {
    const close = value.indexOf('</path>', open)
    if (close > open) {
      return value.substring(open + 6, close).trim()
    }
  }
  const trimmed = value.trim()
  return trimmed.indexOf('<') >= 0 ? '' : trimmed
}

/**
 * Absolute-or-workspace-relative paths a write call touched. Relative paths
 * are resolved against the turn's cwd, which is what the tool itself did.
 */
export function writePathsOf(name: string, raw: Record<string, Object> | undefined,
  cwd: string): string[] {
  if (!isWriteTool(name) || raw === undefined) {
    return []
  }
  const out: string[] = []
  for (const key of WRITE_PATH_KEYS) {
    const value = raw[key]
    if (value === undefined || typeof value !== 'string') {
      continue
    }
    const inner = extractPath(value as string)
    if (inner.length === 0) {
      continue
    }
    const full = inner.startsWith('/') || cwd.length === 0 ? inner : `${cwd}/${inner}`
    if (out.indexOf(full) < 0) {
      out.push(full)
    }
  }
  return out
}
