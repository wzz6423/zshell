/**
 * @pierre/diffs bundle entry point for ClaudeCodeUI
 *
 * This file is bundled with esbuild and loaded into a WKWebView.
 * It exposes the @pierre/diffs library and a bridge for Swift communication.
 */

import { CodeView, FileDiff, parseDiffFromFile } from '@pierre/diffs';
import { Editor } from '@pierre/diffs/edit';
import {
  getOrCreateWorkerPoolSingleton,
  terminateWorkerPoolSingleton,
} from '@pierre/diffs/worker';
import workerSource from './generated/worker-source.js';

// Global state
let currentDiffInstance = null;
let currentTheme = 'pierre-dark';
let currentThemeConfig = {
  dark: 'pierre-dark',
  light: 'pierre-light',
};
let currentDiffStyle = 'split';
let currentOverflow = 'scroll';
let currentOldFile = null;
let currentNewFile = null;

// Multi-file state — the CodeView surface rendered by `renderFiles`. Only one
// of `currentDiffInstance` / `currentCodeView` is ever live at a time.
let currentCodeView = null;
let currentCodeViewOptions = null;
/** Scroll request that arrived before its file existed; applied after setItems. */
let pendingScrollTarget = null;

/**
 * Highlight worker pool for the multi-file surface. `undefined` means it has
 * not been tried yet, `null` that workers are unavailable and highlighting
 * falls back to the main thread.
 */
let workerPool;
let workerBlobURL = null;
/** Serialized render options the workers were last told about. */
let workerRenderOptions = null;
/**
 * Two workers keep a scroll ahead of the reader without paying for a Shiki
 * instance per core — each worker carries its own copy of the highlighter.
 */
const WORKER_POOL_SIZE = 2;
/** Cap on files whose highlighting is warmed up front. */
const MAX_PRIMED_FILES = 60;

/**
 * Sends a message to Swift via webkit message handler
 */
function postToSwift(type, payload = {}) {
  if (window.webkit?.messageHandlers?.diffBridge) {
    window.webkit.messageHandlers.diffBridge.postMessage({
      type,
      ...payload,
    });
  } else {
    console.warn('Swift message handler not available');
  }
}

/**
 * Gets the container element, creating it if necessary
 */
function getContainer() {
  let container = document.getElementById('diff-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'diff-container';
    document.body.appendChild(container);
  }
  return container;
}

/**
 * Runs a DOM update without letting WebKit snap the scroll container back to
 * the top while rows are replaced or resized.
 */
function preservingScrollPosition(update) {
  const container = getContainer();
  const scrollTop = container.scrollTop;
  const scrollLeft = container.scrollLeft;

  const restore = () => {
    container.scrollTop = scrollTop;
    container.scrollLeft = scrollLeft;
  };

  const result = update(container);
  restore();
  requestAnimationFrame(restore);
  setTimeout(restore, 0);
  return result;
}

/**
 * Default font stack matching PierreDiffsSwift historical CSS defaults.
 */
const DEFAULT_FONT = {
  family: "ui-monospace, 'SF Mono', Menlo, Monaco, 'Cascadia Code', 'Roboto Mono', monospace",
  size: '12px',
  lineHeight: '1.5',
  headerFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
  tabSize: 2,
  faces: [],
};

const FONT_FACE_STYLE_ID = 'pierre-font-faces';

const FONT_FORMAT_MIME = {
  truetype: 'font/ttf',
  opentype: 'font/otf',
  woff: 'font/woff',
  woff2: 'font/woff2',
};

/**
 * Escapes a string for use inside a single-quoted CSS value.
 */
