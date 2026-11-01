#!/usr/bin/env node
/**
 * Validate Agent packs under `agents/`.
 *
 * A pack is a workspace that gets copied onto the device as-is, so a typo does
 * not fail a build — it fails silently on the phone (a skill that never loads,
 * a card that renders `—`). This checker mirrors the loaders that actually run
 * in the app, using only what they actually require:
 *
 *   - `dsh-skill-filesystem`: YAML frontmatter with `name` + `description`,
 *     and `name` must match /^[a-z0-9]+(?:-[a-z0-9]+)*$/ (equal to its
 *     directory name, or `skill` lookups by name miss);
 *   - `dsh-agent-instructions`: `AGENTS.md` at the project root, 65536 B budget;
 *   - CardSpec v1: the ten block primitives, `{{path}}` bindings that must
 *     resolve against the card's `bind` document.
 *
 * Missing `bind` data is a warning, not an error: a card is allowed to exist
 * before the agent has written anything (it should then be hidden, not blank).
 *
 * Usage:
 *   node scripts/check-agent-pack.mjs            # every pack under agents/
 *   node scripts/check-agent-pack.mjs agents/x   # one pack
 */

import { readdir, readFile, stat } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '..')
const AGENTS_DIR = join(ROOT, 'agents')
const SKILL_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const AGENT_ID = SKILL_NAME
const INSTRUCTION_BUDGET = 65536
const INSTRUCTION_WARN = 8192
const MIN_DESCRIPTION = 20
const CARD_BLOCKS = new Set([
  'metric', 'ring', 'progress', 'list', 'checklist',
  'chart', 'countdown', 'feed', 'markdown', 'actions',
])

const problems = []
const warnings = []
const fail = (pack, message) => problems.push(`${pack}: ${message}`)
const warn = (pack, message) => warnings.push(`${pack}: ${message}`)

async function main() {
  const target = process.argv[2]
  if (target === undefined && !existsSync(AGENTS_DIR)) {
    console.error(`no agents/ directory at ${AGENTS_DIR}`)
    process.exit(1)
  }
  const packs = target
    ? [resolve(ROOT, target)]
    : (await readdir(AGENTS_DIR, { withFileTypes: true }))
        .filter(entry => entry.isDirectory())
        .map(entry => join(AGENTS_DIR, entry.name))
        .sort()

  if (packs.length === 0) {
    console.error('no packs found under agents/')
    process.exit(1)
  }

  for (const pack of packs) {
    const label = relative(ROOT, pack)
    if (!existsSync(join(pack, 'agent.json'))) {
      fail(label, 'missing agent.json')
      continue
    }
    await checkAgentJson(pack, label)
    await checkInstructions(pack, label)
    await checkSkills(pack, label)
    await checkCards(pack, label)
  }

  for (const message of warnings) console.warn(`warn  ${message}`)
  for (const message of problems) console.error(`error ${message}`)

  const summary = `${packs.length} pack(s): ${problems.length} error(s), ${warnings.length} warning(s)`
  if (problems.length > 0) {
    console.error(summary)
    process.exit(1)
  }
  console.log(`ok    ${summary}`)
}

async function checkAgentJson(pack, label) {
  const doc = await readJson(join(pack, 'agent.json'), label)
  if (doc === undefined) return

  if (doc.schema !== 1) fail(label, `agent.json: schema must be 1, got ${JSON.stringify(doc.schema)}`)
  if (typeof doc.id !== 'string' || !AGENT_ID.test(doc.id)) {
    fail(label, `agent.json: id must be kebab-case, got ${JSON.stringify(doc.id)}`)
  }
  if (typeof doc.name !== 'string' || doc.name.trim().length === 0) {
    fail(label, 'agent.json: name is required')
  }

  const cards = Array.isArray(doc.cards) ? doc.cards : []
  for (const id of cards) {
    if (typeof id !== 'string') {
      fail(label, 'agent.json: cards[] must be strings')
      continue
    }
    if (!existsSync(join(pack, 'cards', `${id}.card.json`))) {
      fail(label, `agent.json: card "${id}" declared but cards/${id}.card.json is missing`)
    }
  }

  // A pack may declare skills; every declared name must exist on disk.
  const skills = Array.isArray(doc.skills) ? doc.skills : []
  for (const name of skills) {
    if (!existsSync(join(pack, '.dsh', 'skills', String(name), 'SKILL.md'))) {
      fail(label, `agent.json: skill "${name}" declared but .dsh/skills/${name}/SKILL.md is missing`)
    }
  }
}

async function checkInstructions(pack, label) {
  const path = join(pack, 'AGENTS.md')
  if (!existsSync(path)) {
    fail(label, 'missing AGENTS.md (the agent would have no persona or config)')
    return
  }
  const bytes = (await readFile(path)).byteLength
  if (bytes > INSTRUCTION_BUDGET) {
    fail(label, `AGENTS.md is ${bytes} B, over the ${INSTRUCTION_BUDGET} B loader budget (ignored entirely)`)
  } else if (bytes > INSTRUCTION_WARN) {
    warn(label, `AGENTS.md is ${bytes} B; every turn pays for it — trim toward ${INSTRUCTION_WARN} B`)
  }
}

