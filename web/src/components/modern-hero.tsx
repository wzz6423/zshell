import { useEffect, useRef, useState } from 'react'
import { DocsLink } from '@/components/site-links'
import type { HomeCopy, Release } from '@/lib/home-copy'

/**
 * 现代化 Hero 区域 - 参考 Google Antigravity
 */
export function ModernHero({ lang, copy, release }: { lang: string; copy: HomeCopy; release: Release }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [scrollY, setScrollY] = useState(0)

  // 清晰可见的粒子动画
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const resize = () => {
      canvas.width = window.innerWidth
      canvas.height = window.innerHeight
    }
    resize()
    window.addEventListener('resize', resize)

    let frame = 0
    const particles: Array<{ x: number; y: number; vx: number; vy: number }> = []

    // 初始化粒子
    for (let i = 0; i < 60; i++) {
      particles.push({
        x: Math.random() * canvas.width,
        y: Math.random() * canvas.height,
        vx: (Math.random() - 0.5) * 0.5,
        vy: (Math.random() - 0.5) * 0.5,
      })
    }

    const animate = () => {
      ctx.clearRect(0, 0, canvas.width, canvas.height)

      // 更新和绘制粒子
      particles.forEach((p) => {
        p.x += p.vx
        p.y += p.vy

        // 边界反弹
        if (p.x < 0 || p.x > canvas.width) p.vx *= -1
        if (p.y < 0 || p.y > canvas.height) p.vy *= -1

        // 绘制粒子 - 更大更明显
        ctx.fillStyle = '#666'
        ctx.beginPath()
        ctx.arc(p.x, p.y, 2, 0, Math.PI * 2)
        ctx.fill()
      })

      // 绘制连线
      ctx.strokeStyle = '#ddd'
      ctx.lineWidth = 1
      for (let i = 0; i < particles.length; i++) {
        for (let j = i + 1; j < particles.length; j++) {
          const dx = particles[i].x - particles[j].x
          const dy = particles[i].y - particles[j].y
          const dist = Math.sqrt(dx * dx + dy * dy)

          if (dist < 150) {
            ctx.globalAlpha = 1 - dist / 150
            ctx.beginPath()
            ctx.moveTo(particles[i].x, particles[i].y)
            ctx.lineTo(particles[j].x, particles[j].y)
            ctx.stroke()
          }
        }
      }
      ctx.globalAlpha = 1

      frame++
      requestAnimationFrame(animate)
    }
    animate()

    return () => window.removeEventListener('resize', resize)
  }, [])

  // 视差滚动
  useEffect(() => {
    const handleScroll = () => setScrollY(window.scrollY)
    window.addEventListener('scroll', handleScroll, { passive: true })
    return () => window.removeEventListener('scroll', handleScroll)
  }, [])

  return (
    <section className="relative flex min-h-screen items-center justify-center overflow-hidden bg-white dark:bg-gray-950">
      {/* 粒子画布 */}
      <canvas
        ref={canvasRef}
        className="absolute inset-0"
        style={{
          transform: `translateY(${scrollY * 0.5}px)`,
        }}
      />

      <div
        className="relative z-10 w-full max-w-6xl px-6 text-center"
        style={{
          transform: `translateY(${scrollY * 0.3}px)`,
          opacity: Math.max(0, 1 - scrollY / 600),
        }}
      >
        {/* 状态标签 */}
        <div className="mb-6 inline-flex items-center gap-2 rounded-full border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-black shadow-sm dark:border-gray-700 dark:bg-gray-900 dark:text-white">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-blue-600 opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-blue-600" />
          </span>
          新版本 v{release.version} 已发布
        </div>

        {/* 主标题 */}
        <h1 className="mb-6 text-7xl font-bold tracking-tight text-black md:text-9xl dark:text-white">
          zshell
        </h1>

        {/* 副标题 - 更多信息 */}
        <p className="mb-4 text-2xl font-semibold text-black md:text-4xl dark:text-white">
          终端在中心。
          <span className="bg-gradient-to-r from-blue-600 to-purple-600 bg-clip-text text-transparent">
            项目在掌握
          </span>
          。
        </p>

        <p className="mx-auto mb-12 max-w-2xl text-lg leading-relaxed text-gray-700 dark:text-gray-300">
          运行你的 shell 和编码 Agent，把本地与 SSH 项目、文件和 Git 审阅留在同一个原生 macOS 工作区。
        </p>

        {/* 按钮 */}
        <div className="flex flex-col items-center justify-center gap-4 sm:flex-row">
          <a
            href={release.dmg}
            download
            className="inline-flex items-center gap-2 rounded-full bg-black px-8 py-4 text-base font-medium text-white shadow-lg transition-transform hover:scale-105 dark:bg-white dark:text-black"
          >
            <span className="i-mingcute-apple-fill text-xl" />
            下载 macOS 版本
            <span className="i-mingcute-arrow-right-line" />
          </a>

          <DocsLink
            lang={lang}
            className="inline-flex items-center gap-2 rounded-full border-2 border-black bg-white px-8 py-4 text-base font-medium text-black transition-colors hover:bg-black hover:text-white dark:border-white dark:bg-gray-950 dark:text-white dark:hover:bg-white dark:hover:text-black"
          >
            查看文档
            <span className="i-mingcute-book-2-line text-xl" />
          </DocsLink>
        </div>

        {/* Homebrew 安装 */}
        <div className="mt-8 inline-flex items-stretch overflow-hidden rounded-lg border border-gray-300 bg-white shadow-sm dark:border-gray-700 dark:bg-gray-900">
          <div className="flex items-center gap-3 px-5 py-3 font-mono text-sm">
            <span className="text-gray-500 dark:text-gray-400">$</span>
            <code className="text-gray-900 select-all dark:text-gray-100">brew install wzz6423/tap/zshell</code>
          </div>
          <button
            onClick={() => {
              navigator.clipboard.writeText('brew install wzz6423/tap/zshell')
            }}
            className="border-l border-gray-300 px-4 transition-colors hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
            aria-label="复制命令"
          >
            <span className="i-mingcute-copy-2-line text-gray-600 dark:text-gray-400" />
          </button>
        </div>
      </div>

    </section>
  )
}