function escapeCSSString(value) {
  return String(value ?? '').replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

/**
 * Injects (or clears) @font-face rules for bundled font bytes.
 * Fonts are embedded as data URLs so they work with loadHTMLString(baseURL: nil).
 */
function applyFontFaces(faces) {
  let styleEl = document.getElementById(FONT_FACE_STYLE_ID);
  if (!styleEl) {
    styleEl = document.createElement('style');
    styleEl.id = FONT_FACE_STYLE_ID;
    document.head.appendChild(styleEl);
  }

  if (!Array.isArray(faces) || faces.length === 0) {
    styleEl.textContent = '';
    return;
  }

  const rules = [];
  for (const face of faces) {
    if (!face || !face.family || !face.data) continue;
    const format = face.format || 'truetype';
    const mime = FONT_FORMAT_MIME[format] || 'font/ttf';
    const family = escapeCSSString(face.family);
    const weight = face.weight || 'normal';
    const fontStyle = face.style || 'normal';
    // data is base64 from Swift; keep as-is (no CSS escaping needed for base64 alphabet)
    rules.push(
      `@font-face{font-family:'${family}';src:url(data:${mime};base64,${face.data}) format('${format}');font-weight:${weight};font-style:${fontStyle};font-display:swap;}`
    );
  }
  styleEl.textContent = rules.join('\n');
}

/**
 * Applies font CSS custom properties that @pierre/diffs reads via
 * --diffs-font-family / --diffs-font-size / etc. (inherits into Shadow DOM).
 * Also injects bundled @font-face rules when `faces` are provided.
 */
function applyFontOptions(fontOptions) {
  const font = {
    ...DEFAULT_FONT,
    ...(fontOptions || {}),
  };

  applyFontFaces(font.faces);

  const root = document.documentElement;
  root.style.setProperty('--diffs-font-family', font.family);
  root.style.setProperty('--diffs-font-size', font.size);
  root.style.setProperty('--diffs-line-height', font.lineHeight);
  root.style.setProperty('--diffs-header-font-family', font.headerFamily);
  root.style.setProperty('--diffs-tab-size', String(font.tabSize));

  // Keep light-DOM body styles in sync with the shadow-DOM host vars.
  document.body.style.fontFamily = font.family;
  document.body.style.fontSize = font.size;
  document.body.style.lineHeight = font.lineHeight;
  document.body.style.tabSize = String(font.tabSize);
}

/**
 * Detects the language from a filename
 */
function detectLanguage(fileName) {
  if (!fileName) return undefined;

  const ext = fileName.split('.').pop()?.toLowerCase();
  const langMap = {
    // Swift & Apple
    swift: 'swift',
    m: 'objective-c',
    mm: 'objective-c',
    h: 'c',

    // JavaScript ecosystem
    js: 'javascript',
    jsx: 'jsx',
    ts: 'typescript',
    tsx: 'tsx',
    mjs: 'javascript',
    cjs: 'javascript',

    // Python
    py: 'python',
    pyw: 'python',
    pyi: 'python',

    // Go
    go: 'go',

    // Rust
    rs: 'rust',

    // Java & JVM
    java: 'java',
    kt: 'kotlin',
    kts: 'kotlin',
    scala: 'scala',

    // C family
    c: 'c',
    cpp: 'cpp',
    cc: 'cpp',
    cxx: 'cpp',
    hpp: 'cpp',
    hxx: 'cpp',

    // Ruby
    rb: 'ruby',
    erb: 'erb',

    // PHP
    php: 'php',

    // Shell
    sh: 'bash',
    bash: 'bash',
    zsh: 'bash',
    fish: 'fish',

    // Data formats
    json: 'json',
    yaml: 'yaml',
    yml: 'yaml',
    toml: 'toml',
    xml: 'xml',
    plist: 'xml',

    // Web
    html: 'html',
    htm: 'html',
    css: 'css',
    scss: 'scss',
    sass: 'sass',
    less: 'less',

    // Database
    sql: 'sql',

    // Markdown & docs
    md: 'markdown',
    mdx: 'mdx',
    rst: 'rst',

    // Config
    dockerfile: 'dockerfile',
    graphql: 'graphql',
    gql: 'graphql',

    // Other
    zig: 'zig',
    lua: 'lua',
    r: 'r',
    ps1: 'powershell',
    psm1: 'powershell',
  };

  // Handle special filenames
  const lowerFileName = fileName.toLowerCase();
  if (lowerFileName === 'dockerfile') return 'dockerfile';
  if (lowerFileName === 'makefile') return 'makefile';
  if (lowerFileName.endsWith('.d.ts')) return 'typescript';

  return langMap[ext] || undefined;
}

/**
 * Creates a DOM element for an inline annotation (comment).
 * Called by @pierre/diffs renderAnnotation callback.
 */
function createAnnotationDOM(annotation) {
  const { metadata } = annotation;
  if (!metadata) return document.createElement('div');

  const container = document.createElement('div');
  container.className = 'pierre-annotation';
  container.dataset.annotationId = metadata.id || '';

  const row = document.createElement('div');
  row.className = 'pierre-annotation-row';

  // Avatar — SVG person icon (or image if avatarURL provided)
  const avatar = document.createElement('div');
  avatar.className = 'pierre-annotation-avatar';
  if (metadata.avatarURL) {
    const img = document.createElement('img');
    img.src = metadata.avatarURL;
    img.alt = metadata.author || '';
    avatar.appendChild(img);
  } else {
    avatar.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 4a4 4 0 1 1 0 8 4 4 0 0 1 0-8Zm0 10c4.42 0 8 1.79 8 4v2H4v-2c0-2.21 3.58-4 8-4Z"/></svg>';
  }

  // Content
  const content = document.createElement('div');
  content.className = 'pierre-annotation-content';

  const header = document.createElement('div');
  header.className = 'pierre-annotation-header';

  // Subtitle (line info)
  if (metadata.subtitle) {
    const subtitleSpan = document.createElement('span');
    subtitleSpan.className = 'pierre-annotation-subtitle';
    subtitleSpan.textContent = metadata.subtitle;
    header.appendChild(subtitleSpan);
  }

  const deleteBtn = document.createElement('button');
  deleteBtn.className = 'pierre-annotation-delete';
  deleteBtn.textContent = '\u00D7';
  deleteBtn.title = 'Delete annotation';
  deleteBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    postToSwift('annotationDeleteRequested', {
      id: metadata.id || '',
      side: annotation.side || '',
      lineNumber: annotation.lineNumber || 0,
    });
  });
  header.appendChild(deleteBtn);

  const body = document.createElement('div');
  body.className = 'pierre-annotation-body';
  body.textContent = metadata.body || '';

  content.appendChild(header);
  content.appendChild(body);
  row.appendChild(avatar);
  row.appendChild(content);
  container.appendChild(row);

  // Post click event to Swift
  container.addEventListener('click', (e) => {
    e.stopPropagation();
    postToSwift('annotationClicked', {
      id: metadata.id || '',
      side: annotation.side || '',
      lineNumber: annotation.lineNumber || 0,
    });
  });

  return container;
}

