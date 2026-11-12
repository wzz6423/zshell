import { Keycap } from '../../components/Hud';
import { BranchIcon, SearchIcon } from '../../components/Icons';
import { linear } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color, type Tone } from '../../theme';
import { Action, Badge, Code, Done, Group, ListRow, Panel, Progress, Setting, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const PROVIDERS = ['Codex', 'Claude Code', 'Gemini CLI', 'Grok Build', 'OpenCode', 'Cursor Agent', 'Aider', 'Amp', 'Pi'];
const STATUS: { label: string; tone: Tone; source: string }[] = [
  { label: 'Working', tone: 'amber', source: 'Native lifecycle' },
  { label: 'Approval required', tone: 'red', source: 'Native lifecycle' },
  { label: 'Idle', tone: 'blue', source: 'Process detection' },
  { label: 'Working', tone: 'amber', source: 'Native lifecycle' },
  { label: 'Done', tone: 'green', source: 'Native lifecycle' },
  { label: 'Working', tone: 'amber', source: 'Screen inference' },
  { label: 'Idle', tone: 'blue', source: 'Process detection' },
  { label: 'Idle', tone: 'blue', source: 'Process detection' },
  { label: 'Working', tone: 'amber', source: 'Native lifecycle' },
];

const PaletteDemo = ({ frame }: DemoProps) => {
  const searching = frame >= 108;
  const selected = frame >= 154;
  const resumed = frame >= 207;
  const query = 'Claude'.slice(0, typedLength('Claude', frame, 108, 143));
  const offset = 425 * linear(frame, [48, 95]);
  return (
    <Shell title="app — agents" toolbar={<div style={{ display: 'flex', gap: 14, alignItems: 'center' }}><Keycap size={19} pressed={!selected ? 1 : 0}>Cmd + Option + A</Keycap><Badge tone={selected ? resumed ? 'amber' : 'red' : 'blue'}>{selected ? resumed ? 'Working' : 'Blocked' : 'Agent palette'}</Badge></div>}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 710px', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}` }}>
          {selected ? <Terminal frame={frame} fontSize={25}>
            <div style={{ color: color.violet, marginBottom: 20 }}>Claude Code — review API routes</div>
            <div>Inspecting src/routes.ts</div>
            <Panel title="Claude Code" style={{ marginTop: 32 }}><div style={{ padding: 24 }}><div style={{ fontSize: 26 }}>Allow this edit?</div><div style={{ color: color.muted, margin: '16px 0 22px' }}>src/routes.ts</div>{resumed ? <Done>Edit approved by you</Done> : <><Action active={frame >= 193}>Allow</Action><span style={{ marginLeft: 14 }}><Action>Deny</Action></span></>}</div></Panel>
            {resumed ? <div style={{ marginTop: 28, color: color.green }}>Continuing with the approved change…</div> : null}
          </Terminal> : <Terminal frame={frame} fontSize={26} command="git diff">
            <div style={{ color: color.muted }}>Codex · tests</div><Progress value={0.26 + 0.39 * linear(frame, [0, 104])} label="Running tests" /><div>PASS src/workspace.test.ts</div><div>PASS src/routes.test.ts</div>
          </Terminal>}
        </div>
        <div style={{ padding: 26 }}>
          <Panel title={selected ? 'Claude Code · app · review' : 'Search agents…'}>
            {!selected ? <><div style={{ display: 'flex', gap: 12, alignItems: 'center', padding: 18, margin: 18, border: `1px solid ${color.lineStrong}`, borderRadius: 8, fontSize: 24 }}><SearchIcon size={24} />{query || <span style={{ color: color.faint }}>Search agents…</span>}</div><div style={{ height: 335, overflow: 'hidden' }}><div style={{ transform: `translateY(${-(!searching ? offset : 0)}px)` }}>{PROVIDERS.filter((name) => !query || name.toLowerCase().includes(query.toLowerCase())).map((name) => { const status = STATUS[PROVIDERS.indexOf(name)]; return <ListRow key={name} active={searching} trailing={<Badge tone={status.tone}>{status.label}</Badge>} style={{ minHeight: 64 }}><div>{name}</div><div style={{ color: color.muted, fontSize: 17, marginTop: 5 }}>app · {status.source}</div></ListRow>; })}</div></div></> : <><ListRow trailing={<Badge tone={resumed ? 'amber' : 'red'}>{resumed ? 'Working' : 'Approval required'}</Badge>}>Claude Code</ListRow><Code lines={['Source: Native lifecycle', 'app · review · src/routes.ts']} /><Progress value={resumed ? 0.72 : 0.45} label="Progress" /><ListRow>Tests <Badge tone="green">Done</Badge></ListRow><ListRow>API routes <Badge tone={resumed ? 'amber' : 'red'}>{resumed ? 'Working' : 'Blocked'}</Badge></ListRow></>}
          </Panel>
          {selected ? <div style={{ marginTop: 24 }}><Action active>Next Agent Needing Attention</Action></div> : <div style={{ marginTop: 24 }}><Keycap size={18} pressed={searching ? 1 : 0}>Return</Keycap></div>}
        </div>
      </div>
    </Shell>
  );
};

const QueueDemo = ({ frame }: DemoProps) => {
  const firstAdded = frame >= 35;
  const secondAdded = frame >= 71;
  const busy = frame < 117;
  const firstSent = frame >= 143;
  const automatic = frame >= 169;
  const secondSent = frame >= 209;
  const typed = frame < 35 ? 'pnpm test'.slice(0, typedLength('pnpm test', frame, 9, 31)) : frame < 71 ? 'git status'.slice(0, typedLength('git status', frame, 45, 66)) : '';
  return (
    <Shell title="app — zsh prompt queue">
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 620px', height: '100%' }}>
        <div style={{ display: 'flex', flexDirection: 'column', minHeight: 0, borderRight: `1px solid ${color.line}` }}>
          <div style={{ flex: 1, minHeight: 0 }}><Terminal frame={frame} fontSize={25}>
            <div style={{ color: color.muted }}>› pnpm run build</div><div>{busy ? 'Building app…' : 'Build complete in 2.1 s'}</div>
            {firstSent ? <><div style={{ marginTop: 20 }}>› pnpm test</div><div style={{ color: color.green }}>{automatic ? '2 tests passed' : 'Running tests…'}</div></> : null}
            {secondSent ? <><div style={{ marginTop: 20 }}>› git status</div><div>On branch main</div><div style={{ color: color.green }}>working tree clean</div></> : null}
          </Terminal></div>
          <Panel title="Prompt Queue" style={{ margin: 22, flexShrink: 0 }}>
            {firstAdded && !firstSent ? <ListRow trailing={<div style={{ display: 'flex', gap: 10 }}><Action disabled={busy} active={!busy}>Send Now</Action><Action>Remove</Action></div>}>pnpm test</ListRow> : null}
            {secondAdded && !secondSent ? <ListRow trailing={<div style={{ display: 'flex', gap: 10 }}><Action disabled={busy || firstSent && frame < 201}>Send Now</Action><Action>Remove</Action></div>}>git status</ListRow> : null}
            <div style={{ display: 'flex', gap: 14, padding: 18, alignItems: 'center' }}><div style={{ flex: 1, padding: 14, fontSize: 22, border: `1px solid ${color.lineStrong}`, borderRadius: 8, color: typed ? color.fg : color.faint }}>{typed || 'Add a prompt to run later…'}</div><Action active={frame >= 29 && frame < 42 || frame >= 63 && frame < 80}>Add to Queue</Action></div>
          </Panel>
        </div>
        <div style={{ padding: 26 }}>
          <Group title="Settings · Terminal · Prompt Queue"><Setting label="Enable Prompt Queue" checked /><Setting label="Send queued prompts automatically" checked={automatic} focus={automatic} /></Group>
          <Panel title="Claude Code — busy foreground program"><div style={{ padding: 22, fontSize: 23, lineHeight: 1.6 }}><Badge tone="amber">Working</Badge><div style={{ marginTop: 20 }}>Reviewing API routes…</div></div><ListRow trailing={<Action disabled>Send Now</Action>}>pnpm lint</ListRow><div style={{ padding: '0 20px 22px', fontSize: 19, color: color.muted }}>Sending waits for an empty prompt in the original zsh shell and for command tasks to finish.</div></Panel>
          <div style={{ display: 'flex', gap: 12, marginTop: 28 }}><Keycap size={18}>Cmd + Shift + M</Keycap>{secondSent ? <Done>Queue sent in order</Done> : null}</div>
        </div>
      </div>
    </Shell>
  );
};

const HistoryDemo = ({ frame }: DemoProps) => {
  const archived = frame >= 67 && frame < 123;
  const resumed = frame >= 148;
  const forked = frame >= 198;
  const deleting = frame >= 191 && frame < 218;
  const deleted = frame >= 218;
  const query = 'API routes'.slice(0, typedLength('API routes', frame, 12, 47));
  return (
    <Shell title="app — Agent Conversation History">
      <div style={{ display: 'grid', gridTemplateColumns: '740px 1fr', height: '100%' }}>
        <div style={{ padding: 26, position: 'relative', borderRight: `1px solid ${color.line}` }}>
          <Panel title="Agent Conversation History"><div style={{ display: 'flex', gap: 14, padding: 18 }}>{['Recent', 'All', 'Archived'].map((label) => <Badge key={label} active={label === (archived ? 'Archived' : frame >= 123 ? 'All' : 'Recent')}>{label}</Badge>)}</div><div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 15, margin: '0 18px 18px', border: `1px solid ${color.lineStrong}`, borderRadius: 8, fontSize: 23 }}><SearchIcon />{query || <span style={{ color: color.faint }}>Search conversations…</span>}</div><ListRow active trailing={<Badge tone={archived ? 'violet' : 'blue'}>{archived ? 'Archived' : resumed ? 'Open Conversation' : 'Saved Conversation'}</Badge>}>Review API routes</ListRow><div style={{ padding: '10px 22px 24px', fontSize: 21, lineHeight: 1.8, color: color.muted }}>Claude Code · app<div className="font-mono" style={{ fontSize: 19 }}>Working Directory: ~/src/app<br />Configuration Directory: ~/.claude</div></div>{frame < 47 || frame >= 170 && !deleted ? <ListRow active={deleting}>API routes — experiment</ListRow> : null}<div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, padding: 18 }}><Action active={frame >= 136 && frame < 171}>{resumed ? 'Show Conversation' : 'Resume Conversation'}</Action><Action active={frame >= 59 && frame < 78 || frame >= 113 && frame < 129}>{archived ? 'Unarchive' : 'Archive'}</Action><Action active={deleting}>Delete</Action></div><ListRow active={forked} trailing={<BranchIcon size={25} />}>Fork Conversation in New Pane</ListRow></Panel>
          {deleting ? <Panel title="Delete this conversation history record?" style={{ position: 'absolute', left: 40, right: 40, bottom: 25, boxShadow: `0 18px 60px ${alpha(color.shadow, 24)}` }}><div style={{ padding: 18, fontSize: 21, lineHeight: 1.5 }}>The provider’s conversation files are kept.</div><div style={{ display: 'flex', gap: 12, padding: 18 }}><Action>Cancel</Action><Action active={frame >= 204}>Delete History Record</Action></div></Panel> : null}
          <div style={{ marginTop: 20, fontSize: 20, color: color.muted }}>Terminal → Agents → Search All Agent Conversations</div>
        </div>
        <div style={{ padding: 26 }}>
          <Panel title="Claude Code — Review API routes"><div style={{ padding: 24, fontSize: 23, lineHeight: 1.85 }}><div style={{ color: color.muted }}>You: Review the API routes and preserve the contract.</div><div style={{ marginTop: 16 }}>Claude: The existing GET /projects response is correct.</div><div style={{ marginTop: 14 }}>Next, I will check the error responses.</div>{resumed ? <div style={{ marginTop: 28, color: color.blue }}>› Continue from the same conversation.</div> : null}</div></Panel>
          {forked ? <Panel title="Claude Code — forked pane" style={{ marginTop: 24 }}><div style={{ padding: 24, fontSize: 23, lineHeight: 1.8 }}><div style={{ color: color.muted }}>Previous context: Review the API routes…</div><div style={{ marginTop: 15 }}>› Try an alternative error response.</div><div style={{ marginTop: 18 }}><Badge>Independent conversation</Badge></div></div></Panel> : <div style={{ marginTop: 30, opacity: resumed ? 1 : 0.4 }}><Badge tone="green">Original directory · original conversation</Badge></div>}
        </div>
      </div>
    </Shell>
  );
};

