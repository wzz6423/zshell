import { BranchIcon } from '../../components/Icons';
import { linear, ramp } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import { Action, Badge, Done, Group, ListRow, Panel, Progress, Setting, Shell, Terminal, type ChapterSpec, type DemoProps } from './Frame';

const DiffLine = ({ number, sign = ' ', children, selected = false, wrap = false }: { number: number; sign?: string; children: string; selected?: boolean; wrap?: boolean }) => {
  const tone = sign === '+' ? color.green : sign === '-' ? color.red : color.fg;
  return <div className="font-mono" style={{ display: 'flex', gap: 15, padding: '7px 20px', minHeight: 32, fontSize: 23, lineHeight: 1.5, backgroundColor: selected ? alpha(color.blue, 8) : sign !== ' ' ? alpha(tone, 8) : 'transparent', color: tone }}><span style={{ width: 30, flexShrink: 0, color: color.faint }}>{number}</span><span style={{ width: 17, flexShrink: 0 }}>{sign}</span><span style={{ whiteSpace: wrap ? 'pre-wrap' : 'pre', overflowWrap: wrap ? 'anywhere' : undefined }}>{children}</span></div>;
};

const LiveDiff = ({ frame }: { frame: number }) => {
  const split = frame >= 70;
  const edit = frame >= 94;
  const wrap = frame >= 124;
  const saved = frame >= 153;
  if (frame < 18) return <Shell title="atlas — Git"><div style={{ padding: 55 }}><div style={{ fontSize: 34, fontWeight: 650, marginBottom: 26 }}>No Git Repository</div><Action active={frame < 10}>Initialize Repository</Action><Terminal frame={frame} command="" fontSize={25} style={{ padding: '30px 0' }}><div style={{ opacity: linear(frame, [7, 12]) }}>› git init</div>{frame >= 12 ? <Done>Initialized repository in ~/src/atlas</Done> : null}</Terminal></div></Shell>;
  if (frame < 42) return <Shell title="atlas — Resolve Conflict" sidebar={<><ListRow>Conflicts</ListRow>{frame < 31 ? <ListRow active trailing={<Badge tone="amber">U</Badge>}>session.ts</ListRow> : null}<ListRow>Staged Changes</ListRow>{frame >= 31 ? <ListRow active trailing={<Badge tone="green">M</Badge>}>session.ts</ListRow> : null}</>}><div style={{ padding: 28 }}><div style={{ fontSize: 27, fontWeight: 650, marginBottom: 24 }}>src/session.ts</div><Panel style={{ padding: '16px 0' }}><DiffLine number={42}>{'function reconnect() {'}</DiffLine><DiffLine number={43} sign="+">{'  restoreScrollback();'}</DiffLine><DiffLine number={44}>{'  attachTerminal();'}</DiffLine><DiffLine number={45}>{'}'}</DiffLine></Panel><div style={{ display: 'flex', gap: 20, marginTop: 28 }}><Action active={frame < 31}>Mark Resolved (Stage)</Action>{frame >= 31 ? <Done>Conflict resolved · file staged</Done> : <Badge tone="amber">Resolved source awaits staging</Badge>}</div></div></Shell>;
  if (frame >= 173) return <Shell title="atlas — Amend and Recent Commits"><div style={{ display: 'grid', gridTemplateColumns: '0.93fr 1.07fr', gap: 30, padding: 30 }}><div><Group title="Staged Changes"><ListRow active trailing={<Badge tone="green">M</Badge>}>src/session.ts</ListRow></Group><Panel style={{ padding: '18px 20px', fontSize: 23, marginBottom: 20 }}>{'fix: preserve terminal history'.slice(0, typedLength('fix: preserve terminal history', frame, 176, 198))}</Panel><Panel title="Commit actions"><ListRow>Commit Staged</ListRow><ListRow>Stage All & Commit</ListRow><ListRow active={frame < 219}>Amend Last Commit</ListRow><ListRow>Stage All & Amend</ListRow></Panel></div><div><Group title="Recent Commits">{frame >= 219 ? <ListRow active trailing={<Badge tone="green">Amended</Badge>}>fix: preserve terminal history</ListRow> : <ListRow>fix: restore terminal history</ListRow>}<ListRow trailing={<Badge tone="violet">v1.3.0</Badge>}>release: 1.3.0</ListRow><ListRow>fix: reconnect sessions</ListRow></Group><Panel title="Commit context menu"><ListRow>Copy Commit Hash</ListRow><ListRow>Copy Commit Message</ListRow></Panel><div style={{ marginTop: 26 }}>{frame >= 219 ? <Done>Last commit amended · tree clean</Done> : <Action active>Amend Last Commit</Action>}</div><div style={{ marginTop: 24, fontSize: 23, color: color.muted }}>提交记录保留 Tag 和分支上下文</div></div></div></Shell>;
  return (
    <Shell title="atlas — Git + Diff" sidebar={<><div style={{ display: 'flex', gap: 12, alignItems: 'center', marginBottom: 12, fontSize: 21 }}><BranchIcon size={24} color={color.blue} />feat/reconnect</div><ListRow style={{ padding: '8px 12px', fontSize: 19 }} trailing={<Badge tone="amber">2</Badge>}>Unstaged Changes</ListRow><ListRow active trailing={<span style={{ color: color.amber }}>M</span>}>src/session.ts</ListRow>{frame < 140 ? <ListRow trailing={<span style={{ color: color.green }}>A</span>}>src/reconnect.ts</ListRow> : null}<ListRow style={{ padding: '8px 12px', fontSize: 19 }}>Staged Changes</ListRow>{frame < 78 ? <ListRow active={frame >= 65}>README.md · staged</ListRow> : <Badge>README.md unstaged</Badge>}<div style={{ margin: '12px 0' }}><Panel title="Filter changed files"><div style={{ padding: 10, fontSize: 19 }}>{frame >= 140 ? 'session' : 'Filename…'}</div></Panel><div style={{ marginTop: 15, display: 'flex', flexWrap: 'wrap', gap: 10 }}><Action active={frame >= 65 && frame < 90}>Unstage</Action><Action>Stage</Action><Action>Discard</Action></div></div></>}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '17px 24px', borderBottom: `1px solid ${color.line}` }}>
        <span style={{ fontSize: 23 }}>src/session.ts</span>
        <span style={{ marginLeft: 'auto', display: 'flex', gap: 12 }}><Action active={!split}>Unified</Action><Action active={split}>Split</Action><Action active={!edit}>Review</Action><Action active={edit}>Edit</Action><Action active={wrap}>Wrap</Action></span>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: split ? 'minmax(0, 1fr) minmax(0, 1fr)' : '1fr', height: 385, overflow: 'hidden' }}>
        {split ? <div style={{ minWidth: 0, overflow: 'hidden', borderRight: `1px solid ${color.line}` }}><div style={{ padding: '18px 24px', fontSize: 21, color: color.muted, borderBottom: `1px solid ${color.line}` }}>Before</div><DiffLine number={42}>{'function reconnect() {'}</DiffLine><DiffLine number={43} sign="-">{'  resetScrollback();'}</DiffLine><DiffLine number={44}>{'  attachTerminal();'}</DiffLine><DiffLine number={45}>{'}'}</DiffLine></div> : null}
        <div style={{ minWidth: 0, overflow: 'hidden' }}><div style={{ padding: '18px 24px', fontSize: 21, color: edit ? color.blue : color.muted, borderBottom: `1px solid ${color.line}` }}>{edit ? saved ? 'Working tree · saved' : 'Working tree · editing' : split ? 'After' : '@@ -42,5 +42,5 @@'}</div><DiffLine number={42}>{'function reconnect() {'}</DiffLine>{!split ? <DiffLine number={43} sign="-">{'  resetScrollback();'}</DiffLine> : null}<DiffLine number={43} sign="+" selected={edit} wrap={wrap}>{edit ? '  restoreScrollback({ keepHistory: true, restoreCursor: true });' : '  restoreScrollback();'}</DiffLine><DiffLine number={44}>{'  attachTerminal();'}</DiffLine><DiffLine number={45}>{'}'}</DiffLine></div>
      </div>
      <div style={{ padding: 24, borderTop: `1px solid ${color.line}`, display: 'flex', alignItems: 'center', gap: 18 }}><Action active={frame >= 141 && frame < 153}>Save ⌘S</Action>{saved ? <Done>Saved to the working tree</Done> : <Badge tone={edit ? 'amber' : 'blue'}>{edit ? 'Unsaved changes' : 'Review the change beside your terminal'}</Badge>}<span style={{ fontSize: 23, color: color.muted, marginLeft: 'auto' }}>{saved ? '改完直接保存，继续查看差异' : '同一面板切换阅读与编辑'}</span></div>
    </Shell>
  );
};

