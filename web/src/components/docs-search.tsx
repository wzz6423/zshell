import { create } from '@orama/orama'
import { createTokenizer } from '@orama/tokenizers/mandarin'
import { useDocsSearch } from 'fumadocs-core/search/client'
import { oramaStaticClient } from 'fumadocs-core/search/client/orama-static'
import { useI18n } from 'fumadocs-ui/contexts/i18n'
import type { SharedProps } from 'fumadocs-ui/contexts/search'
import {
  SearchDialog,
  SearchDialogClose,
  SearchDialogContent,
  SearchDialogHeader,
  SearchDialogIcon,
  SearchDialogInput,
  SearchDialogList,
  SearchDialogOverlay,
} from 'fumadocs-ui/components/dialog/search'
import { withBase } from '@/lib/utils'

/**
 * Rebuilds the database the index is loaded into. Fumadocs' own static dialog
 * cannot be reused here: a tokenizer is a function, so it does not survive the
 * index being exported as JSON, and Chinese queries would reach the English
 * tokenizer — which finds no spaces and returns the query as one token that
 * matches nothing. `load()` only replaces the index, so the tokenizer given
 * here is the one the query goes through.
 */
function initOrama(locale?: string) {
  // Anything else is English, which is Orama's default.
  if (locale !== 'zh') return create({ schema: { _: 'string' } })

  return create({
    schema: { _: 'string' },
    components: { tokenizer: createTokenizer() },
  })
}

/**
 * Docs search. The index is a static file the browser downloads once and
 * queries locally — see `src/routes/api/search.ts` for how it is built.
 */
export default function DocsSearchDialog(props: SharedProps) {
  const { locale } = useI18n()
  const client = oramaStaticClient({ locale, initOrama, from: withBase('/api/search') })
  const { search, setSearch, query } = useDocsSearch({ client })

  return (
    <SearchDialog
      search={search}
      onSearchChange={setSearch}
      isLoading={query.isLoading}
      {...props}
    >
      <SearchDialogOverlay />
      <SearchDialogContent>
        <SearchDialogHeader>
          <SearchDialogIcon />
          <SearchDialogInput />
          <SearchDialogClose />
        </SearchDialogHeader>
        <SearchDialogList items={query.data !== 'empty' ? query.data : null} />
      </SearchDialogContent>
    </SearchDialog>
  )
}