const SettingsDemo = ({ frame }: DemoProps) => {
  const enabled = frame >= 21;
  const rules = enabled && frame < 146;
  const reporting = frame >= 146 && frame < 199;
  const notification = frame >= 199;
  const shown = frame >= 221;
  const exported = frame >= 121;
  const imported = frame >= 91;
  const progress = Math.floor(32 + 50 * linear(frame, [146, 183]));
  const childDone = frame >= 183;
  const ruleLines = ['[[agents]]', 'id = "review-tool"', 'name = "Review Tool"', 'executables = ["review-tool"]', 'screen_enabled = false'];
  const reportLines = [
    '{', '  "name": "Deploy Tool", "state": "working",', `  "progress": ${progress}, "tasks": [`,
    '    {"id":"tests", "title":"Tests", "state":"done"},',
    `    {"id":"docs", "title":"Docs", "state":"${childDone ? 'done' : 'working'}"}`, '  ]', '}',
  ];
  return (
    <Shell title="Settings — AI">
      <div style={{ display: 'grid', gridTemplateColumns: '630px 1fr', height: '100%' }}>
        <div style={{ padding: 25, borderRight: `1px solid ${color.line}` }}><Group title="AI"><Setting label="AI" checked={enabled} focus={frame < 52} /><Setting label="Resume agent conversations" checked /><ListRow>Agent Conversation History</ListRow></Group><Group title="Agent Recognition"><Setting label="Use custom recognition rules" checked /><Setting label="Infer agent state from the screen" checked /><ListRow active={rules}>Manage Agent Rules…</ListRow></Group><Group title="Notifications"><Setting label="Notify when agents need attention" checked /><Setting label="Notify when agents finish" checked /></Group></div>
        <div style={{ padding: 26 }}>
          {reporting ? <Panel title="report.json — program tasks"><Code lines={reportLines} style={{ fontSize: 21, lineHeight: 1.6 }} /><div className="font-mono" style={{ padding: '0 22px 16px', fontSize: 21 }}>zshell +agent report --json &lt; report.json</div><ListRow trailing={<Badge tone="amber">Working</Badge>}>Deploy Tool · Program report</ListRow><Progress value={progress / 100} label="Progress" /><div style={{ display: 'flex', gap: 14, padding: '0 18px 18px' }}><Done>Tests</Done><Badge tone={childDone ? 'green' : 'amber'}>Docs · {childDone ? 'Done' : 'Working'}</Badge></div></Panel> : notification ? <Panel title={shown ? 'app — Claude Code' : 'Notification History'}>{shown ? <Terminal frame={frame} fontSize={25} style={{ height: 435 }}><div style={{ color: color.violet }}>Claude Code · review</div><div style={{ marginTop: 18 }}>Review complete. Two focused changes are ready.</div><Code lines={['src/routes.ts', 'src/routes.test.ts']} /></Terminal> : <><div style={{ display: 'flex', gap: 12, padding: 18 }}>{['All', 'Unread', 'Failed', 'Pending'].map((label) => <Badge key={label} active={label === 'Unread'}>{label}</Badge>)}</div><ListRow active trailing={<Badge tone="green">Done</Badge>}>Claude Code · review</ListRow><div style={{ padding: '6px 22px 20px', color: color.muted, fontSize: 21 }}>Review complete. Open the source pane.</div><div style={{ display: 'flex', gap: 12, padding: 18 }}><Action active={frame >= 211}>Show Pane</Action><Action>Mark as Read</Action></div><ListRow>Mark All as Read</ListRow><ListRow>Remove</ListRow><ListRow>Clear History</ListRow></>}</Panel> : <Panel title="Agent Recognition Rules"><div style={{ padding: 18, display: 'flex', gap: 12 }}><Action active={frame < 62}>Add Agent…</Action><Action active={frame >= 62 && frame < 91}>Import…</Action><Action active={frame >= 111}>Export…</Action></div>{enabled && frame < 62 ? <Panel title="Edit Agent Rules" style={{ margin: 18 }}><Code lines={ruleLines} style={{ fontSize: 21, padding: 18, lineHeight: 1.6 }} /><div style={{ textAlign: 'right', padding: 16 }}><Action active={frame >= 43}>Save</Action></div></Panel> : <><ListRow active>{imported ? 'Deploy Tool' : 'Review Tool'} <Badge>Custom</Badge></ListRow><Panel title={exported ? 'Finder — exported agents.toml' : 'Import — agents.toml'} style={{ margin: 18 }}><Code lines={['[[agents]]', 'id = "deploy-tool"', 'name = "Deploy Tool"', 'executables = ["deploy-tool"]']} style={{ fontSize: 21, padding: 18, lineHeight: 1.6 }} />{!exported ? <div style={{ padding: 16, textAlign: 'right' }}><Action active={frame >= 78 && frame < 96}>Import</Action></div> : null}</Panel></>}</Panel>}
        </div>
      </div>
    </Shell>
  );
};

