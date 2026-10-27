import { useEffect, useRef, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { DocsLink } from '@/components/site-links'
import type { HomeCopy, Release } from '@/lib/home-copy'
import { cn } from '@/lib/utils'

/**
 * 现代化的 Hero 区域，带有粒子动画和渐变背景
 */
export function AnimatedHero({ lang, copy, release }: { lang: string; copy: HomeCopy; release: Release }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [mousePos, setMousePos] = useState({ x: 0, y: 0 })

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const ctx = canvas.getContext('2d')
    if (!ctx) return

    // 设置 canvas 尺寸
    const resizeCanvas = () => {
      canvas.width = canvas.offsetWidth * window.devicePixelRatio
      canvas.height = canvas.offsetHeight * window.devicePixelRatio
      ctx.scale(window.devicePixelRatio, window.devicePixelRatio)
    }
    resizeCanvas()
    window.addEventListener('resize', resizeCanvas)

    // 粒子系统
    class Particle {
      x: number
      y: number
      vx: number
      vy: number
      life: number
      maxLife: number

      constructor(x: number, y: number) {
        this.x = x
        this.y = y
        this.vx = (Math.random() - 0.5) * 2
        this.vy = (Math.random() - 0.5) * 2
        this.life = 0
        this.maxLife = 100 + Math.random() * 100
      }

      update() {
        this.x += this.vx
        this.y += this.vy
        this.life++
        this.vx *= 0.99
        this.vy *= 0.99
      }

      draw(ctx: CanvasRenderingContext2D) {
        const opacity = 1 - this.life / this.maxLife
        const size = 2 + Math.random() * 2

        ctx.fillStyle = `rgba(0, 255, 100, ${opacity * 0.6})`
        ctx.beginPath()
        ctx.arc(this.x, this.y, size, 0, Math.PI * 2)
        ctx.fill()
      }

      isDead() {
        return this.life >= this.maxLife
      }
    }

    const particles: Particle[] = []
    let animationFrame: number

    const animate = () => {
      const width = canvas.offsetWidth
      const height = canvas.offsetHeight

      // 清除画布，使用渐变背景
      const gradient = ctx.createLinearGradient(0, 0, width, height)
      gradient.addColorStop(0, 'rgba(0, 0, 0, 0.05)')
      gradient.addColorStop(1, 'rgba(0, 100, 50, 0.05)')
      ctx.fillStyle = gradient
      ctx.fillRect(0, 0, width, height)

      // 添加新粒子
      if (Math.random() < 0.3) {
        particles.push(new Particle(
          Math.random() * width,
          Math.random() * height
        ))
      }

      // 更新和绘制粒子
      for (let i = particles.length - 1; i >= 0; i--) {
        particles[i].update()
        particles[i].draw(ctx)

        if (particles[i].isDead()) {
          particles.splice(i, 1)
        }
      }

      // 绘制连线
      ctx.strokeStyle = 'rgba(0, 255, 100, 0.1)'
      ctx.lineWidth = 1
      for (let i = 0; i < particles.length; i++) {
        for (let j = i + 1; j < particles.length; j++) {
          const dx = particles[i].x - particles[j].x
          const dy = particles[i].y - particles[j].y
          const distance = Math.sqrt(dx * dx + dy * dy)

          if (distance < 100) {
            ctx.beginPath()
            ctx.moveTo(particles[i].x, particles[i].y)
            ctx.lineTo(particles[j].x, particles[j].y)
            ctx.stroke()
          }
        }
      }

      animationFrame = requestAnimationFrame(animate)
    }

    animate()

    return () => {
      cancelAnimationFrame(animationFrame)
      window.removeEventListener('resize', resizeCanvas)
    }
  }, [])

  // 鼠标移动效果
  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      setMousePos({
        x: (e.clientX / window.innerWidth) * 2 - 1,
        y: (e.clientY / window.innerHeight) * 2 - 1,
      })
    }

    window.addEventListener('mousemove', handleMouseMove)
    return () => window.removeEventListener('mousemove', handleMouseMove)
  }, [])

  return (
    <section className="relative min-h-screen overflow-hidden bg-gradient-to-br from-black via-gray-900 to-black">
      {/* 粒子画布 */}
      <canvas
        ref={canvasRef}
        className="absolute inset-0 h-full w-full"
        style={{
          transform: `translate(${mousePos.x * 10}px, ${mousePos.y * 10}px)`,
          transition: 'transform 0.3s ease-out',
        }}
      />

      {/* 渐变光晕 */}
      <div className="absolute inset-0 overflow-hidden">
        <div
          className="absolute -left-1/4 -top-1/4 h-1/2 w-1/2 rounded-full bg-green-500/20 blur-[120px]"
          style={{
            transform: `translate(${mousePos.x * 30}px, ${mousePos.y * 30}px)`,
          }}
        />
        <div
          className="absolute -right-1/4 -bottom-1/4 h-1/2 w-1/2 rounded-full bg-gray-500/20 blur-[120px]"
          style={{
            transform: `translate(${-mousePos.x * 30}px, ${-mousePos.y * 30}px)`,
          }}
        />
      </div>

      {/* 内容 */}
      <div className="relative z-10 flex min-h-screen flex-col items-center justify-center px-6 text-center">
        <div className="animate-fade-in-up">
          <h1 className="mb-6 text-6xl font-bold tracking-tight text-white md:text-8xl">
            <span className="bg-gradient-to-r from-green-400 via-blue-500 to-purple-600 bg-clip-text text-transparent">
              zshell
            </span>
          </h1>

          <p className="mb-4 text-xl text-gray-300 md:text-2xl">
            {copy.hero.titleBefore}
            <span className="font-semibold text-green-400">{copy.hero.titleHighlight}</span>
            {copy.hero.titleAfter}
          </p>

          <p className="mx-auto mb-12 max-w-2xl text-base text-gray-400 md:text-lg">
            {copy.hero.lede}
          </p>

          <div className="flex flex-wrap items-center justify-center gap-4">
            <a
              href={release.dmg}
              download
              className="group relative inline-flex items-center gap-2 overflow-hidden rounded-full bg-green-500 px-8 py-4 font-semibold text-white transition-all hover:bg-green-600 hover:shadow-lg hover:shadow-green-500/50"
            >
              <span className="relative z-10 flex items-center gap-2">
                <span className="i-mingcute-apple-fill text-xl" />
                {copy.hero.download}
              </span>
              <div className="absolute inset-0 -z-0 bg-gradient-to-r from-gray-600 to-gray-800 opacity-0 transition-opacity group-hover:opacity-100" />
            </a>

            <DocsLink
              lang={lang}
              className="inline-flex items-center gap-2 rounded-full border border-gray-700 px-8 py-4 font-semibold text-gray-300 transition-all hover:border-green-500 hover:text-green-400"
            >
              {copy.hero.docs}
              <span className="i-mingcute-arrow-right-line text-xl" />
            </DocsLink>
          </div>
        </div>

        {/* 滚动提示 */}
        <div className="absolute bottom-8 left-1/2 -translate-x-1/2 animate-bounce">
          <div className="flex flex-col items-center gap-2 text-gray-500">
            <span className="text-sm">向下滚动探索更多</span>
            <span className="i-mingcute-arrow-down-line text-2xl" />
          </div>
        </div>
      </div>
    </section>
  )
}
