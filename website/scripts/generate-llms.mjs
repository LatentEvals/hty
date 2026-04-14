#!/usr/bin/env node
// Generate llms.txt, llms-full.txt, and per-page .md files in out/ so that
// AI agents can discover and ingest the docs without parsing HTML.
//
// Runs AFTER `next build` so we can walk the static HTML export and convert
// each page's rendered content to markdown. See llmstxt.org for the index
// convention.
//
//   /llms.txt         — curated index with links (markdown)
//   /llms-full.txt    — every page concatenated
//   /<route>.md       — markdown sibling of each HTML page
//
// Strategy: jsdom parses each out/<route>.html, we pull the <main> content
// region Nextra marks with data-pagefind-body, strip chrome flagged with
// data-pagefind-ignore, and Turndown converts the HTML to markdown. No MDX
// awareness required — new components (HelpBlock, Callout, future ones)
// work automatically because they're already rendered.

import { readFileSync, writeFileSync, readdirSync, existsSync, statSync, mkdirSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { JSDOM } from 'jsdom'
import TurndownService from 'turndown'
import { gfm } from 'turndown-plugin-gfm'

const __dirname = dirname(fileURLToPath(import.meta.url))
const websiteRoot = join(__dirname, '..')
const appRoot = join(websiteRoot, 'app')
const outRoot = join(websiteRoot, 'out')
const publicRoot = join(websiteRoot, 'public')

// Two modes:
//   - HTML mode (preferred): `out/` exists from `next build` — convert rendered
//     HTML to markdown for full fidelity (code blocks, callouts, tables, etc.).
//   - MDX fallback: no `out/` yet — parse MDX source with a light regex
//     transform. Used by `npm run dev` on a fresh clone so `/llms.txt` works
//     without needing a build first. Every subsequent build overwrites with
//     the HTML-derived version.
const haveHtml = existsSync(outRoot) && existsSync(join(outRoot, 'index.html'))
const mode = haveHtml ? 'html' : 'mdx'

// Writes to public/ (so `next dev` serves the files at /llms.txt, /<route>.md,
// etc.) and to out/ if it exists. public/ copies are gitignored; `next build`
// copies them into out/ automatically.
function writeToBoth(relPath, content) {
  const roots = haveHtml ? [outRoot, publicRoot] : [publicRoot]
  for (const root of roots) {
    const full = join(root, relPath)
    mkdirSync(dirname(full), { recursive: true })
    writeFileSync(full, content)
  }
}

// ---------- domain from CNAME ----------
const cname = readFileSync(join(websiteRoot, 'public', 'CNAME'), 'utf8').trim()
const origin = `https://${cname}`

// ---------- parse _meta.ts ----------
// Simple `export default { ... }` with plain object literals — eval the literal.
function readMeta(dir) {
  const p = join(dir, '_meta.ts')
  if (!existsSync(p)) return null
  const src = readFileSync(p, 'utf8').replace(/^\s*export\s+default\s+/, '')
  // eslint-disable-next-line no-new-func
  return Function(`"use strict"; return (${src});`)()
}

function metaTitle(entry, fallback) {
  if (typeof entry === 'string') return entry
  if (entry && typeof entry === 'object' && typeof entry.title === 'string') return entry.title
  return fallback
}

// ---------- Turndown setup ----------
const turndown = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced',
  bulletListMarker: '-',
  emDelimiter: '_',
  strongDelimiter: '**',
  linkStyle: 'inlined'
})
turndown.use(gfm)

// Shiki renders highlighted code as <pre><code><span style="color:#..."><span>token</span></span>...</code></pre>
// Nested <span>s confuse the default code block rule — override to take textContent
// directly and derive the language from data-language on the wrapper, if present.
turndown.addRule('shikiCodeBlock', {
  filter: (node) => node.nodeName === 'PRE' && node.querySelector('code'),
  replacement: (_content, node) => {
    const code = node.querySelector('code')
    const text = code.textContent.replace(/\n+$/, '')
    // Nextra/Shiki puts the language on data-language on the outer figure
    // or on a class on <code>. Fall back to empty fence.
    let lang = ''
    const cls = code.getAttribute('class') || ''
    const langMatch = cls.match(/language-(\S+)/)
    if (langMatch) lang = langMatch[1]
    else {
      const dl =
        node.getAttribute('data-language') ||
        node.parentElement?.getAttribute('data-language') ||
        ''
      if (dl) lang = dl
    }
    return `\n\n\`\`\`${lang}\n${text}\n\`\`\`\n\n`
  }
})