const UsageWindow = ({ label, value, reset }: { label: string; value: number; reset?: string }) => (
  <div style={{ padding: '10px 16px' }}>
    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 24, fontSize: 21 }}><span>{label}</span><span>{value}% used</span></div>
    <Progress value={value / 100} style={{ padding: '8px 0' }} />
    {reset ? <div style={{ fontSize: 20, color: color.muted }}>{reset}</div> : null}
  </div>
);

const AccountUsageDemo = ({ frame }: DemoProps) => {
  const enabled = frame >= 35;
  const refreshing = frame >= 116 && frame < 150;
  const claudeEnabled = frame < 185;
  return (
    <Shell title="Settings — AI · Account Usage">
      <div style={{ display: 'grid', gridTemplateColumns: '630px 1fr', height: '100%' }}>
        <div style={{ padding: 25, borderRight: `1px solid ${color.line}` }}>
          <Group title="Account Usage">
            <Setting label="Read account usage" checked={enabled} focus={frame < 80} />
            <Setting label="Read Claude Code usage" checked={claudeEnabled} focus={frame >= 175} />
            <Setting label="Read Codex usage" checked />
          </Group>
          <Panel title="Local CLI integrations">
            <ListRow>Claude Code · status-line report</ListRow>
            <ListRow>Codex · signed-in CLI</ListRow>
            <div style={{ padding: 20, fontSize: 23, color: color.muted, lineHeight: 1.6 }}>提供方报告的限额占用与重置时间</div>
          </Panel>
        </div>
        <div style={{ padding: 26 }}>
          <Panel title="Account Usage — reported limits">
            <div style={{ padding: 24 }}>
              {enabled ? <>
                {claudeEnabled ? <Group title="Claude Code">
                  <UsageWindow label="5-hour limit" value={32} reset="Resets Nov 13, 02:00" />
                  <UsageWindow label="7-day limit" value={18} />
                </Group> : null}
                <Group title="Codex">
                  <UsageWindow label="5-hour limit" value={frame >= 150 ? 47 : 46} reset="Resets Nov 13, 01:30" />
                  <UsageWindow label="1-week limit" value={24} />
                </Group>
                <div style={{ fontSize: 20, color: color.muted, marginBottom: 18 }}>{refreshing ? 'Refreshing…' : frame >= 150 ? 'Updated 23:32' : 'Updated 23:30'}</div>
                <Action active={frame >= 95 && frame < 150} disabled={refreshing}>Refresh Usage</Action>
              </> : <Badge active={false}>Turn on Read account usage</Badge>}
            </div>
          </Panel>
        </div>
      </div>
    </Shell>
  );
};