/**
 * Applies the theme / diff style / overflow / font state carried by a render
 * request. Shared by the single-file and multi-file entry points.
 */
function applySharedOptions(options) {
  if (options.theme) {
    currentThemeConfig = typeof options.theme === 'string'
      ? { dark: options.theme, light: options.theme }
      : {
          dark: options.theme.dark || 'pierre-dark',
          light: options.theme.light || 'pierre-light',
        };
    currentTheme = options.themeType === 'light'
      ? currentThemeConfig.light
      : currentThemeConfig.dark;
  }
  if (options.diffStyle) {
    currentDiffStyle = options.diffStyle;
  }
  if (options.overflow) {
    currentOverflow = options.overflow;
  }

  applyFontOptions(options.font);
}

/**
 * Builds the renderer options shared by `FileDiff` and `CodeView`, applying
 * PierreDiffsSwift's historical defaults for anything the caller left unset.
 */
function baseRenderOptions(options) {
  const rendererOptions = {
    theme: currentThemeConfig,
    themeType: options.themeType || (currentTheme.includes('light') ? 'light' : 'dark'),
    diffStyle: currentDiffStyle,
    diffIndicators: options.diffIndicators || 'bars',
    hunkSeparators: options.hunkSeparators || 'line-info',
    lineDiffType: options.lineDiffType || 'word-alt',
    overflow: currentOverflow,
    enableLineSelection: options.enableLineSelection ?? true,
    disableLineNumbers: options.disableLineNumbers ?? false,
    disableFileHeader: options.disableFileHeader ?? false,
    disableBackground: options.disableBackground ?? false,
    expandUnchanged: options.expandUnchanged ?? false,
  };

  const passThrough = [
    'collapsedContextThreshold',
    'maxLineDiffLength',
    'expansionLineCount',
    'tokenizeMaxLength',
    'tokenizeMaxLineLength',
  ];
  for (const key of passThrough) {
    if (options[key] != null) {
      rendererOptions[key] = options[key];
    }
  }

  return rendererOptions;
}

