#!/usr/bin/env node
// Extract help-text strings from src/headless.zig and write one _help.txt
// per command into website/app/commands/<cmd>/. The goal is to make the Zig
// source the single source of truth for CLI synopsis + flags so the docs
// can't drift from the binary.
//
// Invoked automatically from `npm run dev` and `npm run build`. Generated
// files are gitignored — always produced fresh from source.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const websiteRoot = join(__dirname, '..')
const repoRoot = join(websiteRoot, '..')
const sourcePath = join(repoRoot, 'src', 'headless.zig')

// Map website directory name → Zig function name.
// Most commands use `<cmd>HelpText`; `keys` uses `supportedKeysText`.
const commandToFn = {
  run: 'runHelpText',
  list: 'listHelpText',
  watch: 'watchHelpText',
  send: 'sendHelpText',
  snapshot: 'snapshotHelpText',
  wait: 'waitHelpText',
  kill: 'killHelpText',
  delete: 'deleteHelpText',
  logs: 'logsHelpText',
  replay: 'replayHelpText',
  attach: 'attachHelpText',
  keys: 'supportedKeysText'
}

const source = readFileSync(sourcePath, 'utf8')

function extractHelp(fnName) {
  // Match: fn <name>() []const u8 { ... }
  // The function body contains `return` followed by a Zig multiline string:
  //   \\line 1
  //   \\line 2
  //   ;
  const fnRe = new RegExp(
    `fn\\s+${fnName}\\s*\\(\\s*\\)\\s*\\[\\]const u8\\s*\\{([\\s\\S]*?)^\\}`,
    'm'
  )
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
for (const [cmd, fnName] of Object.entries(commandToFn)) {
  const text = extractHelp(fnName)
  if (text === null) {
    console.error(`✗ ${cmd}: could not find ${fnName}() in ${sourcePath}`)
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
