import '@fontsource-variable/inter';
import { Composition } from 'remotion';
import { Film } from './Film';
import { DURATION, FPS } from './lib/time';

export const Root: React.FC = () => (
  <Composition id="WinMuxIntro" component={Film} durationInFrames={Math.round(DURATION * FPS)} fps={FPS} width={1920} height={1080} />
);
