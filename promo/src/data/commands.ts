// Every command here is copied from the syntax documented in
// mac/zshell/Skills/zshell-automation/SKILL.md and web/content/docs/automation.mdx.
// The CLI prints one line of JSON with sorted keys; the output below keeps
// that key order and marks everything left out with an ellipsis.

export type DemoCommand = {
  id: 'split' | 'start' | 'prompt';
  command: string;
  typeFrom: number;
  typeTo: number;
  enterAt: number;
  outputAt: number;
  output: string[];
  emphasize: string[];
};

export const PROMPT = { cwd: '~/src/app', branch: 'main', symbol: '›' };

export const DEMO_COMMANDS: DemoCommand[] = [
  {
    id: 'split',
    command: 'zshell +pane split --right --wait --timeout 300000 -- make test',
    typeFrom: 40,
    typeTo: 168,
    enterAt: 178,
    outputAt: 312,
    output: [
      '{…,"is_focused":false,"pane_id":"4F2A9C1E-…",…,"task":{…,',
      '"duration_ms":8412.7,…,"exit_code":2,…,"state":"completed",…},…,',
      '"timed_out":false,…,"waited":true,…}',
    ],
    emphasize: ['duration_ms', 'exit_code'],
  },
  {
    id: 'start',
    command: 'zshell +agent start tests --kind codex --pane "$PANE_ID"',
    typeFrom: 346,
    typeTo: 452,
    enterAt: 460,
    outputAt: 472,
    output: [
      '{"agent":{"alias":"tests",…,"authority":"process",…,',
      '"kind":"codex",…,"state":"created",…},"content":"terminal",…}',
    ],
    emphasize: ['kind', 'state'],
  },
  {
    id: 'prompt',
    command: 'zshell +agent prompt tests --text "Fix the failing test."',
    typeFrom: 500,
    typeTo: 618,
    enterAt: 626,
    outputAt: 636,
    output: [
      '{"agent":{"alias":"tests",…,"authority":"command",…,',
      '"reason":"Prompt submitted","state":"working",…},…}',
    ],
    emphasize: ['reason', 'state'],
  },
];

export type StreamLine = { at: number; text: string; tone?: 'muted' | 'red' | 'green' | 'fg' };

// What the background pane prints. The project under test is a stand-in; only
// the exit status it produces is something Zshell reports.
export const TEST_RUN: StreamLine[] = [
  { at: 214, text: '› make test', tone: 'fg' },
  { at: 228, text: 'running 128 tests' },
  { at: 244, text: 'test config::parses_dotted_keys ... ok' },
  { at: 254, text: 'test layout::split_keeps_ratio ... ok' },
  { at: 264, text: 'test parser::wide_glyph_width ... FAILED', tone: 'red' },
  { at: 276, text: 'test session::restores_scrollback ... ok' },
  { at: 290, text: '127 passed; 1 failed', tone: 'red' },
  { at: 298, text: 'make: *** [test] Error 1', tone: 'muted' },
];

export const AGENT_RUN: StreamLine[] = [
  { at: 474, text: '› codex', tone: 'fg' },
  { at: 644, text: '• Fix the failing test.', tone: 'fg' },
  { at: 662, text: '• Reading the failed run' },
  { at: 680, text: '• Editing src/parser.rs' },
  { at: 698, text: '• Running make test' },
  { at: 716, text: '128 passed; 0 failed', tone: 'green' },
];

export const AGENT_STATE_AT = { created: 474, working: 636, done: 724 };

export type Hud = {
  id: string;
  from: number;
  to: number;
  en: string;
  zh: string;
  tone: 'cyan' | 'amber' | 'green' | 'violet';
};

export const HUDS: Hud[] = [
  { id: 'background', from: 196, to: 318, en: 'Background pane · focus stays put', zh: '后台窗格 · 焦点不动', tone: 'cyan' },
  { id: 'status', from: 322, to: 440, en: 'Real exit status & duration', zh: '真实退出码与耗时', tone: 'amber' },
  { id: 'agents', from: 478, to: 606, en: '9 agent CLIs, one interface', zh: '9 种编码智能体，同一接口', tone: 'violet' },
  { id: 'lifecycle', from: 648, to: 772, en: 'State reported by the agent itself', zh: '状态由智能体原生上报', tone: 'green' },
];

// Shown as a code slice in the architecture scene (automation.mdx).
export const EVENTS_COMMAND = 'zshell +events --event command.task.finished';
export const EVENTS_STREAM = [
  '{"version":1,"event":"stream.ready",…,"sequence":0,…}',
  '{"version":1,"event":"command.task.finished",…,"sequence":1,…}',
];
