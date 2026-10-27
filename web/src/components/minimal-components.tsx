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
      className={`group relative overflow-hidden border-t border-gray-200 py-16 transition-all duration-700 ${
        isVisible ? 'translate-y-0 opacity-100' : 'translate-y-12 opacity-0'
      }`}
    >
      {/* 悬停背景效果 */}
      <div className="absolute inset-0 bg-gradient-to-r from-blue-50/0 via-blue-50/50 to-blue-50/0 opacity-0 transition-opacity duration-500 group-hover:opacity-100" />

      <div className="relative grid gap-8 md:grid-cols-[120px_1fr] md:gap-16">
        {/* 编号 */}
        <div>
          <div className="text-sm font-medium text-gray-400">{number}</div>
          {icon && (
            <div className="mt-4 inline-flex rounded-lg bg-gradient-to-br from-blue-50 to-purple-50 p-3">
              <span className={`text-3xl ${icon}`} />
            </div>
          )}
        </div>

        {/* 内容 */}
        <div>
          <h3 className="mb-4 text-3xl font-semibold text-black transition-transform duration-300 group-hover:translate-x-2">
            {title}
          </h3>
          <p className="max-w-xl text-lg leading-relaxed text-gray-600">{description}</p>
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
    <section className={`bg-white py-24 ${className}`}>
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
    <div ref={ref} className="relative overflow-hidden rounded-2xl border border-gray-200 bg-gradient-to-br from-gray-900 to-black shadow-2xl">
      {/* 窗口标题栏 */}
      <div className="flex items-center gap-2 border-b border-gray-800 bg-gray-800/50 px-4 py-3 backdrop-blur">
        <div className="flex gap-2">
          <div className="h-3 w-3 rounded-full bg-red-500" />
          <div className="h-3 w-3 rounded-full bg-yellow-500" />
          <div className="h-3 w-3 rounded-full bg-green-500" />
        </div>
        <div className="ml-4 text-xs text-gray-400">zshell</div>
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
                  ? 'text-yellow-400'
                  : line.type === 'success'
                    ? 'text-green-400'
                    : 'text-gray-400'
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
      <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-blue-500/10 to-transparent" />
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
      <div className="relative overflow-hidden rounded-2xl border border-gray-200 bg-white p-8 shadow-sm transition-all duration-300 hover:shadow-xl">
        {/* 视觉元素 */}
        <div className="mb-6">{visual}</div>

        {/* 文本内容 */}
        <h3 className="mb-3 text-2xl font-semibold text-black">{title}</h3>
        <p className="text-gray-600">{description}</p>

        {/* 悬停箭头 */}
        <div className="mt-4 flex items-center gap-2 text-sm font-medium text-blue-600 opacity-0 transition-all duration-300 group-hover:translate-x-2 group-hover:opacity-100">
          了解更多
          <span className="i-mingcute-arrow-right-line" />
        </div>
      </div>
    </div>
  )
}
