import type { Tone } from '../theme';

// Copy and numbers below come from README.md and web/content/docs; nothing
// here is a benchmark, because the repository publishes none.

export const PRODUCT = {
  name: 'Zshell',
  tagline: { en: 'Your terminal. Your whole project.', zh: '终端在中心。项目在掌握。' },
  eyebrow: { en: 'Native macOS terminal workspace', zh: '原生 macOS 终端工作区' },
  install: 'brew install wzz6423/tap/zshell',
  repo: 'github.com/wzz6423/zshell',
  requirement: 'macOS 15.6+',
};

export const AGENT_KINDS = [
  'codex',
  'claude',
  'gemini',
  'grok',
  'opencode',
  'cursor-agent',
  'aider',
  'amp',
  'pi',
];

export type Layer = { index: string; en: string; zh: string; detail: string; tone: Tone };

export const LAYERS: Layer[] = [
  { index: '01', en: 'AppKit workspace', zh: '原生工作区', detail: 'Projects · panes · files · Git · editor · diff', tone: 'cyan' },
  { index: '02', en: 'Automation', zh: '自动化接口', detail: 'zshell CLI · private Unix socket', tone: 'green' },
  { index: '03', en: 'Terminal backends', zh: '终端后端', detail: 'libghostty · Alacritty', tone: 'amber' },
  { index: '04', en: 'Sessions', zh: '会话层', detail: 'Local shell · zshell-server on remote hosts', tone: 'violet' },
];

export const CONFIG_PATH = '~/.config/zshell/config.toml';
export const CONFIG_SLICE = [
  '# Read while Zshell is running.',
  'theme-light = "Catppuccin Latte"',
  'font-family = "IBM Plex Mono"',
  'terminal.backend = "alacritty"',
  'terminal.restore-history = true',
];
export const CONFIG_FOCUS_LINE = 3;

export const BACKENDS = [
  { name: 'libghostty', note: { en: 'Default', zh: '默认' }, tone: 'cyan' as Tone },
  { name: 'alacritty', note: { en: 'Lower memory footprint', zh: '内存占用更低' }, tone: 'amber' as Tone },
];
export const BACKEND_TRAITS = ['Native', 'GPU-accelerated', 'Image rendering', 'Shared themes'];

export const BOUNDARY = {
  chain: [
    { label: 'Agent', sub: 'in a pane' },
    { label: 'zshell CLI', sub: '+pane · +agent · +events' },
    { label: 'Unix socket', sub: 'private · authenticated' },
    { label: 'This project', sub: 'its panes only' },
  ],
  rules: [
    { en: 'Other projects and windows stay out of reach', zh: '无法触及其他项目与窗口', allowed: false },
    { en: 'Permission and credential prompts stay yours', zh: '授权与凭据提示始终由你确认', allowed: false },
    { en: 'Terminal output cannot fake a lifecycle report', zh: '终端输出无法伪造状态上报', allowed: false },
  ],
};

export type Limit = { label: string; zh: string; value: number; unit: string; tone: Tone };

// web/content/docs/automation.mdx, "zshell +events" limits.
export const LIMITS: Limit[] = [
  { label: 'Event subscriptions', zh: '事件订阅', value: 32, unit: 'max', tone: 'cyan' },
  { label: 'Queued frames per stream', zh: '单流排队帧', value: 256, unit: 'max', tone: 'amber' },
  { label: 'Size of one frame', zh: '单帧大小', value: 64, unit: 'KiB', tone: 'violet' },
  { label: 'Tasks in one agent report', zh: '单次上报任务数', value: 32, unit: 'max', tone: 'green' },
];

export const FOOTNOTES = [
  { en: '17 languages', zh: '17 种语言' },
  { en: 'No account', zh: '无需账号' },
  { en: 'No telemetry', zh: '无遥测' },
  { en: PRODUCT.requirement, zh: '系统要求' },
];
