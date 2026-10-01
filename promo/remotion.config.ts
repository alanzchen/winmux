import { Config } from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(95);
Config.setOverwriteOutput(true);
// Metal-backed ANGLE on macOS: much faster CSS filters and compositing than the software default.
Config.setChromiumOpenGlRenderer('angle');
