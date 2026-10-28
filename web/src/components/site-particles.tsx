import { useEffect, useRef } from 'react'
import * as THREE from 'three'

// Adapted from Zisla's website ambient particles (web/src/main.ts).
// PolyForm Noncommercial License 1.0.0: https://polyformproject.org/licenses/noncommercial/1.0.0
// Required Notice: Copyright 2026 Zisla Contributors (https://github.com/wzz6423/zisla)
export function SiteParticles() {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return
    const reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)')
    const scene = new THREE.Scene()
    const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 1, 2000)
    camera.position.set(0, 0, 800)

    // A fresh canvas avoids reusing a lost WebGL context when React replays effects.
    const canvas = document.createElement('canvas')
    let renderer: THREE.WebGLRenderer
    try {
      renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true })
    } catch (error) {
      console.warn('Zshell particle background is unavailable.', error)
      return
    }
    container.append(canvas)
    renderer.setClearColor(0x09090b, 0)
    renderer.setSize(window.innerWidth, window.innerHeight)
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))

    const circleTexture = (() => {
      const cnv = document.createElement('canvas')
      cnv.width = cnv.height = 32
      const ctx = cnv.getContext('2d')!
      const gradient = ctx.createRadialGradient(16, 16, 0, 16, 16, 16)
      gradient.addColorStop(0, 'rgba(250,250,250,1)')
      gradient.addColorStop(0.5, 'rgba(250,250,250,0.5)')
      gradient.addColorStop(1, 'rgba(250,250,250,0)')
      ctx.fillStyle = gradient
      ctx.beginPath()
      ctx.arc(16, 16, 16, 0, Math.PI * 2)
      ctx.fill()
      return new THREE.CanvasTexture(cnv)
    })()

    const ambientCount = 520
    const ambientGeometry = new THREE.BufferGeometry()
    const ambientMaterial = new THREE.PointsMaterial({
      size: 3.6,
      sizeAttenuation: false,
      transparent: true,
      map: circleTexture,
      depthWrite: false,
    })
    const ambientSeeds = Array.from({ length: ambientCount }, () =>
      new THREE.Vector3(Math.random(), Math.random(), (Math.random() - 0.5) * 240),
    )
    ambientGeometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(ambientCount * 3), 3))
    scene.add(new THREE.Points(ambientGeometry, ambientMaterial))

    let viewHeight = 2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * camera.position.z
    let viewWidth = viewHeight * camera.aspect
    let animationId: number | undefined
    const clock = new THREE.Clock()
    let elapsed = 0

    const renderFrame = () => {
      const delta = reducedMotionQuery.matches ? 0 : Math.min(clock.getDelta(), 0.05)
      elapsed += delta
      const positions = ambientGeometry.attributes.position.array as Float32Array
      for (let i = 0; i < ambientCount; i++) {
        const i3 = i * 3
        const seed = ambientSeeds[i]
        const depthScale = (camera.position.z - seed.z) / camera.position.z
        const width = viewWidth * depthScale + 64
        const height = viewHeight * depthScale + 64
        positions[i3] = ((seed.x + elapsed * (0.004 + i % 5 * 0.0008)) % 1 - 0.5) * width
          + Math.sin(elapsed * 0.45 + i) * 10
        positions[i3 + 1] = ((seed.y + elapsed * (0.012 + i % 7 * 0.0015)) % 1 - 0.5) * height
        positions[i3 + 2] = seed.z
      }
      ambientGeometry.attributes.position.needsUpdate = true
      renderer.render(scene, camera)
    }

    const animate = () => {
      animationId = undefined
      renderFrame()
      if (!document.hidden && !reducedMotionQuery.matches) animationId = requestAnimationFrame(animate)
    }
    const updateMotion = () => {
      if (animationId !== undefined) cancelAnimationFrame(animationId)
      animationId = undefined
      clock.stop()
      if (document.hidden) return
      clock.start()
      animate()
    }
    const updateTheme = () => {
      const styles = getComputedStyle(document.documentElement)
      ambientMaterial.color.set(styles.getPropertyValue('--particle-color').trim())
      ambientMaterial.blending = document.documentElement.classList.contains('dark')
        ? THREE.AdditiveBlending : THREE.NormalBlending
      ambientMaterial.opacity = Number(styles.getPropertyValue('--particle-opacity'))
      if (!document.hidden) renderer.render(scene, camera)
    }
    const handleResize = () => {
      camera.aspect = window.innerWidth / window.innerHeight
      camera.updateProjectionMatrix()
      renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
      renderer.setSize(window.innerWidth, window.innerHeight)
      viewHeight = 2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * camera.position.z
      viewWidth = viewHeight * camera.aspect
      if (!document.hidden) renderFrame()
    }
    const themeObserver = new MutationObserver(updateTheme)
    themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] })
    window.addEventListener('resize', handleResize)
    document.addEventListener('visibilitychange', updateMotion)
    reducedMotionQuery.addEventListener('change', updateMotion)
    updateTheme()
    updateMotion()

    return () => {
      if (animationId !== undefined) cancelAnimationFrame(animationId)
      clock.stop()
      themeObserver.disconnect()
      window.removeEventListener('resize', handleResize)
      document.removeEventListener('visibilitychange', updateMotion)
      reducedMotionQuery.removeEventListener('change', updateMotion)
      ambientGeometry.dispose()
      ambientMaterial.dispose()
      circleTexture.dispose()
      scene.clear()
      renderer.dispose()
      renderer.forceContextLoss()
      canvas.remove()
    }
  }, [])

  return <div ref={containerRef} className="site-particles" aria-hidden="true" />
}
