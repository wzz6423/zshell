import { useDocsSearch } from 'fumadocs-core/search/client'
import { staticClient } from 'fumadocs-core/search/client/orama-static'
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
 * Docs search. The index is a static file the browser downloads once and
 * queries locally — see `src/routes/api/search.ts` for how it is built.
 *
 * The engine's default tokenizer is multilingual, so a Chinese query is split
 * the same way here as the index was built there — nothing has to be kept in
 * sync by hand, and a tokenizer never has to survive the index's trip through
 * JSON.
 */
export default function DocsSearchDialog(props: SharedProps) {
  const { locale } = useI18n()
  const client = staticClient({ locale, from: withBase('/api/search') })
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
