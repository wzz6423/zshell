import { useEffect, useRef, useState } from 'react'
import { Canvas, useFrame } from '@react-three/fiber'
import { OrbitControls, Text, Html, Stars, Float } from '@react-three/drei'
import * as THREE from 'three'

/**
 * Three.js 介绍动画组件
 * 结合音乐和动画展示 zshell 项目特性
 */
export function ThreeIntroAnimation({ onComplete, onSkip }: { onComplete?: () => void; onSkip?: () => void }) {
  const [started, setStarted] = useState(false)
  const [audioContext, setAudioContext] = useState<AudioContext | null>(null)
  const [audioPlaying, setAudioPlaying] = useState(false)

  const startExperience = () => {
    setStarted(true)
    // 创建简单的背景音乐（使用 Web Audio API）
    const ctx = new AudioContext()
    setAudioContext(ctx)
    playBackgroundMusic(ctx)
    setAudioPlaying(true)
  }

  const skipIntro = () => {
    if (audioContext) {
      audioContext.close()
    }
    onSkip?.()
  }

  return (
    <div className="fixed inset-0 z-50 bg-gradient-to-br from-black via-gray-900 to-black">
      {!started ? (
        <div className="flex h-full flex-col items-center justify-center gap-8">
          <div className="text-center">
            <h1 className="mb-4 text-6xl font-bold text-white">zshell</h1>
            <p className="text-xl text-gray-400">原生 macOS 终端工作空间</p>
          </div>
          <div className="flex gap-4">
            <button
              onClick={startExperience}
              className="rounded-lg bg-green-500 px-8 py-4 text-lg font-semibold text-white transition-all hover:scale-105 hover:bg-green-600"
            >
              🎵 开始体验
            </button>
            <button
              onClick={skipIntro}
              className="rounded-lg border border-gray-600 px-8 py-4 text-lg font-semibold text-gray-400 transition-all hover:border-gray-400 hover:text-gray-200"
            >
              跳过介绍
            </button>
          </div>
        </div>
      ) : (
        <>
          <Canvas camera={{ position: [0, 0, 12], fov: 60 }}>
            <color attach="background" args={['#000000']} />
            <fog attach="fog" args={['#000000', 10, 50]} />

            {/* 星空背景 */}
            <Stars radius={100} depth={50} count={5000} factor={4} saturation={0} fade speed={1} />

            {/* 光源 */}
            <ambientLight intensity={0.3} />
            <pointLight position={[10, 10, 10]} intensity={1} color="#00ff00" />
            <pointLight position={[-10, -10, -10]} intensity={0.5} color="#0088ff" />
            <spotLight position={[0, 15, 0]} angle={0.3} penumbra={1} intensity={1} color="#ffffff" />

            <AnimatedScene onComplete={onComplete} audioPlaying={audioPlaying} />
            <OrbitControls
              enableZoom={false}
              enablePan={false}
              autoRotate
              autoRotateSpeed={0.5}
              minPolarAngle={Math.PI / 3}
              maxPolarAngle={Math.PI / 1.5}
            />
          </Canvas>

          {/* 跳过按钮 */}
          <button
            onClick={skipIntro}
            className="absolute right-8 top-8 rounded-lg border border-gray-600 px-4 py-2 text-sm text-gray-400 transition-all hover:border-gray-400 hover:text-gray-200"
          >
            跳过 →
          </button>
        </>
      )}
    </div>
  )
}

// 使用 Web Audio API 创建简单的背景音乐
function playBackgroundMusic(ctx: AudioContext) {
  const notes = [
    { freq: 261.63, time: 0.0 },    // C4
    { freq: 329.63, time: 0.3 },    // E4
    { freq: 392.00, time: 0.6 },    // G4
    { freq: 523.25, time: 0.9 },    // C5
    { freq: 392.00, time: 1.2 },    // G4
    { freq: 329.63, time: 1.5 },    // E4
  ]

  notes.forEach(({ freq, time }) => {
    const osc = ctx.createOscillator()
    const gain = ctx.createGain()

    osc.connect(gain)
    gain.connect(ctx.destination)

    osc.frequency.value = freq
    osc.type = 'sine'

    gain.gain.setValueAtTime(0, ctx.currentTime + time)
    gain.gain.linearRampToValueAtTime(0.1, ctx.currentTime + time + 0.05)
    gain.gain.exponentialRampToValueAtTime(0.01, ctx.currentTime + time + 0.3)

    osc.start(ctx.currentTime + time)
    osc.stop(ctx.currentTime + time + 0.3)
  })

  // 循环播放
  setTimeout(() => {
    if (ctx.state === 'running') {
      playBackgroundMusic(ctx)
    }
  }, 1800)
}

