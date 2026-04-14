#!/usr/bin/env node
// Extract help-text strings from src/commands/*.zig and write one _help.txt
// per command into website/app/commands/<cmd>/. The goal is to make the Zig
// source the single source of truth for CLI synopsis + flags so the docs
// can't drift from the binary.
//
// Invoked automatically from `npm run dev` and `npm run build`. Generated
// files are gitignored — always produced fresh from source.

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { dirname, join, basename } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const websiteRoot = join(__dirname, '..')
const repoRoot = join(websiteRoot, '..')
const commandsDir = join(repoRoot, 'src', 'commands')

// Commands that should get rendered on the website. This excludes `common`
// (shared helpers, no user-facing help) and `help` (overview, not a command
// page). Add new commands here to include them.
const websiteCommands = new Set([
  'run',
  'list',
  'watch',
  'send',
  'snapshot',
  'wait',
  'kill',
  'delete',
  'logs',
  'replay',
  'attach',
  'keys',
  'info',
])

function extractHelp(source) {
  // Match: pub fn helpText() []const u8 { ... }
  // The function body contains `return` followed by a Zig multiline string:
  //   \\line 1
  //   \\line 2
  //   ;
  const fnRe = /pub\s+fn\s+helpText\s*\(\s*\)\s*\[\]const u8\s*\{([\s\S]*?)^\}/m
  const match = source.match(fnRe)
  if (!match) return null

  const body = match[1]
  const lines = body.split('\n')
  const textLines = []
  for (const line of lines) {
    // Match lines of the form "    \\..." — the `\\` prefix is Zig's
    // multiline string continuation. Everything after `\\` is literal content.
    const m = line.match(/^\s*\\\\(.*)$/)
    if (m) textLines.push(m[1])
  }
  if (textLines.length === 0) return null
  return textLines.join('\n').replace(/\n+$/, '') + '\n'
}

let errors = 0
const files = readdirSync(commandsDir).filter((f) => f.endsWith('.zig'))

for (const file of files) {
  const cmd = basename(file, '.zig')
  if (!websiteCommands.has(cmd)) continue

  const source = readFileSync(join(commandsDir, file), 'utf8')
  const text = extractHelp(source)
  if (text === null) {
    console.error(`✗ ${cmd}: could not find pub fn helpText() in src/commands/${file}`)
    errors++
    continue
  }
  const outDir = join(websiteRoot, 'app', 'commands', cmd)
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true })
  const outPath = join(outDir, '_help.txt')
  writeFileSync(outPath, text)
  console.log(`✓ ${cmd} → app/commands/${cmd}/_help.txt (${text.length} bytes)`)
}

if (errors > 0) {
  console.error(`\n${errors} command(s) failed — regex needs updating?`)
  process.exit(1)
}
