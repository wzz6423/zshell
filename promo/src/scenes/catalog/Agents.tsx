import { Keycap } from '../../components/Hud';
import { BranchIcon, SearchIcon } from '../../components/Icons';
import { linear, ramp } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import {
  Action,
  Badge,
  Code,
  Done,
  ListRow,
  Panel,
  Progress,
  Setting,
  Shell,
  pressAt,
  revealAt,
  type ChapterSpec,
  type DemoProps,
} from './Frame';

const AgentsContextStep = ({ frame, fps }: DemoProps) => {
  const allowPress = pressAt(frame, 68);
  const approved = revealAt(frame, fps, 74);
  const autoSend = revealAt(frame, fps, 114, true);
  const draftAdded = revealAt(frame, fps, 94);
  const copyDraftPress = pressAt(frame, 152);
  const focusAgentPress = pressAt(frame, 174);
  const draftReady = revealAt(frame, fps, 178);
  const draftNote = 'Please keep the existing GET /projects schema.'.slice(
    0,
    typedLength('Please keep the existing GET /projects schema.', frame, 102, 146),
  );

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 24, height: '100%' }}>
      <Shell
        title="app — Agents & Prompt Queue"
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Keycap size={15} pressed={pressAt(frame, 18)}>Cmd + Option + A</Keycap>
            <Badge tone={approved > 0.5 ? 'amber' : 'red'}>
              {approved > 0.5 ? 'Claude Code · Working' : 'Claude Code · Approval required'}
            </Badge>
            <Badge active={false} style={{ marginLeft: 'auto' }}>Cmd+Shift+A Next Attention</Badge>
          </div>
        }
      >
        <div style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 16, height: '100%', boxSizing: 'border-box' }}>
          <Panel title="Human-controlled approval · Native lifecycle">
            <div style={{ padding: '14px 18px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 14 }}>
              <div>
                <div style={{ fontSize: 19, fontWeight: 600 }}>Allow edit to src/routes.ts?</div>
                <div style={{ fontSize: 16, color: color.muted, marginTop: 3 }}>Zshell never auto-approves permissions or credentials.</div>
              </div>
              {approved > 0.5 ? (
                <Done progress={approved}>Approved by you</Done>
              ) : (
                <div style={{ display: 'flex', gap: 8 }}>
                  <Action active press={allowPress} style={{ padding: '6px 14px', fontSize: 16 }}>Allow</Action>
                  <Action style={{ padding: '6px 14px', fontSize: 16 }}>Deny</Action>
                </div>
              )}
            </div>
          </Panel>

          <Panel title="Prompt Queue · Cmd+Shift+M" style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
            <Setting label="Send queued prompts automatically" checked={autoSend} focus={autoSend > 0.1 && autoSend < 0.95} />
            <ListRow active={autoSend < 0.5} trailing={<Action active={autoSend > 0.5} style={{ padding: '5px 12px', fontSize: 15 }}>{autoSend > 0.5 ? 'Sent' : 'Send Now'}</Action>}>
              <span className="font-mono" style={{ fontSize: 18 }}>pnpm test</span>
            </ListRow>
            <ListRow trailing={<Badge active={false} style={{ fontSize: 14, padding: '3px 9px' }}>Queued #2</Badge>}>
              <span className="font-mono" style={{ fontSize: 18 }}>git status</span>
            </ListRow>
            <div style={{ marginTop: 'auto', padding: '10px 16px', borderTop: `1px solid ${color.line}`, fontSize: 16, color: color.muted }}>
              Dispatches only when the original local zsh returns to an empty prompt.
            </div>
          </Panel>
        </div>
      </Shell>

      <Shell
        title="Terminal → Agent Context Draft"
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Badge tone="violet">Add Selection / Output to Agent Draft</Badge>
            <span style={{ marginLeft: 'auto', fontSize: 16, color: color.muted }}>Per-project · up to 256 KiB</span>
          </div>
        }
      >
        <div style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 14, height: '100%', boxSizing: 'border-box' }}>
          <Panel title="Captured sources (editable multiline draft)" style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
            <div className="font-mono" style={{ padding: '14px 16px', fontSize: 17, lineHeight: 1.6, flex: 1 }}>
              <div style={{ color: color.muted }}># From command output: bun test</div>
              <div style={{ color: color.red }}>FAIL src/routes.test.ts:42 — expected 200</div>
              <div style={{ marginTop: 10, opacity: draftAdded, transform: `translateY(${(1 - draftAdded) * 6}px)` }}>
                <span style={{ color: color.muted }}># Added selection: src/routes.ts</span>
                <div style={{ color: color.fg, marginTop: 4 }}>{draftNote}</div>
              </div>
            </div>
          </Panel>

          <Panel>
            <Setting label="Target local agent" value={<Badge tone="blue" style={{ padding: '3px 10px', fontSize: 15 }}>Claude Code · app</Badge>} />
          </Panel>

          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <Action active press={copyDraftPress} style={{ padding: '7px 14px', fontSize: 16 }}>Copy Draft</Action>
            <Action active={frame >= 156} press={focusAgentPress} tone="violet" style={{ padding: '7px 14px', fontSize: 16 }}>Focus Agent</Action>
            <Done progress={draftReady} style={{ marginLeft: 'auto', fontSize: 15 }}>Ready to review &amp; paste</Done>
          </div>
          <div style={{ fontSize: 16, color: color.muted }}>
            Copy and focus never write to the terminal or press Enter automatically.
          </div>
        </div>
      </Shell>
    </div>
  );
};