function AnimatedScene({ onComplete, audioPlaying }: { onComplete?: () => void; audioPlaying: boolean }) {
  const groupRef = useRef<THREE.Group>(null)
  const [phase, setPhase] = useState(0)
  const [progress, setProgress] = useState(0)

  useFrame((state, delta) => {
    if (!groupRef.current) return

    // 更新进度
    setProgress(prev => {
      const newProgress = prev + delta * 0.2

      // 阶段切换
      if (newProgress > 1 && phase < 5) {
        setPhase(p => p + 1)
        return 0
      }

      // 动画结束
      if (phase >= 5 && newProgress > 2) {
        setTimeout(() => onComplete?.(), 500)
      }

      return newProgress
    })

    // 整体旋转动画
    if (phase === 0) {
      groupRef.current.rotation.y = Math.sin(state.clock.elapsedTime * 0.5) * 0.3
    }

    // 音频驱动的脉动效果
    if (audioPlaying) {
      const pulse = Math.sin(state.clock.elapsedTime * 3) * 0.05 + 1
      groupRef.current.scale.set(pulse, pulse, pulse)
    }
  })

  return (
    <group ref={groupRef}>
      <TerminalWindow phase={phase} progress={progress} />
      <FloatingText phase={phase} progress={progress} />
      <FeatureCircles phase={phase} progress={progress} />
      <ParticleField phase={phase} />
    </group>
  )
}

function TerminalWindow({ phase, progress }: { phase: number; progress: number }) {
  const meshRef = useRef<THREE.Mesh>(null)

  useFrame((state) => {
    if (!meshRef.current) return

    // 窗口动画
    if (phase === 0) {
      // 初始旋转进入
      meshRef.current.rotation.y = (1 - progress) * Math.PI * 2
      meshRef.current.position.y = (1 - progress) * 5
    } else if (phase === 2) {
      // 缩放动画
      const scale = 1 + Math.sin(progress * Math.PI) * 0.2
      meshRef.current.scale.set(scale, scale, scale)
    }

    // 持续的微小浮动
    meshRef.current.position.y += Math.sin(state.clock.elapsedTime * 2) * 0.002
  })

  return (
    <Float speed={1.5} rotationIntensity={0.2} floatIntensity={0.5}>
      <group>
        {/* 终端窗口主体 */}
        <mesh ref={meshRef} position={[0, 0, 0]} castShadow>
          <boxGeometry args={[5, 3, 0.15]} />
          <meshStandardMaterial
            color="#1a1a1a"
            metalness={0.5}
            roughness={0.3}
            emissive="#00ff00"
            emissiveIntensity={0.1}
          />
        </mesh>

        {/* 窗口发光边框 */}
        <mesh position={[0, 0, -0.08]}>
          <boxGeometry args={[5.2, 3.2, 0.05]} />
          <meshStandardMaterial
            color="#00ff00"
            emissive="#00ff00"
            emissiveIntensity={0.5}
            transparent
            opacity={0.3}
          />
        </mesh>

        {/* 标题栏 */}
        <mesh position={[0, 1.35, 0.08]}>
          <boxGeometry args={[5, 0.4, 0.05]} />
          <meshStandardMaterial color="#2a2a2a" metalness={0.8} roughness={0.2} />
        </mesh>

        {/* 窗口按钮 */}
        {[-2, -1.7, -1.4].map((x, i) => (
          <mesh key={i} position={[x, 1.35, 0.11]}>
            <sphereGeometry args={[0.08, 16, 16]} />
            <meshStandardMaterial
              color={i === 0 ? '#ff5f56' : i === 1 ? '#ffbd2e' : '#27c93f'}
              emissive={i === 0 ? '#ff5f56' : i === 1 ? '#ffbd2e' : '#27c93f'}
              emissiveIntensity={0.3}
            />
          </mesh>
        ))}

        {/* 代码内容 */}
        {phase >= 1 && (
          <Html
            position={[-2.2, 0.5, 0.12]}
            transform
            occlude
            style={{
              width: '420px',
              fontSize: '14px',
              fontFamily: 'Monaco, Menlo, monospace',
              color: '#00ff00',
              pointerEvents: 'none',
              textShadow: '0 0 10px rgba(0,255,0,0.5)',
            }}
          >
            <div className="space-y-2">
              <div style={{ opacity: Math.min(progress * 2, 1) }}>
                <span style={{ color: '#00ff00' }}>❯</span> <span style={{ color: '#00aaff' }}>cd</span> ~/code/zshell
              </div>
              {progress > 0.2 && (
                <div style={{ opacity: Math.min((progress - 0.2) * 2, 1) }}>
                  <span style={{ color: '#00ff00' }}>❯</span> <span style={{ color: '#00aaff' }}>git</span> status
                </div>
              )}
              {progress > 0.4 && (
                <div style={{ opacity: Math.min((progress - 0.4) * 2, 1), color: '#888' }}>
                  <span style={{ color: '#00ff00' }}>M</span> src/workspace.ts
                </div>
              )}
              {progress > 0.5 && (
                <div style={{ opacity: Math.min((progress - 0.5) * 2, 1), color: '#888' }}>
                  <span style={{ color: '#00ff00' }}>M</span> src/theme.css
                </div>
              )}
              {progress > 0.7 && (
                <div style={{ opacity: Math.min((progress - 0.7) * 2, 1) }}>
                  <span style={{ color: '#00ff00' }}>❯</span> <span style={{ color: '#00aaff' }}>bun</span> run dev
                </div>
              )}
              {progress > 0.85 && (
                <div style={{ opacity: Math.min((progress - 0.85) * 2, 1), color: '#ffbd2e' }}>
                  ✓ Server running at localhost:3000
                </div>
              )}
            </div>
          </Html>
        )}
      </group>
    </Float>
  )
}

