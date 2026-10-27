import { useEffect, useState } from 'react'

export function ThemeToggle() {
  const [theme, setTheme] = useState<'light' | 'dark' | 'auto'>('auto')
  const [systemTheme, setSystemTheme] = useState<'light' | 'dark'>('light')

  useEffect(() => {
    // 检测系统主题
    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
    const updateSystemTheme = () => {
      setSystemTheme(mediaQuery.matches ? 'dark' : 'light')
    }

    updateSystemTheme()
    mediaQuery.addEventListener('change', updateSystemTheme)

    // 从 localStorage 读取用户偏好
    const savedTheme = localStorage.getItem('theme') as 'light' | 'dark' | 'auto' | null
    if (savedTheme) {
      setTheme(savedTheme)
    }

    return () => mediaQuery.removeEventListener('change', updateSystemTheme)
  }, [])

  useEffect(() => {
    // 应用主题
    const isDark = theme === 'auto' ? systemTheme === 'dark' : theme === 'dark'
    document.documentElement.classList.toggle('dark', isDark)

    // 保存用户偏好
    localStorage.setItem('theme', theme)
  }, [theme, systemTheme])

  const cycleTheme = () => {
    setTheme(current => {
      if (current === 'auto') return 'light'
      if (current === 'light') return 'dark'
      return 'auto'
    })
  }

  const currentIcon = () => {
    if (theme === 'auto') {
      return systemTheme === 'dark' ? 'i-mingcute-moon-line' : 'i-mingcute-sun-line'
    }
    return theme === 'dark' ? 'i-mingcute-moon-fill' : 'i-mingcute-sun-fill'
  }

  const getLabel = () => {
    if (theme === 'auto') return '自动'
    return theme === 'dark' ? '深色' : '浅色'
  }

  return (
    <button
      onClick={cycleTheme}
      className="inline-flex items-center gap-2 rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm transition-colors hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:hover:bg-gray-800"
      aria-label={`切换主题 (当前: ${getLabel()})`}
      title={`切换主题 (当前: ${getLabel()})`}
    >
      <span className={`${currentIcon()} text-base`} />
      <span className="hidden sm:inline">{getLabel()}</span>
    </button>
  )
}