const HistoryAndRulesStep = ({ frame, fps }: DemoProps) => {
  const forkPress = pressAt(frame, 88);
  const forked = revealAt(frame, fps, 94);
  const progress = ramp(frame, [30, 170], [0.32, 0.88]);
  const childDone = frame >= 152;
  const ruleLines = [
    '[[agents]]',
    'id = "deploy-tool"',
    'name = "Deploy Tool"',
    'executables = ["deploy-tool"]',
    'screen_enabled = false',
  ];

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.02fr 0.98fr', gap: 24, height: '100%' }}>
      <Shell title="Agent Conversation History">
        <div style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 14, height: '100%', boxSizing: 'border-box' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Badge active>Recent</Badge>
            <Badge active={false}>All</Badge>
            <Badge active={false}>Archived</Badge>
            <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8, padding: '6px 12px', borderRadius: 8, border: `1px solid ${color.lineStrong}`, fontSize: 16, color: color.muted }}>
              <SearchIcon size={16} /> API routes
            </div>
          </div>

          <Panel>
            <ListRow active trailing={<Badge tone="blue" style={{ fontSize: 14, padding: '3px 9px' }}>Saved · Claude Code</Badge>}>
              Review API routes
            </ListRow>
            <div className="font-mono" style={{ padding: '2px 16px 12px', fontSize: 16, color: color.muted }}>
              Working Dir: ~/src/app · Config: ~/.claude
            </div>
            <div style={{ padding: '0 16px 14px', display: 'flex', gap: 10, flexWrap: 'wrap' }}>
              <Action style={{ padding: '6px 13px', fontSize: 16 }}>Resume Conversation</Action>
              <Action active press={forkPress} tone="violet" style={{ padding: '6px 13px', fontSize: 16 }}>
                <BranchIcon size={16} /> Fork in New Pane
              </Action>
              <Action style={{ padding: '6px 13px', fontSize: 16 }}>Archive</Action>
            </div>
          </Panel>

          <Panel
            title="Claude Code — Forked Pane (independent conversation)"
            style={{
              flex: 1,
              opacity: forked,
              transform: `translateY(${(1 - forked) * 14}px)`,
              borderColor: alpha(color.violet, 38),
            }}
          >
            <div style={{ padding: 16, fontSize: 18, lineHeight: 1.65 }}>
              <div style={{ color: color.muted }}>Inherited context: Review API routes (source unchanged)</div>
              <div style={{ marginTop: 10, color: color.fg }}>› Try an alternative error-handling strategy.</div>
              <div style={{ marginTop: 12 }}><Done progress={forked}>Provider-native fork · local &amp; remote hosts</Done></div>
            </div>
          </Panel>
        </div>
      </Shell>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 18, height: '100%' }}>
        <Shell title="Settings — AI · Agent Recognition Rules" style={{ flex: 1 }}>
          <div style={{ padding: 18 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
              <Badge active>agents.toml · live reload</Badge>
              <div style={{ display: 'flex', gap: 8 }}>
                <Action style={{ padding: '5px 11px', fontSize: 15 }}>Add</Action>
                <Action style={{ padding: '5px 11px', fontSize: 15 }}>Import / Export</Action>
              </div>
            </div>
            <Panel style={{ backgroundColor: alpha(color.raised, 45) }}>
              <Code lines={ruleLines} style={{ fontSize: 16, padding: '10px 14px', lineHeight: 1.55 }} />
            </Panel>
          </div>
        </Shell>

        <Shell title="Explicit Program Reports · zshell +agent report --json" style={{ flex: 1 }}>
          <div style={{ padding: 18 }}>
            <ListRow trailing={<Badge tone={childDone ? 'green' : 'amber'} style={{ fontSize: 15, padding: '4px 10px' }}>{childDone ? 'Ready' : 'Working'}</Badge>}>
              Deploy Tool · Program report
            </ListRow>
            <Progress value={progress} label="Build & verify" tone={childDone ? 'green' : 'blue'} style={{ padding: '10px 14px' }} />
            <div style={{ padding: '8px 14px 0', display: 'flex', gap: 10, flexWrap: 'wrap', opacity: linear(frame, [20, 36]) }}>
              <Done>Tests</Done>
              <Badge tone={childDone ? 'green' : 'amber'}>Docs · {childDone ? 'Done' : 'Working'}</Badge>
              <span style={{ marginLeft: 'auto', fontSize: 15, color: color.muted }}>Native &gt; Program &gt; Screen</span>
            </div>
          </div>
        </Shell>
      </div>
    </div>
  );
};

