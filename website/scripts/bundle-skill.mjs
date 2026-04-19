#!/usr/bin/env node
// Publish the agent skill (skills/hty/) to the static site so it's
// fetchable at:
//   https://hty.sh/skill.md        — the SKILL.md entrypoint
//   https://hty.sh/skill.tar.gz    — the full skill directory as a tarball
//
// Agents told "use this skill: https://hty.sh/skill.md" read SKILL.md's
// "Install this skill" section, then run the tarball one-liner to persist
// SKILL.md + references/ into their local skill directory.
//
// Runs as part of the website build, so the published skill always matches
// the repo's canonical skills/hty/ copy on main — no separate workflow.

import { cpSync, existsSync, mkdirSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(__dirname, '..', '..')
const skillSrc = join(repoRoot, 'skills', 'hty')
const websiteRoot = join(__dirname, '..')
const outRoot = join(websiteRoot, 'out')

if (!existsSync(skillSrc)) {
  console.error(`bundle-skill: ${skillSrc} not found`)
  process.exit(1)
}
if (!existsSync(outRoot)) {
  console.error(`bundle-skill: ${outRoot} not found — run next build first`)
  process.exit(1)
}

// 1. Publish SKILL.md at /skill.md.
cpSync(join(skillSrc, 'SKILL.md'), join(outRoot, 'skill.md'))

// 2. Publish the full skill dir at /skills/hty/ so per-file curls work too.
//    (Mirrors the raw.githubusercontent.com paths documented in SKILL.md's
//    explicit-install variant, without the GitHub hop.)
const skillOutDir = join(outRoot, 'skills', 'hty')
mkdirSync(skillOutDir, { recursive: true })
cpSync(skillSrc, skillOutDir, { recursive: true })

// 3. Produce /skill.tar.gz. Tarball root is `hty/` so that
//    `tar -xz -C ~/.claude/skills/` unpacks to ~/.claude/skills/hty/.
const tar = spawnSync(
  'tar',
  ['-czf', join(outRoot, 'skill.tar.gz'), '-C', join(repoRoot, 'skills'), 'hty'],
  { stdio: 'inherit' },
)
if (tar.status !== 0) {
  console.error('bundle-skill: tar failed')
  process.exit(tar.status ?? 1)
}

console.log('bundle-skill: published skill.md, skills/hty/, and skill.tar.gz')
