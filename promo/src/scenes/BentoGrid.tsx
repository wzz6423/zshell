import type { ReactNode } from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { SceneLabel } from '../components/Hud';
import { AgentIcon, BranchIcon, DiffIcon, GlobeIcon, TerminalIcon } from '../components/Icons';
import { FOOTNOTES } from '../data/product';
import { during, linear, pop, SPRING } from '../lib/motion';
import { color, type Tone } from '../theme';
import { SCENES } from '../timeline';
import { AgentsCard, BentoCard, ReviewCard, type CardProps } from './BentoCards';
import { RemoteCard, WorktreeCard } from './BentoCardsExtra';
import { GitCard } from './BentoCardsGit';
import { AnywhereCard } from './BentoCardsAnywhere';

type CardSpec = {
  span: number;
  tone: Tone;
  icon: ReactNode;
  en: string;
  zh: string;
  Body: (props: CardProps) => ReactNode;
};

// Two rows of twelve columns: 5/4/3 over 3/4/5, so no two wide cards stack.
const CARDS: CardSpec[] = [
  { span: 5, tone: 'cyan', icon: <BranchIcon size={24} />, en: 'Git, close at hand', zh: '审阅、暂存、提交、推送', Body: GitCard },
  { span: 4, tone: 'green', icon: <DiffIcon size={24} />, en: 'Review every turn', zh: '逐轮审阅改动', Body: ReviewCard },
  { span: 3, tone: 'amber', icon: <AgentIcon size={24} />, en: 'Agent status', zh: '多智能体协同', Body: AgentsCard },
  { span: 3, tone: 'violet', icon: <BranchIcon size={24} />, en: 'Worktree sessions', zh: 'Worktree 会话', Body: WorktreeCard },
  { span: 4, tone: 'blue', icon: <GlobeIcon size={24} />, en: 'Remote sessions', zh: '远程会话', Body: RemoteCard },
  { span: 5, tone: 'pink', icon: <TerminalIcon size={24} />, en: 'Terminal, anywhere', zh: '随处唤出，跨设备接续', Body: AnywhereCard },
];

export const BentoGrid = () => {
  const tempo = 540 / SCENES.bentoGrid.duration;
  const frame = useCurrentFrame() * tempo;
  const fps = useVideoConfig().fps * tempo;
  const chrome = during(frame, 6, 530, 14);

  return (
    <AbsoluteFill style={{ opacity: linear(frame, [522, 540], [1, 0]) }}>
      <SceneLabel index="14" en="Everything in one window" zh="一个窗口，全部就位" opacity={chrome} />

      <div
        style={{
          position: 'absolute',
          left: 72,
          right: 72,
          top: 116,
          bottom: 104,
          display: 'grid',
          gridTemplateColumns: 'repeat(12, 1fr)',
          gridTemplateRows: '1fr 1fr',
          gap: 22,
        }}
      >
        {CARDS.map(({ Body, ...card }, index) => (
          <BentoCard key={card.en} {...card} enter={pop(frame, fps, 10 + index * 9, SPRING.snappy)}>
            <Body frame={frame} fps={fps} />
          </BentoCard>
        ))}
      </div>

      <div
        className="font-sans"
        style={{ position: 'absolute', left: 0, right: 0, bottom: 44, display: 'flex', justifyContent: 'center', gap: 44, fontSize: 20 }}
      >
        {FOOTNOTES.map((note, index) => (
          <span key={note.en} style={{ display: 'flex', alignItems: 'baseline', gap: 10, opacity: linear(frame, [80 + index * 10, 100 + index * 10]) * chrome }}>
            <span style={{ fontWeight: 600, color: color.fg }}>{note.en}</span>
            <span style={{ fontSize: 16, color: color.muted }}>{note.zh}</span>
          </span>
        ))}
      </div>
    </AbsoluteFill>
  );
};
