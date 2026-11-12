import { AbsoluteFill, Html5Audio, Sequence, staticFile } from 'remotion';
import { Backdrop } from './components/Backdrop';
import { Awakening } from './scenes/Awakening';
import { BentoGrid } from './scenes/BentoGrid';
import { Outro } from './scenes/Outro';
import { UnderTheHood } from './scenes/UnderTheHood';
import { Workflow } from './scenes/Workflow';
import { FeatureCatalog } from './scenes/catalog/Catalog';
import { SCENES } from './timeline';

export const LaunchVideo = () => (
  <AbsoluteFill>
    <Html5Audio src={staticFile('audio/tears-in-rain-tour.mp3')} />
    <Backdrop />
    <Sequence name="1 · The Terminal Awakening" from={SCENES.awakening.from} durationInFrames={SCENES.awakening.duration}>
      <Awakening />
    </Sequence>
    <Sequence name="2 · Speed & Core Workflow" from={SCENES.workflow.from} durationInFrames={SCENES.workflow.duration}>
      <Workflow />
    </Sequence>
    <Sequence name="3 · Under the Hood" from={SCENES.underTheHood.from} durationInFrames={SCENES.underTheHood.duration}>
      <UnderTheHood />
    </Sequence>
    <Sequence name="4 · Complete feature tour" from={SCENES.catalog.from} durationInFrames={SCENES.catalog.duration}>
      <FeatureCatalog />
    </Sequence>
    <Sequence name="5 · Feature Bento Grid" from={SCENES.bentoGrid.from} durationInFrames={SCENES.bentoGrid.duration}>
      <BentoGrid />
    </Sequence>
    <Sequence name="6 · Outro & Get Started" from={SCENES.outro.from} durationInFrames={SCENES.outro.duration}>
      <Outro />
    </Sequence>
  </AbsoluteFill>
);