const BranchesAndRemotes = ({ frame }: { frame: number }) => {
  const phase = Math.min(3, Math.floor(frame / 60));
  const deleted = frame >= 106;
  const closed = frame >= 232;
  const remoteActions = ['Fetch', 'Pull (Fast-forward Only)', 'Push', 'Publish Branch', 'Sync Changes'];
  const activeRemote = phase < 2 ? -1 : phase === 2 ? Math.min(1, Math.floor((frame - 120) / 30)) : frame < 195 ? 2 : frame < 208 ? 3 : 4;
  const outputs = [
    ['› git switch -c feat/review', '› git switch main', '› git worktree add', '    ../atlas-review feat/review', 'Preparing worktree (branch feat/review)'],
    frame < 90 ? ['› git stash push --include-untracked', 'Tracked and untracked changes saved', '› git stash pop', 'Changes restored to the working tree'] : ['Delete Branch… feat/old', 'Saved branch backup:', 'refs/zshell/deleted-branches/', '  92FA7B15…/feat/old', 'Local changes saved in stash', 'Branch deleted · commits recoverable'],
    frame < 150 ? ['› git fetch', 'Remote-tracking refs updated'] : ['› git pull --ff-only', 'Updating 9a4e821..8b31cd0', 'Fast-forward'],
    frame < 195 ? ['› git push', 'Branch pushed to origin'] : frame < 208 ? ['› git push --set-upstream origin feat/review', "Branch now tracks 'origin/feat/review'"] : ['› git pull --ff-only', 'Already up to date.', '› git push', 'Everything up-to-date'],
  ][phase];
  return (
    <Shell title="atlas — Branches, Worktrees, Remotes">
      <div style={{ display: 'grid', gridTemplateColumns: '0.9fr 1.1fr', height: '100%' }}>
        <div style={{ padding: 28, borderRight: `1px solid ${color.line}` }}>
          <Group title="Branches" style={{ marginBottom: 14 }}><ListRow active={frame >= 25 && frame < 48}>main <span style={{ marginLeft: 18, fontSize: 20, color: color.muted }}>Default</span></ListRow><ListRow active={frame < 25 || frame >= 48 && frame < 90}>feat/review</ListRow>{frame >= 60 && !deleted ? <ListRow active={frame >= 90}>feat/old</ListRow> : null}<div style={{ padding: 12 }}><Action active={frame < 28 || frame >= 90 && frame < 106}>{frame >= 90 && frame < 120 ? 'Delete Branch…' : 'Create New Branch…'}</Action></div></Group>
          <Group title="Worktrees · project checkout" style={{ marginBottom: 14 }}><ListRow trailing={<Badge>Current</Badge>}>{frame < 25 ? 'feat/review' : 'main'} · ~/src/atlas</ListRow>{frame >= 42 ? <ListRow active={frame >= 48} trailing={frame >= 48 ? <Badge>Terminal tab</Badge> : undefined}>feat/review · ../atlas-review</ListRow> : null}<div style={{ padding: 12 }}><Action active={frame >= 28 && frame < 48}>Create Worktree…</Action></div></Group>
          <div style={{ display: 'flex', gap: 14 }}><Action active={frame >= 64 && frame < 76}>Stash All Changes</Action><Action active={frame >= 76 && frame < 90}>Pop Stash</Action></div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '290px 1fr', minWidth: 0 }}>
          <Panel title="⋯ Remote actions" style={{ margin: '28px 0 28px 24px' }}>{remoteActions.map((action, index) => <ListRow key={action} active={index === activeRemote} style={{ fontSize: 21, padding: '17px 18px' }}>{action}</ListRow>)}</Panel>
          <div style={{ minWidth: 0, position: 'relative' }}><Terminal frame={frame} command="" fontSize={23} directory={frame < 48 ? '~/src/atlas' : '~/src/atlas-review'} branch={frame >= 25 && frame < 48 ? 'main' : 'feat/review'}>
            <div style={{ marginBottom: 22 }}><Badge>{phase < 2 ? frame >= 25 && frame < 48 ? 'main · source checkout' : 'feat/review · terminal tab' : frame >= 211 ? '↑ 0  ↓ 0' : '↑ 1  ↓ 1'}</Badge></div>
            {outputs.map((line, index) => <div key={`${phase}-${index}`} style={{ marginBottom: 14, lineHeight: 1.55, overflowWrap: 'anywhere', color: line.startsWith('›') ? color.fg : color.green, opacity: linear(phase === 1 && frame >= 90 ? frame - 90 : phase === 2 && frame >= 150 ? frame - 150 : phase === 3 ? frame - (frame < 195 ? 180 : frame < 208 ? 195 : 208) : frame % 60, [index * 2, index * 2 + 4]) }}>{line}</div>)}
          </Terminal><div style={{ position: 'absolute', bottom: 28, left: 28, right: 28 }}>{frame >= 217 ? <Panel style={{ padding: 18 }}><div style={{ fontSize: 23, fontWeight: 600, marginBottom: 16 }}>Close worktree session?</div><div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}><Action active={!closed}>Keep Worktree</Action><Action>Remove Worktree</Action><Action>Cancel</Action></div>{closed ? <div style={{ marginTop: 18 }}><Done>Session closed · worktree kept</Done></div> : null}</Panel> : frame >= 211 ? <Done>Branch synchronized</Done> : <div style={{ fontSize: 23, color: color.muted }}>{phase === 0 ? '分支与 worktree 各自保留 shell 上下文' : phase === 1 ? frame >= 90 ? '删除分支前保存恢复引用与 stash' : '暂存与恢复包括未跟踪文件' : phase === 2 ? 'Pull 只执行 Fast-forward' : '推送、发布分支与同步'}</div>}</div></div>
        </div>
      </div>
    </Shell>
  );
};

