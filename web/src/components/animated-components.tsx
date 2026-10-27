import { useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'

interface FeatureCardProps {
  title: string
  description: string
  icon: string
  delay?: number
  gradient: string
}

export function AnimatedFeatureCard({ title, description, icon, delay = 0, gradient }: FeatureCardProps) {
  const [isVisible, setIsVisible] = useState(false)
  const cardRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setTimeout(() => setIsVisible(true), delay)
          observer.disconnect()
        }
      },
      { threshold: 0.1 }
    )

    if (cardRef.current) {
      observer.observe(cardRef.current)
    }

    return () => observer.disconnect()
  }, [delay])

  return (
    <div
      ref={cardRef}
      className={cn(
        'group relative overflow-hidden rounded-2xl border border-gray-800 bg-gray-900/50 p-8 backdrop-blur-sm transition-all duration-700',
        isVisible ? 'translate-y-0 opacity-100' : 'translate-y-20 opacity-0',
        'hover:border-gray-700 hover:shadow-2xl'
      )}
      style={{
        transitionDelay: `${delay}ms`,
      }}
    >
      {/* 渐变背景 */}
      <div
        className={cn(
          'absolute inset-0 opacity-0 transition-opacity duration-500 group-hover:opacity-100',
          gradient
        )}
      />

      {/* 内容 */}
      <div className="relative z-10">
        <div className="mb-4 inline-flex items-center justify-center rounded-xl bg-gradient-to-br from-green-500/10 to-blue-500/10 p-3">
          <span className={cn('text-4xl', icon)} />
        </div>

        <h3 className="mb-3 text-2xl font-bold text-white">{title}</h3>
        <p className="text-gray-400">{description}</p>
      </div>

      {/* 光晕效果 */}
      <div className="pointer-events-none absolute -inset-px rounded-2xl opacity-0 transition-opacity duration-500 group-hover:opacity-100">
        <div className="absolute inset-0 rounded-2xl bg-gradient-to-r from-green-500/20 to-blue-500/20 blur-xl" />
      </div>
    </div>
  )
}

interface AnimatedSectionProps {
  children: React.ReactNode
  className?: string
}

export function AnimatedSection({ children, className }: AnimatedSectionProps) {
  const [isVisible, setIsVisible] = useState(false)
  const sectionRef = useRef<HTMLElement>(null)

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      { threshold: 0.1 }
    )

    if (sectionRef.current) {
      observer.observe(sectionRef.current)
    }

    return () => observer.disconnect()
  }, [])

  return (
    <section
      ref={sectionRef}
      className={cn(
        'transition-all duration-1000',
        isVisible ? 'translate-y-0 opacity-100' : 'translate-y-20 opacity-0',
        className
      )}
    >
      {children}
    </section>
  )
}

export function CodeWindow({ code, language = 'bash' }: { code: string; language?: string }) {
  const [displayedCode, setDisplayedCode] = useState('')
  const [isVisible, setIsVisible] = useState(false)
  const windowRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      { threshold: 0.1 }
    )

    if (windowRef.current) {
      observer.observe(windowRef.current)
    }

    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    if (!isVisible) return

    let currentIndex = 0
    const interval = setInterval(() => {
      if (currentIndex <= code.length) {
        setDisplayedCode(code.slice(0, currentIndex))
        currentIndex++
      } else {
        clearInterval(interval)
      }
    }, 30)

    return () => clearInterval(interval)
  }, [code, isVisible])

  return (
    <div
      ref={windowRef}
      className="relative overflow-hidden rounded-xl border border-gray-800 bg-gray-900/80 backdrop-blur-sm"
    >
      {/* 窗口标题栏 */}
      <div className="flex items-center gap-2 border-b border-gray-800 px-4 py-3">
        <div className="flex gap-2">
          <div className="h-3 w-3 rounded-full bg-red-500" />
          <div className="h-3 w-3 rounded-full bg-yellow-500" />
          <div className="h-3 w-3 rounded-full bg-green-500" />
        </div>
        <span className="ml-auto text-xs text-gray-500">{language}</span>
      </div>

      {/* 代码内容 */}
      <div className="p-4 font-mono text-sm">
        <pre className="text-green-400">
          {displayedCode}
          <span className="inline-block h-4 w-2 animate-pulse bg-green-400" />
        </pre>
      </div>

      {/* 发光效果 */}
      <div className="pointer-events-none absolute inset-0">
        <div className="absolute inset-0 bg-gradient-to-b from-green-500/5 to-transparent" />
      </div>
    </div>
  )
}

export function FloatingElement({
  children,
  className,
  delay = 0,
}: {
  children: React.ReactNode
  className?: string
  delay?: number
}) {
  return (
    <div
      className={cn('animate-float', className)}
      style={{
        animationDelay: `${delay}ms`,
      }}
    >
      {children}
    </div>
  )
}