const AgentsBody = (props: DemoProps) =>
  props.step === 0 ? <AgentsContextStep {...props} /> : <HistoryAndRulesStep {...props} />;

export const agentsChapter: ChapterSpec = {
  id: 'agents',
  en: 'AI agents & context',
  zh: 'AI 协作、队列与上下文草稿',
  nav: 'AI 与上下文',
  steps: [
    { en: 'Agent palette, Prompt Queue & context drafts', zh: '智能体切换、提示词队列与可编辑上下文草稿' },
    { en: 'Conversation history, native forks & program reports', zh: '历史对话、原生分叉、自定义识别规则与进度上报' },
  ],
  features: [
    'Cmd+Option+A Agent palette, Cmd+Shift+A Next Agent Needing Attention and human-controlled permission approvals',
    'Per-terminal Prompt Queue (Cmd+Shift+M) with manual Send Now and opt-in automatic dispatch at empty original zsh prompt',
    'Editable per-project Agent Context Draft (Add Selection/Output to Agent Draft, Copy Draft, Focus Agent without submitting terminal input)',
    'Agent Conversation History search, Recent/All/Archived, Resume Conversation and provider-native Fork Conversation in New Pane',
    'Custom Agent Recognition Rules (agents.toml Add/Import/Export) with native lifecycle and program report priority',
    'Explicit program reports (zshell +agent report --json) with progress percentage and child tasks',
  ],
  sources: [
    'web/content/docs/automation.mdx',
    'web/content/docs/terminal.mdx',
    'mac/zshell/AgentPalette.swift',
    'mac/zshell/TerminalPromptQueue.swift',
    'mac/zshell/AgentConversationHistoryController.swift',
    'mac/zshell/AgentRecognitionRulesController.swift',
    'mac/zshell/AgentStatusReporting.swift',
  ],
  Body: AgentsBody,
};