// Strip the anchor <a> rendered next to headings by Nextra — they look like
// '#' or empty links and just clutter the markdown.
turndown.addRule('dropHeadingAnchors', {
  filter: (node) =>
    node.nodeName === 'A' &&
    (node.getAttribute('aria-label') === 'Permalink' ||
      node.classList?.contains('subheading-anchor') ||
      (node.textContent.trim() === '#' && node.getAttribute('href')?.startsWith('#'))),
  replacement: () => ''
})

// Convert Nextra's <div class="nextra-callout">...</div> to a blockquote.
// Detects type (info/warning/error/default) from the Tailwind color class
// Nextra applies, and prefixes the blockquote with a label.
turndown.addRule('nextraCallout', {
  filter: (node) => node.nodeName === 'DIV' && node.classList?.contains('nextra-callout'),
  replacement: (_content, node) => {
    // Drop the leading icon container (Nextra renders an emoji/SVG wrapper first).
    const clone = node.cloneNode(true)
    const firstChild = clone.firstElementChild
    if (firstChild && firstChild.querySelector('svg, [data-pagefind-ignore]')) {
      firstChild.remove()
    }
    // Detect type from Tailwind color class (best-effort).
    const cls = node.className || ''
    let label = 'Note'
    if (/yellow/.test(cls)) label = 'Warning'
    else if (/red/.test(cls)) label = 'Error'
    else if (/blue/.test(cls)) label = 'Info'
    else if (/green/.test(cls)) label = 'Tip'
    const inner = turndown.turndown(clone.innerHTML).trim()
    const quoted = inner
      .split('\n')
      .map((l) => (l ? `> ${l}` : '>'))
      .join('\n')
    return `\n\n> **${label}:**\n${quoted}\n\n`
  }
})

// ---------- html → markdown ----------
function htmlToMarkdown(htmlPath) {
  const html = readFileSync(htmlPath, 'utf8')
  const dom = new JSDOM(html)
  const doc = dom.window.document

  // Nextra wraps the actual page content in <main data-pagefind-body>.
  const main = doc.querySelector('main[data-pagefind-body]') || doc.querySelector('main')
  if (!main) return null

  // Drop chrome Nextra flagged as non-content (copy-page dropdown, TOC widgets,
  // callout icons, etc.) — but don't remove wrappers that contain real content
  // like <pre> code blocks. Nextra tags its <pre> wrappers with data-pagefind-ignore
  // to keep code out of the search index; we still want the code in our markdown.
  main.querySelectorAll('[data-pagefind-ignore]').forEach((el) => {
    if (!el.querySelector('pre')) el.remove()
  })
  // Drop the skip-to-content anchor.
  main.querySelectorAll('#nextra-skip-nav').forEach((el) => el.remove())
  // Drop inline SVGs — turndown can't do anything useful with them.
  main.querySelectorAll('svg').forEach((el) => el.remove())

  const md = turndown.turndown(main.innerHTML)
  return md.trim() + '\n'
}