const PullRequestReview = ({ frame }: { frame: number }) => {
  const replied = frame >= 74;
  const resolved = frame >= 112 && frame < 154;
  const review = frame >= 162;
  const approved = frame >= 220;
  const reply = 'Updated the reconnect path and verified scrollback.';
  return (
    <Shell title="atlas — Pull Request Review" toolbar={<div style={{ display: 'flex', alignItems: 'center', gap: 16 }}><BranchIcon size={24} color={color.blue} /><span style={{ fontSize: 23 }}>feat/reconnect</span><Badge tone="green">#128 Open</Badge><Action active>PR Comments</Action><span style={{ marginLeft: 'auto' }}><Action>Back to Changes</Action></span><Action>Open on GitHub</Action></div>}>
      <div style={{ display: 'grid', gridTemplateColumns: '0.85fr 1.15fr', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}`, paddingTop: 18 }}><div style={{ padding: '12px 26px 24px', fontSize: 24 }}>src/session.ts <span style={{ marginLeft: 16, color: color.muted, fontSize: 21 }}>Read-only</span></div><DiffLine number={42}>{'function reconnect() {'}</DiffLine><DiffLine number={43} sign="-">{'  resetScrollback();'}</DiffLine><DiffLine number={43} sign="+">{'  restoreScrollback();'}</DiffLine><DiffLine number={44}>{'  attachTerminal();'}</DiffLine><DiffLine number={45}>{'}'}</DiffLine><Panel style={{ margin: '26px 24px', padding: 24 }}><div style={{ fontSize: 22, color: color.blue, marginBottom: 16 }}>Review discussion · line 43</div><div style={{ fontSize: 23, lineHeight: 1.6 }}>Can we keep the existing scrollback when reconnecting?</div></Panel></div>
        <div style={{ padding: 28 }}>
          <div style={{ display: 'flex', gap: 16, alignItems: 'center', marginBottom: 20 }}><span style={{ fontSize: 26, fontWeight: 650 }}>{review ? 'Review Pull Request…' : 'Review discussion'}</span><span style={{ marginLeft: 'auto' }}><Badge tone={resolved || approved ? 'green' : 'blue'}>{approved ? 'Approved' : resolved ? 'Resolved' : 'Open'}</Badge></span></div>
          <Panel style={{ padding: 24, minHeight: 168 }}>
            <div style={{ fontSize: 20, color: color.muted, marginBottom: 14 }}>Reviewer · src/session.ts:43</div>
            <div style={{ fontSize: 23, lineHeight: 1.65 }}>Can we keep the existing scrollback when reconnecting?</div>
            {replied ? <div style={{ marginTop: 18, color: color.green, fontSize: 22 }}>{reply}</div> : null}
          </Panel>
          <div style={{ marginTop: 20, padding: '17px 20px', border: `1px solid ${color.blue}`, borderRadius: 10, minHeight: 73, fontSize: 23, lineHeight: 1.6, color: color.fg }}>{review ? 'The new reconnect behavior preserves terminal context.' : replied ? <span style={{ color: color.faint }}>Reply</span> : reply.slice(0, typedLength(reply, frame, 18, 64))}</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 14, marginTop: 20 }}>
            {review ? <><Action active={frame < 183}>Comment</Action><Action active={frame >= 205}>Approve</Action><Action active={frame >= 183 && frame < 205}>Request Changes</Action><Action active={frame >= 214 && !approved}>Submit Review</Action></> : <><Action active={frame >= 55 && frame < 74}>Reply</Action><Action active={frame >= 90 && frame < 112 || frame >= 136 && frame < 154}>{resolved ? 'Reopen Discussion' : 'Resolve Discussion'}</Action><Action>Review Pull Request…</Action></>}
          </div>
          <div style={{ marginTop: 22 }}>{approved ? <Done>Review submitted for the displayed commit</Done> : <div style={{ fontSize: 23, color: color.muted }}>{review ? '选择 Comment、Approve 或 Request Changes' : resolved ? '讨论已解决，可按需重新打开' : replied ? '回复与讨论状态同步到 GitHub' : '直接在差异旁阅读和回复评论'}</div>}</div>
        </div>
      </div>
    </Shell>
  );
};

const TurnReview = ({ frame }: { frame: number }) => {
  const protectedState = frame >= 183;
  const second = frame >= 95 && !protectedState;
  const kept = frame >= 52;
  const reverted = frame >= 149;
  return (
    <Shell title="Agent Turn Review" toolbar={<div style={{ display: 'flex', gap: 16, alignItems: 'center' }}><Action active>Latest Turn</Action><Action>Uncommitted</Action><Action>Entire Branch</Action><span style={{ fontSize: 23, marginLeft: 'auto', color: color.muted }}>Pi · completed turn</span></div>}>
      <div style={{ display: 'grid', gridTemplateColumns: '0.69fr 1.31fr', height: '100%' }}>
        <div style={{ padding: 24, borderRight: `1px solid ${color.line}` }}>
          <div style={{ fontSize: 21, color: color.muted, marginBottom: 14 }}>Turn changes</div>
          <ListRow active>src/session.ts</ListRow>
          <ListRow active={!second && !protectedState} indent={12} trailing={kept ? <Badge tone="green">Kept</Badge> : undefined}>Hunk 1 · reconnect</ListRow>
          <ListRow active={second} indent={12} trailing={reverted ? <Badge tone="amber">Reverted</Badge> : undefined}>Hunk 2 · debug output</ListRow>
          {protectedState ? <ListRow active indent={12}>Hunk 3 · retry count</ListRow> : null}
          <div style={{ marginTop: 32 }}><Panel><Setting label="Staged files" value="0" /><Setting label="Working tree" value={protectedState ? 'New external edit' : reverted ? 'Hunk 2 reverted' : 'Changes present'} /></Panel></div>
          <div style={{ margin: '26px 10px', fontSize: 23, color: color.muted, lineHeight: 1.6 }}>{protectedState ? '发现新的改动时，保护当前工作区' : reverted ? '快照与每段审查决定继续保留' : kept ? 'Keep 记录已审查，Git 暂存区保持不变' : '按 Agent 本次回合检查每段改动'}</div>
        </div>
        <div style={{ padding: 24 }}>
          <div style={{ display: 'flex', gap: 18, alignItems: 'center', marginBottom: 20 }}><span style={{ fontSize: 24 }}>{protectedState ? '@@ -101,3 +101,3 @@' : second ? '@@ -70,3 +70,4 @@' : '@@ -42,5 +42,5 @@'}</span><span style={{ marginLeft: 'auto' }}><Badge tone={protectedState ? 'blue' : second && reverted ? 'amber' : kept && !second ? 'green' : 'blue'}>{protectedState ? 'Unreviewed' : second ? reverted ? 'Reverted' : 'Unreviewed' : kept ? 'Kept' : 'Unreviewed'}</Badge></span></div>
          <Panel style={{ minHeight: 210, padding: '12px 0' }}>{protectedState ? <><DiffLine number={101}>{'function retry() {'}</DiffLine><DiffLine number={102} sign="-">{'  attempts = 1;'}</DiffLine><DiffLine number={102} sign="+">{'  attempts = 3;'}</DiffLine><DiffLine number={103}>{'}'}</DiffLine></> : second ? <><DiffLine number={70}>{'function restore() {'}</DiffLine><DiffLine number={71} sign="+">{'  console.log(snapshot);'}</DiffLine><DiffLine number={72}>{'  restoreScrollback(snapshot);'}</DiffLine><DiffLine number={73}>{'}'}</DiffLine></> : <><DiffLine number={42}>{'function reconnect() {'}</DiffLine><DiffLine number={43} sign="-">{'  resetScrollback();'}</DiffLine><DiffLine number={43} sign="+">{'  restoreScrollback();'}</DiffLine><DiffLine number={44}>{'  attachTerminal();'}</DiffLine><DiffLine number={45}>{'}'}</DiffLine></>}</Panel>
          <div style={{ display: 'flex', gap: 16, marginTop: 24 }}><Action active={frame >= 30 && frame < 52} disabled={second && reverted}>Keep Hunk</Action><Action active={frame >= 121 && frame < 149} disabled={second && reverted || protectedState} tone="red">Revert Hunk</Action><span style={{ marginLeft: 'auto', fontSize: 23, color: color.muted, alignSelf: 'center' }}>Git index unchanged</span></div>
          <div style={{ marginTop: 24 }}>{protectedState ? <Panel style={{ padding: 22, backgroundColor: alpha(color.amber, 5) }}><div style={{ fontSize: 23, color: color.amber, marginBottom: 14 }}>{frame >= 216 ? 'Revert unavailable · overlapping turns' : 'Revert cancelled · file changed'}</div><div style={{ fontSize: 22, lineHeight: 1.6, color: color.muted }}>{frame >= 216 ? 'Concurrent agent turns share this snapshot. Revert is unavailable.' : 'The file changed after this review snapshot. Revert was cancelled.'}</div></Panel> : reverted ? <Done>Hunk reverted in the working tree</Done> : kept ? <Done>Hunk marked reviewed</Done> : <Progress value={ramp(frame, [0, 30])} label="Loading completed turn" />}</div>
        </div>
      </div>
    </Shell>
  );
};

const GitBody = ({ step, frame, fps }: DemoProps) => {
  const tick = frame * 60 / fps;
  return <div style={{ height: '100%', padding: 24, boxSizing: 'border-box' }}>{step === 0 ? <LiveDiff frame={tick} /> : step === 1 ? <BranchesAndRemotes frame={tick} /> : step === 2 ? <PullRequestReview frame={tick} /> : <TurnReview frame={tick} />}</div>;
};

export const gitChapter: ChapterSpec = {
  id: 'git', en: 'Inspect. Review. Ship.', zh: '看清改动，再提交和推送',
  steps: [
    { en: 'Review and edit the live diff', zh: 'Unified、Split、编辑、换行和保存' },
    { en: 'Branches, worktrees, remotes', zh: '分支隔离、stash、Fetch、Pull 与同步' },
    { en: 'Pull requests beside your code', zh: '状态、评论、回复和提交审查' },
    { en: 'Review one agent turn at a time', zh: '按片段保留与回退，保护已有改动' },
  ],
  features: [
    'Project-rooted Git panel; conflicts / staged / unstaged groups; stage / unstage / discard / filename filter',
    'Conflicted paths use Mark Resolved (Stage); Discard All Changes confirms explicitly',
    'No Git Repository → Initialize Repository result; conflict source explicitly marked resolved and staged',
    'Unified / Split diff layouts; Review / Edit for eligible unstaged live-worktree files',
    'Wrap lines to diff width and remembered global diff preferences; staged and historical snapshots remain read-only',
    'Edit the new diff side and Save to working tree; protects drafts across layout/wrap changes and dirty-close handling',
    'Existing launch-video Git Bento retains stage → commit → push workflow',
    'Commit Staged / Stage All & Commit / Amend / Stage All & Amend; recent commits with tags and copy actions',
    'Branch search / switch / Create New Branch / Create Worktree; active worktree path and Current state',
    'Worktree opens its own shell context in a terminal tab; collapse branches/worktrees independently',
    'Worktree session close offers Keep Worktree / Remove Worktree / Cancel; Keep closes session and preserves checkout',
    'Branch deletion preserves backup refs and stashes tracked/untracked changes',
    'Stash All Changes includes untracked files; Pop Stash restores latest stash',
    'Fetch / Pull (Fast-forward Only) / Push / Publish Branch / Sync Changes; upstream ahead/behind badges',
    'Local GitHub PR number and status with GitHub CLI authentication; status refresh / Open on GitHub',
    'PR Comments read-only comparison; hides outdated discussions; Back to Changes',
    'Full review discussion / Reply / Resolve Discussion / Reopen Discussion when permitted',
    'Review Pull Request: Comment / Approve / Request Changes for displayed commit; validates branch and PR revision',
    'Failed PR submissions retain drafts; uncertain outcomes require checking GitHub before retry',
    'Agent Turn Review scopes Latest Turn / Uncommitted / Entire Branch; per-file and per-hunk snapshot inspection',
    'Keep Hunk marks reviewed; Revert Hunk reverses working tree; both preserve Git index',
    'Original turn snapshot and Kept/Reverted decisions remain visible after actions',
    'Revert protects changed file/HEAD, unsafe paths, active agents and overlapping turns; binary/mode-only changes read-only',
  ],
  sources: [
    'web/content/docs/git.mdx', 'mac/zshell/AppKitGitPanelView.swift', 'mac/zshell/GitStatusModel.swift',
    'mac/zshell/DiffViewerView.swift', 'mac/zshell/AppKitGitPullRequestView.swift',
    'mac/zshell/ProjectPullRequestReviewController.swift', 'mac/zshell/ProjectPullRequestReviewActions.swift',
    'mac/zshell/AgentReviewWindow.swift', 'mac/zshell/AgentTurnReview.swift',
  ],
  Body: GitBody,
};
