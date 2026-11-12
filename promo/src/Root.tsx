import './index.css';
import { Composition } from 'remotion';
import { loadFonts } from './fonts';
import { LaunchVideo } from './LaunchVideo';
import { FPS, HEIGHT, TOTAL_FRAMES, WIDTH } from './timeline';

loadFonts();

export const Root = () => (
  <Composition
    id="LaunchVideo"
    component={LaunchVideo}
    durationInFrames={TOTAL_FRAMES}
    fps={FPS}
    width={WIDTH}
    height={HEIGHT}
  />
);