async function checkSkills(pack, label) {
  const root = join(pack, '.dsh', 'skills')
  if (!existsSync(root)) {
    fail(label, 'missing .dsh/skills (no skills would load)')
    return
  }
  const entries = await readdir(root, { withFileTypes: true })
  let seen = 0
  for (const entry of entries.filter(item => item.isDirectory())) {
    const file = join(root, entry.name, 'SKILL.md')
    if (!existsSync(file)) {
      fail(label, `.dsh/skills/${entry.name}: missing SKILL.md`)
      continue
    }
    seen += 1
    const raw = await readFile(file, 'utf8')
    const front = parseFrontmatter(raw)
    if (front === undefined) {
      fail(label, `.dsh/skills/${entry.name}/SKILL.md: missing or malformed YAML frontmatter`)
      continue
    }
    const { name, description } = front
    if (typeof name !== 'string' || name.length === 0) {
      fail(label, `.dsh/skills/${entry.name}/SKILL.md: frontmatter requires "name"`)
      continue
    }
    if (!SKILL_NAME.test(name)) {
      fail(label, `.dsh/skills/${entry.name}/SKILL.md: name "${name}" must be lowercase kebab-case`)
    }
    if (name !== entry.name) {
      fail(label, `.dsh/skills/${entry.name}/SKILL.md: name "${name}" must equal its directory name`)
    }
    if (typeof description !== 'string' || description.trim().length < MIN_DESCRIPTION) {
      fail(label, `.dsh/skills/${entry.name}/SKILL.md: description must be a trigger sentence (>= ${MIN_DESCRIPTION} chars)`)
    }
  }
  if (seen === 0) fail(label, '.dsh/skills has no skill directories')
}

async function checkCards(pack, label) {
  const root = join(pack, 'cards')
  if (!existsSync(root)) return
  const files = (await readdir(root)).filter(name => name.endsWith('.card.json'))
  for (const file of files) {
    const where = `cards/${file}`
    const doc = await readJson(join(root, file), label)
    if (doc === undefined) continue

    if (doc.schema !== 1) fail(label, `${where}: schema must be 1`)
    const expectedId = file.slice(0, -'.card.json'.length)
    if (doc.id !== expectedId) fail(label, `${where}: id "${doc.id}" must equal the file stem "${expectedId}"`)
    if (typeof doc.title !== 'string' || doc.title.length === 0) fail(label, `${where}: title is required`)
    if (!Array.isArray(doc.blocks) || doc.blocks.length === 0) {
      fail(label, `${where}: blocks[] is required`)
      continue
    }

    // `list` / `checklist` templates bind per element, so their `item` tokens are
    // relative to an element of `bind`, not to the document root. Collect those
    // separately instead of reporting every one of them as unresolvable.
    const tokens = []
    const collections = []
    for (const [index, block] of doc.blocks.entries()) {
      if (typeof block !== 'object' || block === null || !CARD_BLOCKS.has(block.type)) {
        fail(label, `${where}: blocks[${index}] has unknown type ${JSON.stringify(block?.type)}`)
        continue
      }
      if (block.type === 'list' || block.type === 'checklist') {
        const { item, items, ...outer } = block
        collectTokens(outer, tokens)
        if (typeof block.bind !== 'string') {
          fail(label, `${where}: blocks[${index}] (${block.type}) requires a "bind" path`)
          continue
        }
        collections.push({ where: `blocks[${index}]`, ref: block.bind, template: item ?? items })
        continue
      }
      collectTokens(block, tokens)
    }

    if (typeof doc.bind !== 'string') {
      if (tokens.length > 0) fail(label, `${where}: has {{...}} bindings but no "bind" document`)
      continue
    }
    const bindPath = join(pack, doc.bind)
    if (!existsSync(bindPath)) {
      warn(label, `${where}: bind "${doc.bind}" does not exist yet (card must render as hidden)`)
      continue
    }
    const data = await readJson(bindPath, label)
    if (data === undefined) continue
    for (const token of tokens) {
      if (resolvePath(data, token) === undefined) {
        fail(label, `${where}: {{${token}}} does not resolve in ${doc.bind}`)
      }
    }
    for (const { where: at, ref, template } of collections) {
      const list = resolvePath(data, ref)
      if (!Array.isArray(list)) {
        fail(label, `${where}: ${at} binds "${ref}", which is not an array in ${doc.bind}`)
        continue
      }
      if (template === undefined) continue
      const sample = list[0]
      if (sample === undefined) continue
      const itemTokens = []
      collectTokens(template, itemTokens)
      for (const token of itemTokens) {
        if (resolvePath(sample, token) === undefined) {
          fail(label, `${where}: ${at} item {{${token}}} does not resolve on ${ref}[0]`)
        }
      }
    }
    for (const field of ['generatedAt', 'source']) {
      if (data[field] === undefined) warn(label, `${doc.bind}: missing "${field}" (CardSpec requires it)`)
    }
  }
}

function parseFrontmatter(raw) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(raw)
  if (match === null) return undefined
  const out = {}
  for (const line of match[1].split(/\r?\n/)) {
    if (line.trim().length === 0 || line.trimStart().startsWith('#')) continue
    const kv = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line)
    if (kv === null) continue
    out[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, '')
  }
  return out
}

function collectTokens(value, out) {
  if (typeof value === 'string') {
    for (const match of value.matchAll(/\{\{([^}]+)\}\}/g)) out.push(match[1].trim())
    return
  }
  if (Array.isArray(value)) {
    for (const item of value) collectTokens(item, out)
    return
  }
  if (typeof value === 'object' && value !== null) {
    for (const item of Object.values(value)) collectTokens(item, out)
  }
}

function resolvePath(data, token) {
  const segments = token.replace(/^\//, '').split('.')
  let current = data
  for (const segment of segments) {
    if (current === null || typeof current !== 'object') return undefined
    current = current[segment]
  }
  return current
}

async function readJson(path, label) {
  try {
    return JSON.parse(await readFile(path, 'utf8'))
  } catch (error) {
    fail(label, `${relative(ROOT, path)}: ${error instanceof Error ? error.message : String(error)}`)
    return undefined
  }
}

await main()