// ---------- mdx → markdown (fallback path for dev-on-fresh-clone) ----------
// Light regex transform. Lower fidelity than HTML mode, but good enough to
// preview /llms.txt and /<route>.md in `next dev` without a prior build.
function mdxToMarkdown(mdxPath) {
  let text = readFileSync(mdxPath, 'utf8')

  // Strip frontmatter if any.
  text = text.replace(/^---\n[\s\S]*?\n---\n/, '')

  // <HelpBlock cmd="X" /> → fenced block with contents of _help.txt.
  text = text.replace(/<HelpBlock\s+cmd=(?:"([^"]+)"|'([^']+)')\s*\/>/g, (_m, a, b) => {
    const cmd = a || b
    const helpPath = join(appRoot, 'commands', cmd, '_help.txt')
    if (!existsSync(helpPath)) return ''
    const help = readFileSync(helpPath, 'utf8').trimEnd()
    return '```\n' + help + '\n```'
  })

  // <Callout type="T">…</Callout> → blockquote with **T:** prefix.
  text = text.replace(
    /<Callout\s+type=(?:"([^"]+)"|'([^']+)')\s*>([\s\S]*?)<\/Callout>/g,
    (_m, a, b, body) => {
      const type = (a || b || 'info').trim()
      const label = type.charAt(0).toUpperCase() + type.slice(1)
      const quoted = body.trim().split('\n').map((l) => (l ? `> ${l}` : '>')).join('\n')
      return `> **${label}:**\n${quoted}`
    }
  )

  // Warn on any remaining JSX-style tags we didn't handle — means a new
  // component slipped in and we need to extend this fallback.
  const leftover = text.match(/<[A-Z][A-Za-z0-9]*\b[^>]*>/g)
  if (leftover) {
    console.warn(
      `⚠ ${relative(websiteRoot, mdxPath)}: unhandled JSX in MDX fallback: ${[
        ...new Set(leftover)
      ].join(', ')}`
    )
  }

  return text.trimEnd() + '\n'
}

// ---------- rewrite internal links to .md siblings ----------
function rewriteLinks(md) {
  return md.replace(/\]\((\/[^)\s#]*?)(#[^)]*)?\)/g, (_m, path, hash = '') => {
    if (/\.[a-z0-9]+$/i.test(path)) return `](${path}${hash})`
    const target = path === '/' ? '/index.md' : `${path}.md`
    return `](${target}${hash})`
  })
}

// ---------- find built HTML pages ----------
// For every `app/**/page.mdx`, there is a corresponding `out/<route>.html`
// (or `out/index.html` for the root).
function findPages(dir, routePrefix = '') {
  const out = []
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    const st = statSync(full)
    if (st.isDirectory()) out.push(...findPages(full, `${routePrefix}/${name}`))
    else if (name === 'page.mdx') out.push({ route: routePrefix || '/', mdxFile: full })
  }
  return out
}

function routeToHtmlPath(route) {
  if (route === '/') return join(outRoot, 'index.html')
  return join(outRoot, `${route.replace(/^\//, '')}.html`)
}

// ---------- extract title and summary from converted markdown ----------
function extractTitleAndSummary(md) {
  const lines = md.split('\n')
  let title = null
  let summary = null
  let inCode = false
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.startsWith('```')) {
      inCode = !inCode
      continue
    }
    if (inCode) continue
    if (!title) {
      const m = line.match(/^#\s+(.+)$/)
      if (m) {
        title = m[1].trim()
        continue
      }
    } else if (!summary) {
      const t = line.trim()
      if (!t) continue
      if (t.startsWith('#')) continue
      if (t.startsWith('>')) continue
      // Require space after bullet so `**bold**` and `---` aren't treated as list items.
      if (/^([-*+]\s|\d+\.\s)/.test(t)) continue
      if (t === '---' || t === '***') continue
      const para = [t]
      for (let j = i + 1; j < lines.length; j++) {
        const n = lines[j].trim()
        if (!n) break
        if (n.startsWith('```')) break
        para.push(n)
      }
      summary = para.join(' ')
      break
    }
  }
  return { title, summary }
}

function truncate(s, n) {
  if (!s) return ''
  if (s.length <= n) return s
  return s.slice(0, n - 1).trimEnd() + '…'
}

// ---------- convert every page ----------
console.log(`ℹ mode: ${mode} (${mode === 'html' ? 'converting rendered HTML' : 'MDX source fallback — run a build for full fidelity'})`)
const pagesByRoute = new Map()
for (const { route, mdxFile } of findPages(appRoot)) {
  let md
  if (mode === 'html') {
    const htmlPath = routeToHtmlPath(route)
    if (!existsSync(htmlPath)) {
      console.warn(`⚠ no HTML for ${route} at ${relative(websiteRoot, htmlPath)}`)
      continue
    }
    md = htmlToMarkdown(htmlPath)
    if (!md) {
      console.warn(`⚠ could not extract main content from ${htmlPath}`)
      continue
    }
  } else {
    md = mdxToMarkdown(mdxFile)
  }
  md = rewriteLinks(md)
  const { title, summary } = extractTitleAndSummary(md)
  pagesByRoute.set(route, { route, md, title, summary })
}

