import '@fontsource-variable/geist/wght.css';
import '@fontsource-variable/jetbrains-mono/wght.css';
import { cancelRender, continueRender, delayRender } from 'remotion';

const FAMILIES = ['JetBrains Mono Variable', 'Geist Variable'];

// A face declared by CSS only downloads once a glyph needs it, which is too
// late for a frame that is already being captured, so every face is forced.
export const loadFonts = () => {
  const handle = delayRender('Loading fonts');
  const faces = Array.from(document.fonts).filter((face) =>
    FAMILIES.some((family) => face.family.includes(family)),
  );
  Promise.all(faces.map((face) => face.load()))
    .then(() => continueRender(handle))
    .catch((error) => cancelRender(error));
};
