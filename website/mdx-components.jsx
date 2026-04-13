import { useMDXComponents as getDocsMDXComponents } from 'nextra-theme-docs'
import { Callout } from 'nextra/components'

const docsComponents = getDocsMDXComponents()

export function useMDXComponents(components) {
  return {
    ...docsComponents,
    Callout,
    ...components
  }
}