/**
 * Estimated row height for CodeView's virtualizer, derived from the font
 * options actually applied. A wrong estimate only shows up as scroll drift
 * before rows are measured, but the fix is cheap so keep it in sync.
 */
function estimatedLineHeight(fontOptions) {
  const font = { ...DEFAULT_FONT, ...(fontOptions || {}) };
  const size = parseFloat(font.size) || 12;
  const lineHeight = String(font.lineHeight ?? '');
  const resolved = lineHeight.endsWith('px')
    ? parseFloat(lineHeight)
    : (parseFloat(lineHeight) || 1.5) * size;
  return Math.max(1, Math.round(resolved || size * 1.5));
}

/**
 * Cheap content fingerprint used as a CodeView item `version`. CodeView keeps
 * an existing record untouched when the version matches, so files whose
 * contents changed must land on a different number.
 */
function contentVersion(...parts) {
  let hash = 5381;
  for (const part of parts) {
    const text = String(part ?? '');
    for (let index = 0; index < text.length; index++) {
      hash = (hash * 33) ^ text.charCodeAt(index);
    }
    hash = (hash * 33) ^ 0;
  }
  return hash >>> 0;
}

/**
 * Turns one Swift-supplied file descriptor into a CodeView item. Files that
 * carry a `note` (binary, too large, unreadable) render as a plain one-file
 * item holding that note instead of a diff.
 */
function createCodeViewItem(file) {
  const id = file.id || file.name;
  if (file.note != null) {
    return {
      id,
      type: 'file',
      version: contentVersion('note', file.note),
      file: { name: file.name, contents: file.note, lang: 'text' },
    };
  }

  const oldName = file.oldName || file.name;
  const oldContents = file.oldContents || '';
  const newContents = file.newContents || '';
  // Both sides need a cache key for the parsed diff to carry one, and the
  // worker pool caches highlighting under that key — so it has to follow the
  // contents, not just the path.
  const fileDiff = parseDiffFromFile(
    {
      name: oldName,
      contents: oldContents,
      lang: file.lang || detectLanguage(oldName),
      cacheKey: `${id}~old~${contentVersion(oldContents)}`,
    },
    {
      name: file.name,
      contents: newContents,
      lang: file.lang || detectLanguage(file.name),
      cacheKey: `${id}~new~${contentVersion(newContents)}`,
    }
  );

  return {
    id,
    type: 'diff',
    version: contentVersion(
      oldName,
      oldContents,
      newContents,
      file.isEditable ? 'edit' : 'review'
    ),
    edit: file.isEditable === true,
    fileDiff,
  };
}

/**
 * Applies a queued scroll request once its file is present. Requests can
 * arrive before the files they name (the Swift side asks for a file at the
 * same time it asks for the diff), so they wait rather than being dropped.
 */
function flushPendingScroll() {
  if (!pendingScrollTarget || !currentCodeView) return;
  if (!currentCodeView.getItem(pendingScrollTarget.id)) return;
  const target = pendingScrollTarget;
  pendingScrollTarget = null;
  currentCodeView.scrollTo(target);
}

/**
 * The highlight worker pool, created on first use.
 *
 * Syntax highlighting is by far the most expensive part of mounting a file,
 * and in a virtualized surface that work would otherwise land in a scroll
 * frame — a scroll that reaches an unhighlighted file stalls for as long as
 * tokenizing it takes. Workers move it off the main thread: rows appear
 * immediately as plain text and are re-rendered highlighted when the worker
 * answers. Returns null when workers are unavailable, which leaves the
 * previous main-thread behaviour in place.
 */
