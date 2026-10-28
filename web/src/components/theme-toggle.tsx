import { useSyncExternalStore } from 'react'
import { Airplay, Moon, Sun } from 'lucide-react'
import { useTheme } from 'fumadocs-ui/provider/base'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { uiCopy } from '@/lib/ui-copy'
import { cn } from '@/lib/utils'

const noop = () => () => {}
const themeOptions = {
  system: { label: 'themeAuto', Icon: Airplay, next: 'light' },
  light: { label: 'themeLight', Icon: Sun, next: 'dark' },
  dark: { label: 'themeDark', Icon: Moon, next: 'system' },
} as const

const themeToggleSize = {
  default: 'h-11 w-[62px]',
  compact: 'size-9',
} as const

export function ThemeToggle({
  lang = DEFAULT_LANGUAGE,
  size = 'default',
}: {
  lang?: string
  size?: keyof typeof themeToggleSize
}) {
  const { theme, setTheme } = useTheme()
  const mounted = useSyncExternalStore(noop, () => true, () => false)
  const currentTheme = theme === 'light' || theme === 'dark' ? theme : 'system'
  const { label, Icon } = themeOptions[mounted ? currentTheme : 'system']
  const labels = uiCopy(lang)
  const toggleLabel = labels.toggleTheme.replace('{theme}', labels[label])

  return (
    <button
      type="button"
      data-theme-toggle=""
      onClick={() => setTheme(themeOptions[currentTheme].next)}
      className={cn(
        'inline-flex shrink-0 items-center justify-center rounded-[var(--control-radius)] border border-border bg-background px-1 text-foreground transition-colors hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring focus-visible:outline-offset-2',
        themeToggleSize[size],
      )}
      aria-label={toggleLabel}
      title={toggleLabel}
    >
      <Icon className="size-4 shrink-0" aria-hidden="true" />
    </button>
  )
}
