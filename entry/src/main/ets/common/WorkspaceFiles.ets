import { fileIo as fs } from '@kit.CoreFileKit'

/**
 * A flat, bounded index of the workspace for `@` references.
 *
 * The composer needs to answer "which files could this be" on every keystroke,
 * which rules out walking the tree per keypress: this walks once, caps the
 * result, and the caller reuses the list for a few seconds. Depth and count are
 * both bounded because the workspace is agent-written — nothing stops a run
 * from creating thousands of files, and a picker that stalls on them is worse
 * than one that shows the first three hundred.
 *
 * Dot entries and `node_modules` are skipped: they are never what the user
 * means to reference, and they are where the file count explodes.
 */

const MAX_FILES = 300
const MAX_DEPTH = 3
const SKIP_DIRS: string[] = ['node_modules', 'oh_modules', '.git', '.hvigor', 'build']

/** Paths relative to `root`, files only, sorted by depth then name. */
export function listWorkspaceFiles(root: string): string[] {
  const out: string[] = []
  if (root.length === 0) {
    return out
  }
  try {
    if (!fs.accessSync(root)) {
      return out
    }
  } catch (error) {
    return out
  }
  walk(root, '', 0, out)
  return out
}

function walk(root: string, prefix: string, depth: number, out: string[]): void {
  if (depth > MAX_DEPTH || out.length >= MAX_FILES) {
    return
  }
  let names: string[] = []
  try {
    names = fs.listFileSync(root)
  } catch (error) {
    return
  }
  const dirs: string[] = []
  for (const name of names) {
    if (out.length >= MAX_FILES) {
      return
    }
    if (name.length === 0 || name.startsWith('.')) {
      continue
    }
    const path = `${root}/${name}`
    let stat: fs.Stat | null = null
    try {
      stat = fs.statSync(path)
    } catch (error) {
      continue
    }
    if (stat.isDirectory()) {
      if (SKIP_DIRS.indexOf(name) < 0) {
        dirs.push(name)
      }
      continue
    }
    out.push(prefix.length > 0 ? `${prefix}/${name}` : name)
  }
  for (const name of dirs) {
    if (out.length >= MAX_FILES) {
      return
    }
    walk(`${root}/${name}`, prefix.length > 0 ? `${prefix}/${name}` : name, depth + 1, out)
  }
}

/** Files whose relative path contains `query`, case-insensitively, capped. */
export function matchWorkspaceFiles(files: string[], query: string, limit: number = 8): string[] {
  const out: string[] = []
  const needle = query.toLowerCase()
  for (const file of files) {
    if (needle.length > 0 && file.toLowerCase().indexOf(needle) < 0) {
      continue
    }
    out.push(file)
    if (out.length >= limit) {
      break
    }
  }
  return out
}