function getWorkerPool(options) {
  const renderOptions = {
    theme: currentThemeConfig,
    lineDiffType: options.lineDiffType || 'word-alt',
    ...(options.maxLineDiffLength != null
      ? { maxLineDiffLength: options.maxLineDiffLength }
      : {}),
    ...(options.tokenizeMaxLineLength != null
      ? { tokenizeMaxLineLength: options.tokenizeMaxLineLength }
      : {}),
  };

  if (workerPool !== undefined) {
    // Highlighting is cached per render option set, so the workers have to be
    // told when those change or they would serve results for the old ones.
    const serialized = JSON.stringify(renderOptions);
    if (workerPool && serialized !== workerRenderOptions) {
      workerRenderOptions = serialized;
      workerPool.setRenderOptions(renderOptions)?.catch(() => {});
    }
    return workerPool;
  }

  workerPool = null;
  try {
    if (typeof Worker !== 'function' || !workerSource) return workerPool;
    workerBlobURL ??= URL.createObjectURL(
      new Blob([workerSource], { type: 'text/javascript' })
    );
    workerPool = getOrCreateWorkerPoolSingleton({
      poolOptions: {
        workerFactory: () => new Worker(workerBlobURL),
        poolSize: WORKER_POOL_SIZE,
      },
      highlighterOptions: renderOptions,
    });
    workerRenderOptions = JSON.stringify(renderOptions);
    // Spinning up Shiki inside the workers takes a moment; start it now rather
    // than when the first file needs highlighting.
    workerPool.initialize().catch((error) => {
      console.error('Failed to initialize highlight workers:', error);
    });
  } catch (error) {
    console.error('Highlight workers unavailable:', error);
    workerPool = null;
  }
  return workerPool;
}

/**
 * Warms the highlight cache for files the reader has not scrolled to yet, so
 * mounting them later is DOM work against a cached AST.
 */
function primeHighlighting(items) {
  if (!workerPool) return;
  for (const item of items.slice(0, MAX_PRIMED_FILES)) {
    if (item.type === 'diff') {
      workerPool.primeDiffHighlightCache(item.fileDiff);
    }
  }
}

/**
 * Tears down the multi-file surface, if one is live.
 */
function destroyCodeView() {
  if (!currentCodeView) return;
  currentCodeView.cleanUp();
  currentCodeView = null;
  currentCodeViewOptions = null;
  pendingScrollTarget = null;
}

/**
 * Builds the CodeView options for a render request. `CodeView.setOptions`
 * replaces the whole options object, so every call has to pass a complete one.
 */
function buildCodeViewOptions(options) {
  return {
    ...baseRenderOptions(options),
    stickyHeaders: options.stickyHeader ?? true,
    itemMetrics: { lineHeight: estimatedLineHeight(options.font) },
    renderAnnotation(annotation) {
      return createAnnotationDOM(annotation);
    },
    onLineClick: ({ lineNumber, side }, context) => {
      postToSwift('lineClicked', {
        lineNumber,
        side,
        lineY: 0,
        lineHeight: 22,
        fileId: context?.item?.id ?? '',
      });
    },
    onLineSelectionEnd: (range, context) => {
      if (range) {
        postToSwift('selectionChanged', {
          startLine: range.start,
          endLine: range.end,
          side: range.side,
          fileId: context?.item?.id ?? '',
        });
      }
    },
    createEditor(editorOptions) {
      return new Editor(editorOptions);
    },
    onItemEditChange(item, file) {
      postToSwift('fileEditChanged', {
        fileId: item.id,
        contents: file.contents,
      });
    },
    onItemEditComplete(item, file) {
      postToSwift('fileEditCompleted', {
        fileId: item.id,
        contents: file.contents,
      });
    },
  };
}

/**
 * Applies a partial option change to a live multi-file surface. `setOptions`
 * replaces the options wholesale, so the last full set is kept around and
 * patched rather than rebuilt from the (already consumed) render request.
 */
function updateCodeViewOptions(patch) {
  if (!currentCodeView || !currentCodeViewOptions) return;
  currentCodeViewOptions = { ...currentCodeViewOptions, ...patch };
  currentCodeView.setOptions(currentCodeViewOptions);
}

/**
 * Bridge object exposed to Swift
 */