// ---------- write per-page .md files ----------
let wrote = 0
for (const { route, md } of pagesByRoute.values()) {
  const relPath = route === '/' ? 'index.md' : `${route.replace(/^\//, '')}.md`
  writeToBoth(relPath, md)
  wrote++
}
console.log(
  `✓ wrote ${wrote} per-page markdown files (${haveHtml ? 'out/ + public/' : 'public/'})`
)

// ---------- assemble llms.txt using _meta.ts ordering ----------
const rootMeta = readMeta(appRoot) || {}
const sections = []
let currentSection = null

for (const [key, value] of Object.entries(rootMeta)) {
  if (value && typeof value === 'object' && value.type === 'separator') {
    if (currentSection) sections.push(currentSection)
    currentSection = { title: value.title || key, items: [] }
    continue
  }
  if (value && typeof value === 'object' && value.display === 'hidden') continue
  if (!currentSection) continue

  const sectionDir = join(appRoot, key)
  if (!existsSync(sectionDir) || !statSync(sectionDir).isDirectory()) continue
  const childMeta = readMeta(sectionDir) || {}
  for (const [childKey, childVal] of Object.entries(childMeta)) {
    const route = `/${key}/${childKey}`
    const page = pagesByRoute.get(route)
    if (!page) {
      console.warn(`⚠ llms.txt: no page for ${route}`)
      continue
    }
    const label = metaTitle(childVal, page.title || childKey)
    currentSection.items.push({ route, label, summary: page.summary })
  }
}
if (currentSection) sections.push(currentSection)

const landing = pagesByRoute.get('/')
const tagline = landing?.summary || 'Terminal automation for AI agents.'

const llmsLines = []
llmsLines.push(`# ${landing?.title || 'hty'}`)
llmsLines.push('')
llmsLines.push(`> ${tagline}`)
llmsLines.push('')
for (const section of sections) {
  if (!section.items.length) continue
  llmsLines.push(`## ${section.title}`)
  llmsLines.push('')
  for (const item of section.items) {
    const url = `${origin}${item.route}.md`
    const desc = truncate(item.summary || '', 140)
    llmsLines.push(`- [${item.label}](${url})${desc ? `: ${desc}` : ''}`)
  }
  llmsLines.push('')
}
// Per llmstxt.org convention: an "Optional" section at the end for supplementary
// resources. We use it to point at llms-full.txt, which bundles every page into
// a single fetch for agents that want the whole corpus at once.
llmsLines.push('## Optional')
llmsLines.push('')
llmsLines.push(
  `- [Full documentation](${origin}/llms-full.txt): every page above concatenated into a single file.`
)
llmsLines.push('')
writeToBoth('llms.txt', llmsLines.join('\n'))
console.log(`✓ wrote llms.txt (${sections.reduce((n, s) => n + s.items.length, 0)} entries)`)

// ---------- assemble llms-full.txt ----------
const fullLines = []
fullLines.push(`# ${landing?.title || 'hty'} — full documentation`)
fullLines.push('')
fullLines.push(`> ${tagline}`)
fullLines.push('')
fullLines.push(`Source: ${origin}/`)
fullLines.push('')

if (landing) {
  fullLines.push('---')
  fullLines.push('')
  fullLines.push(`<!-- page: / -->`)
  fullLines.push(landing.md.trimEnd())
  fullLines.push('')
}
for (const section of sections) {
  for (const item of section.items) {
    const page = pagesByRoute.get(item.route)
    if (!page) continue
    fullLines.push('---')
    fullLines.push('')
    fullLines.push(`<!-- page: ${item.route} -->`)
    fullLines.push(page.md.trimEnd())
    fullLines.push('')
  }
}
writeToBoth('llms-full.txt', fullLines.join('\n'))
console.log(`✓ wrote llms-full.txt`)
