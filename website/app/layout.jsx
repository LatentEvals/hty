import { Footer, Layout, Navbar } from 'nextra-theme-docs'
import { Head } from 'nextra/components'
import { getPageMap } from 'nextra/page-map'
import 'nextra-theme-docs/style.css'
import './custom.css'

export const metadata = {
  title: 'hty — terminal automation for AI agents',
  description:
    'hty gives AI agents a way to use interactive TUI and CLI programs by reading the rendered screen and sending keys.'
}

const navbar = (
  <Navbar
    logo={
      <span style={{ fontWeight: 700, fontSize: '1.1rem' }}>hty</span>
    }
    projectLink="https://github.com/LatentEvals/hty"
  />
)

const footer = (
  <Footer>
    <div
      style={{
        display: 'flex',
        gap: '1.25rem',
        alignItems: 'center',
        flexWrap: 'wrap',
        fontSize: '0.875rem'
      }}
    >
      <span>© {new Date().getFullYear()} Montana Flynn · MIT License</span>
      <span style={{ opacity: 0.5 }}>·</span>
      <a href="https://github.com/LatentEvals/hty">GitHub</a>
      <a href="https://latentevals.com">LatentEvals</a>
      <a href="/llms.txt">llms.txt</a>
    </div>
  </Footer>
)

export default async function RootLayout({ children }) {
  return (
    <html lang="en" dir="ltr" suppressHydrationWarning>
      <Head />
      <body>
        <Layout
          navbar={navbar}
          pageMap={await getPageMap()}
          docsRepositoryBase="https://github.com/LatentEvals/hty/tree/main/website"
          footer={footer}
          sidebar={{ defaultMenuCollapseLevel: 1 }}
        >
          {children}
        </Layout>
      </body>
    </html>
  )
}
