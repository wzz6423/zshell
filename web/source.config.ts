import { defineConfig, defineDocs } from 'fumadocs-mdx/config'

export const docs = defineDocs({
  dir: 'content/docs',
})

export default defineConfig({
  mdxOptions: {
    remarkStructureOptions: {
      // Index readable document text without exposing JSX props in search results.
      types: ['heading', 'paragraph', 'blockquote', 'tableCell'],
    },
  },
})
