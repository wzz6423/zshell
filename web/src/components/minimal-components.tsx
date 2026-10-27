import { useEffect, useRef, useState } from 'react'

interface MinimalFeatureProps {
  number: string
  title: string
  description: string
  icon?: string
}

export function MinimalFeature({ number, title, description, icon }: MinimalFeatureProps) {
  const [isVisible, setIsVisible] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      { threshold: 0.2 }
    )

    if (ref.current) observer.observe(ref.current)
    return () => observer.disconnect()
  }, [])

  return (
    <div
      ref={ref}
      className={`group relative overflow-hidden border-t border-border py-16 transition-all duration-700 ${
        isVisible ? 'translate-y-0 opacity-100' : 'translate-y-12 opacity-0'
      }`}
    >
      {/* 悬停背景效果 */}
      <div className="absolute inset-0 bg-gradient-to-r from-neutral-50/0 via-neutral-50/50 to-neutral-50/0 opacity-0 transition-opacity duration-500 group-hover:opacity-100 dark:from-neutral-900/0 dark:via-neutral-900/30 dark:to-neutral-900/0" />

      <div className="relative grid gap-8 md:grid-cols-[120px_1fr] md:gap-16">
        {/* 编号 */}
        <div>
          <div className="text-sm font-medium text-neutral-400 dark:text-neutral-500">{number}</div>
        </div>

        {/* 内容 */}
        <div>
          <h3 className="mb-4 text-3xl font-semibold text-foreground transition-transform duration-300 group-hover:translate-x-2">
            {title}
          </h3>
          <p className="max-w-xl text-lg leading-relaxed text-muted-foreground">{description}</p>
        </div>
      </div>
    </div>
  )
}

export function MinimalSection({
  children,
  className = '',
}: {
  children: React.ReactNode
  className?: string
}) {
  return (
    <section className={`bg-background py-24 ${className}`}>
      <div className="mx-auto max-w-6xl px-6">{children}</div>
    </section>
  )
}

/**
 * 终端演示窗口
 */
export function TerminalDemo() {
  const [currentLine, setCurrentLine] = useState(0)
  const [isVisible, setIsVisible] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  const lines = [
    { type: 'command', text: '❯ cd ~/projects/my-app', delay: 0 },
    { type: 'command', text: '❯ git status', delay: 800 },
    { type: 'output', text: 'On branch main', delay: 1200 },
    { type: 'modified', text: 'M  src/app.ts', delay: 1400 },
    { type: 'modified', text: 'M  src/utils.ts', delay: 1600 },
    { type: 'command', text: '❯ npm run dev', delay: 2200 },
    { type: 'success', text: '✓ Server running at http://localhost:3000', delay: 2800 },
  ]

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      { threshold: 0.3 }
    )

    if (ref.current) observer.observe(ref.current)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    if (!isVisible) return

    const timers = lines.map((line, index) => {
      return setTimeout(() => {
        setCurrentLine(index + 1)
      }, line.delay)
    })

    return () => timers.forEach(clearTimeout)
  }, [isVisible])

  return (
    <div ref={ref} className="relative overflow-hidden rounded-2xl border border-neutral-200 bg-gradient-to-br from-neutral-900 to-black shadow-2xl">
      {/* 窗口标题栏 */}
      <div className="flex items-center gap-2 border-b border-neutral-800 bg-neutral-800/50 px-4 py-3 backdrop-blur">
        <div className="flex gap-2">
          <div className="h-3 w-3 rounded-full bg-neutral-500" />
          <div className="h-3 w-3 rounded-full bg-neutral-600" />
          <div className="h-3 w-3 rounded-full bg-neutral-700" />
        </div>
        <div className="ml-4 text-xs text-neutral-400">zshell</div>
      </div>

      {/* 终端内容 */}
      <div className="p-6 font-mono text-sm">
        {lines.slice(0, currentLine).map((line, index) => (
          <div
            key={index}
            className={`mb-2 animate-fade-in ${
              line.type === 'command'
                ? 'text-white'
                : line.type === 'modified'
                  ? 'text-neutral-300'
                  : line.type === 'success'
                    ? 'text-neutral-100'
                    : 'text-neutral-400'
            }`}
          >
            {line.text}
          </div>
        ))}
        {currentLine === lines.length && (
          <div className="inline-block h-4 w-2 animate-pulse bg-white" />
        )}
      </div>

      {/* 光晕效果 */}
      <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-neutral-500/10 to-transparent" />
    </div>
  )
}

/**
 * 特性卡片
 */
export function FeatureCard({
  title,
  description,
  visual,
}: {
  title: string
  description: string
  visual: React.ReactNode
}) {
  const [isVisible, setIsVisible] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      { threshold: 0.2 }
    )

    if (ref.current) observer.observe(ref.current)
    return () => observer.disconnect()
  }, [])

  return (
    <div
      ref={ref}
      className={`group transition-all duration-700 ${
        isVisible ? 'translate-y-0 opacity-100' : 'translate-y-12 opacity-0'
      }`}
    >
      <div className="relative overflow-hidden rounded-2xl border border-neutral-200 bg-white p-8 shadow-sm transition-all duration-300 hover:shadow-xl">
        {/* 视觉元素 */}
        <div className="mb-6">{visual}</div>

        {/* 文本内容 */}
        <h3 className="mb-3 text-2xl font-semibold text-black">{title}</h3>
        <p className="text-neutral-600">{description}</p>

        {/* 悬停箭头 */}
        <div className="mt-4 flex items-center gap-2 text-sm font-medium text-black opacity-0 transition-all duration-300 group-hover:translate-x-2 group-hover:opacity-100 dark:text-white">
          了解更多
          <span className="i-mingcute-arrow-right-line" />
        </div>
      </div>
    </div>
  )
}
