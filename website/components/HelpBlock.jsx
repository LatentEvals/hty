import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// Renders the contents of app/commands/<cmd>/_help.txt in a styled code block.
// The _help.txt files are generated at build time by scripts/extract-help.mjs
// from the Zig source — they are NEVER committed. See website/scripts/extract-help.mjs.
//
// Used in MDX as: <HelpBlock cmd="list" />
// Globally registered in mdx-components.jsx, so no import needed.
export function HelpBlock({ cmd }) {
  const path = join(process.cwd(), 'app', 'commands', cmd, '_help.txt')
  const text = readFileSync(path, 'utf8').trimEnd()
  return (
    <pre className="help-block">
      <code>{text}</code>
    </pre>
  )
}
