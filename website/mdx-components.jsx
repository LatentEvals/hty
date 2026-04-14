import { useMDXComponents as getDocsMDXComponents } from 'nextra-theme-docs'
import { Callout } from 'nextra/components'
import { HelpBlock } from './components/HelpBlock.jsx'

const docsComponents = getDocsMDXComponents()

export function useMDXComponents(components) {
  return {
    ...docsComponents,
    Callout,
    HelpBlock,
    ...components
  }
}