const AgentsBody = (props: DemoProps) => {
  if (props.step === 0) return <PaletteDemo {...props} />;
  if (props.step === 1) return <QueueDemo {...props} />;
  if (props.step === 2) return <HistoryDemo {...props} />;
  if (props.step === 4) return <AccountUsageDemo {...props} />;
  return <SettingsDemo {...props} />;
};

export const agentsChapter: ChapterSpec = {
  id: 'agents', en: 'Stay close to every agent', zh: '掌握每个智能体的上下文',
  steps: [
    { en: 'Find the agent that needs you', zh: '定位需要关注的智能体' },
    { en: 'Queue shell commands · send when ready', zh: '命令排队，空提示符再发送' },
    { en: 'Resume the context · fork a new path', zh: '续接原对话，分叉独立会话' },
    { en: 'Real state · progress · source notifications', zh: '识别规则、状态、进度与来源通知' },
    { en: 'Account usage, limits and reset times', zh: '账户用量、限额占用与重置时间' },
  ],
  features: [
    'Cmd+Option+A Agent palette search and navigation across running project panes',
    'Codex, Claude Code, Gemini CLI, Grok Build, OpenCode, Cursor Agent, Aider, Amp and Pi recognition',
    'Working, Blocked, Done and attention states with Native lifecycle, Program report, Screen inference or Process detection authority',
    'Next Agent Needing Attention and human-controlled permission prompts',
    'Per-terminal Prompt Queue, Add to Queue, Remove, manual Send Now and opt-in automatic dispatch in queue order',
    'Queue dispatch only to an empty original zsh prompt after command tasks finish; busy agent sends remain disabled',
    'Agent Conversation History, saved title/provider/directory search, Recent/All/Archived, Archive/Unarchive/Delete record',
    'Show or Resume the exact saved conversation in its original directory and configuration',
    'Provider-native Fork Conversation in New Pane with inherited context and independent conversation identity',
    'AI integrations, automatic conversation resume, custom recognition rules and screen inference switches',
    'Agent rule add/edit/import/export and native lifecycle priority over screen inference',
    'Explicit program reports, progress and child task states',
    'Agent attention and completion notifications, All/Unread/Failed/Pending history, Show Pane and read/remove/clear actions',
    'Opt-in local Claude Code / Codex account-limit reading, used percentages and reset times; Refresh Usage and independent provider switches',
  ],
  sources: [
    'mac/zshell/AgentPalette.swift', 'mac/zshell/TerminalManager.swift', 'mac/zshell/AgentAutomation.swift',
    'mac/zshell/TerminalPromptQueue.swift', 'mac/zshell/PromptQueueBarView.swift',
    'mac/zshell/AgentConversationHistoryController.swift', 'mac/zshell/TerminalConversationHistory.swift',
    'mac/zshell/Settings/SettingsAutomationPane.swift', 'mac/zshell/AgentRecognitionRulesController.swift',
    'mac/zshell/AgentStatusReporting.swift', 'mac/zshell/TerminalNotificationCenter.swift',
    'mac/zshell/AgentUsage.swift', 'mac/zshell/AgentUsageSettingsView.swift',
  ],
  Body: AgentsBody,
};