function FloatingText({ phase, progress }: { phase: number; progress: number }) {
  const features = [
    { text: 'zshell', size: 0.8, color: '#00ff00', position: [0, 4, 0] as [number, number, number] },
    { text: '原生 macOS 终端工作空间', size: 0.35, color: '#ffffff', position: [0, 3, 0] as [number, number, number] },
    { text: '📁 项目管理', size: 0.3, color: '#00aaff', position: [-3, -3, 1] as [number, number, number] },
    { text: '🎨 分屏布局', size: 0.3, color: '#ff00aa', position: [3, -3, 1] as [number, number, number] },
    { text: '⚡️ 快速启动', size: 0.3, color: '#ffbd2e', position: [-3, -4, 1] as [number, number, number] },
    { text: '🔧 高度定制', size: 0.3, color: '#27c93f', position: [3, -4, 1] as [number, number, number] },
  ]

  return (
    <>
      {phase >= 3 && features.map((item, index) => {
        const delay = index * 0.15
        const opacity = Math.max(0, Math.min(1, (progress - delay) * 3))

        if (opacity <= 0) return null

        return (
          <Float key={item.text} speed={2} rotationIntensity={0.3} floatIntensity={0.8}>
            <Text
              position={item.position}
              fontSize={item.size}
              color={item.color}
              anchorX="center"
              anchorY="middle"
              fillOpacity={opacity}
              outlineWidth={0.02}
              outlineColor="#000000"
              font="/fonts/inter-bold.woff"
            >
              {item.text}
            </Text>
          </Float>
        )
      })}
    </>
  )
}

function FeatureCircles({ phase, progress }: { phase: number; progress: number }) {
  const circleRefs = useRef<THREE.Mesh[]>([])

  useFrame((state) => {
    circleRefs.current.forEach((mesh, i) => {
      if (!mesh) return
      const time = state.clock.elapsedTime
      mesh.rotation.z = time * (0.5 + i * 0.2)
      mesh.position.y = Math.sin(time * 2 + i) * 0.3
    })
  })

  if (phase < 4) return null

  const circles = [
    { radius: 6, color: '#00ff00', opacity: 0.1 },
    { radius: 7, color: '#00aaff', opacity: 0.08 },
    { radius: 8, color: '#ff00aa', opacity: 0.06 },
  ]

  return (
    <>
      {circles.map((circle, i) => {
        const opacity = Math.min(progress * 2, 1) * circle.opacity

        return (
          <mesh
            key={i}
            ref={(el) => {
              if (el) circleRefs.current[i] = el
            }}
            rotation={[Math.PI / 2, 0, 0]}
          >
            <torusGeometry args={[circle.radius, 0.05, 16, 100]} />
            <meshStandardMaterial
              color={circle.color}
              emissive={circle.color}
              emissiveIntensity={0.5}
              transparent
              opacity={opacity}
            />
          </mesh>
        )
      })}
    </>
  )
}

function ParticleField({ phase }: { phase: number }) {
  const particlesRef = useRef<THREE.Points>(null)
  const particleCount = 200

  useFrame((state) => {
    if (!particlesRef.current) return
    particlesRef.current.rotation.y = state.clock.elapsedTime * 0.05
  })

  if (phase < 2) return null

  const positions = new Float32Array(particleCount * 3)
  for (let i = 0; i < particleCount; i++) {
    positions[i * 3] = (Math.random() - 0.5) * 20
    positions[i * 3 + 1] = (Math.random() - 0.5) * 20
    positions[i * 3 + 2] = (Math.random() - 0.5) * 20
  }

  return (
    <points ref={particlesRef}>
      <bufferGeometry>
        <bufferAttribute
          attach="attributes-position"
          args={[positions, 3]}
        />
      </bufferGeometry>
      <pointsMaterial
        size={0.05}
        color="#00ff00"
        transparent
        opacity={0.6}
        sizeAttenuation
      />
    </points>
  )
}