window.pierreBridge = {
  /**
   * Renders a diff from input data
   * @param {object|string} inputData - Diff data (object or JSON string)
   */
  renderDiff(inputData) {
    try {
      // Handle both object (from base64 decode) and string input
      const input = typeof inputData === 'string' ? JSON.parse(inputData) : inputData;

      const { oldFile, newFile, options = {} } = input;

      // Clean up previous instances
      if (currentDiffInstance) {
        currentDiffInstance.cleanUp();
        currentDiffInstance = null;
      }
      destroyCodeView();

      // Clear container
      const container = getContainer();
      container.innerHTML = '';

      // Update current settings
      applySharedOptions(options);

      // Detect languages if not specified
      const oldLang = oldFile.lang || detectLanguage(oldFile.name);
      const newLang = newFile.lang || detectLanguage(newFile.name);

      // Create file objects for @pierre/diffs
      const oldFileObj = {
        name: oldFile.name || 'old',
        contents: oldFile.contents || '',
        lang: oldLang,
      };

      const newFileObj = {
        name: newFile.name || 'new',
        contents: newFile.contents || '',
        lang: newLang,
      };
      currentOldFile = oldFileObj;
      currentNewFile = newFileObj;

      const fileDiffOptions = {
        ...baseRenderOptions(options),
        stickyHeader: options.stickyHeader ?? false,
        renderAnnotation(annotation) {
          return createAnnotationDOM(annotation);
        },
        onLineClick: ({ lineNumber, side }) => {
          // Send line info to Swift - positioning is handled via NSEvent.mouseLocation
          postToSwift('lineClicked', { lineNumber, side, lineY: 0, lineHeight: 22 });
        },
        onLineSelectionEnd: (range) => {
          if (range) {
            postToSwift('selectionChanged', {
              startLine: range.start,
              endLine: range.end,
              side: range.side,
            });
          }
        },
      };

      // Create FileDiff instance
      currentDiffInstance = new FileDiff(fileDiffOptions);

      // Render the diff
      currentDiffInstance.render({
        oldFile: oldFileObj,
        newFile: newFileObj,
        containerWrapper: container,
        lineAnnotations: input.lineAnnotations || [],
      });

      postToSwift('ready');
    } catch (error) {
      console.error('Error rendering diff:', error);
      postToSwift('error', { message: error.message });
    }
  },

  /**
   * Renders several file diffs stacked in one virtualized scroll surface.
   * @param {object|string} inputData - `{ files: [...], options: {...} }`
   */
  renderFiles(inputData) {
    try {
      const input = typeof inputData === 'string' ? JSON.parse(inputData) : inputData;
      const { files = [], options = {} } = input;

      // The single-file surface owns the same container, so it cannot stay.
      if (currentDiffInstance) {
        currentDiffInstance.cleanUp();
        currentDiffInstance = null;
        currentOldFile = null;
        currentNewFile = null;
      }

      applySharedOptions(options);

      const container = getContainer();
      const pool = getWorkerPool(options);
      currentCodeViewOptions = buildCodeViewOptions(options);
      if (currentCodeView) {
        currentCodeView.setOptions(currentCodeViewOptions);
      } else {
        container.innerHTML = '';
        currentCodeView = new CodeView(currentCodeViewOptions, pool ?? undefined);
        currentCodeView.setup(container);
      }

      const items = [];
      const seen = new Set();
      for (const file of files) {
        // CodeView throws on duplicate ids; a repeated path is a caller bug
        // that should not take the whole diff down with it.
        const item = createCodeViewItem(file);
        if (seen.has(item.id)) continue;
        seen.add(item.id);
        items.push(item);
      }
      currentCodeView.setItems(items);
      flushPendingScroll();
      primeHighlighting(items);

      postToSwift('ready');
    } catch (error) {
      console.error('Error rendering diffs:', error);
      postToSwift('error', { message: error.message });
    }
  },

  /**
   * Scrolls the multi-file surface to one file. Requests for a file that has
   * not been rendered yet are applied by the next `renderFiles`.
   * @param {object|string} inputData - `{ id, align?, offset?, behavior? }`
   */
  scrollToFile(inputData) {
    try {
      const input = typeof inputData === 'string' ? JSON.parse(inputData) : inputData;
      if (!input || !input.id) return;
      pendingScrollTarget = {
        type: 'item',
        id: input.id,
        align: input.align || 'start',
        offset: input.offset ?? 0,
        behavior: input.behavior || 'instant',
      };
      flushPendingScroll();
    } catch (error) {
      console.error('Error scrolling to file:', error);
      postToSwift('error', { message: error.message });
    }
  },

  /**
   * Sets the current theme
   * @param {string} theme - "dark", "light", or "system"
   */
  setTheme(theme) {
    if (!currentDiffInstance && !currentCodeView) return;

    let themeType;
    if (theme === 'system') {
      themeType = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    } else {
      themeType = theme;
    }

    currentTheme = themeType === 'dark' ? currentThemeConfig.dark : currentThemeConfig.light;
    currentDiffInstance?.setThemeType(themeType);
    updateCodeViewOptions({ themeType });
    // Pierre themes switch light/dark through CSS variables, so the cached
    // ASTs stay valid; the workers only need the theme *config* if it changes.
    workerPool?.setRenderOptions({ theme: currentThemeConfig })?.catch(() => {});
  },

  /**
   * Sets the diff style
   * @param {string} style - "split" or "unified"
   */
  setDiffStyle(style) {
    currentDiffStyle = style;
    if (currentDiffInstance) {
      currentDiffInstance.setOptions({
        ...currentDiffInstance.options,
        diffStyle: style,
      });
      currentDiffInstance.rerender();
    }
    updateCodeViewOptions({ diffStyle: style });
  },

  /**
   * Sets the overflow mode (wrap or scroll)
   * @param {string} mode - "wrap" or "scroll"
   */
  setOverflow(mode) {
    currentOverflow = mode;
    if (currentDiffInstance) {
      currentDiffInstance.setOptions({
        ...currentDiffInstance.options,
        overflow: mode,
      });
      currentDiffInstance.rerender();
    }
    updateCodeViewOptions({ overflow: mode });
  },

  /**
   * Updates font CSS variables without a full FileDiff re-render.
   * @param {object|string} fontData - Font options (object or JSON string)
   */
  setFont(fontData) {
    try {
      const font = typeof fontData === 'string' ? JSON.parse(fontData) : fontData;
      applyFontOptions(font);
      // Row-height estimates feed the multi-file virtualizer, so they have to
      // follow the font even though the CSS variables update on their own.
      updateCodeViewOptions({ itemMetrics: { lineHeight: estimatedLineHeight(font) } });
    } catch (error) {
      console.error('Error setting font:', error);
      postToSwift('error', { message: error.message });
    }
  },

  /**
   * Scrolls to a specific line number
   * @param {number} lineNumber - The line number to scroll to
   */
  scrollToLine(lineNumber) {
    const lineElement = document.querySelector(`[data-line-index="${lineNumber - 1}"]`);
    if (lineElement) {
      lineElement.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  },

  /**
   * Gets the currently selected text
   * @returns {string} The selected text
   */
  getSelection() {
    return window.getSelection()?.toString() || '';
  },

  /**
   * Sets line annotations dynamically without full re-render
   * @param {object|string} annotationsData - Array of annotations (object or JSON string)
   */
  setAnnotations(annotationsData) {
    if (!currentDiffInstance) return;
    try {
      const annotations = typeof annotationsData === 'string'
        ? JSON.parse(annotationsData)
        : annotationsData;
      preservingScrollPosition((container) => {
        currentDiffInstance.render({
          oldFile: currentOldFile,
          newFile: currentNewFile,
          containerWrapper: container,
          lineAnnotations: annotations,
          preventEmit: true,
        });
      });
    } catch (error) {
      console.error('Error setting annotations:', error);
      postToSwift('error', { message: error.message });
    }
  },

  /**
   * Removes all line annotations
   */
  removeAnnotations() {
    if (!currentDiffInstance) return;
    this.setAnnotations([]);
  },

  /**
   * Cleans up the current diff instance
   */
  cleanup() {
    if (currentDiffInstance) {
      currentDiffInstance.cleanUp();
      currentDiffInstance = null;
    }
    destroyCodeView();
    if (workerPool) {
      terminateWorkerPoolSingleton();
      // The singleton is gone, so the next render has to build a fresh pool.
      workerPool = undefined;
      workerRenderOptions = null;
    }
    if (workerBlobURL) {
      URL.revokeObjectURL(workerBlobURL);
      workerBlobURL = null;
    }
    currentOldFile = null;
    currentNewFile = null;
    const container = getContainer();
    container.innerHTML = '';
  },
};

// Also expose raw utilities for advanced usage
window.PierreDiffs = {
  FileDiff,
  parseDiffFromFile,
};

// Signal that the bridge is ready
document.addEventListener('DOMContentLoaded', () => {
  postToSwift('bridgeReady');
});

// Handle system theme changes
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
  postToSwift('systemThemeChanged', { isDark: e.matches });
});
