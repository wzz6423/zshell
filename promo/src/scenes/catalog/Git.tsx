import { BranchIcon } from '../../components/Icons';
import { linear, mix } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import {
  Action,
  Badge,
  Done,
  Group,
  ListRow,
  Panel,
  Shell,
  pressAt,
  revealAt,
  type ChapterSpec,
  type DemoProps,
} from './Frame';

const DiffLine = ({ number, sign = ' ', children, selected = false, wrap = false }: { number: number; sign?: string; children: string; selected?: boolean; wrap?: boolean }) => {
  const tone = sign === '+' ? color.green : sign === '-' ? color.red : color.fg;
  return (
    <div
      className="font-mono"
      style={{
        display: 'flex',
        gap: 12,
        padding: '6px 16px',
        minHeight: 30,
        fontSize: 19,
        lineHeight: 1.5,
        backgroundColor: selected ? alpha(color.blue, 9) : sign !== ' ' ? alpha(tone, 8) : 'transparent',
        color: tone,
      }}
    >
      <span style={{ width: 26, flexShrink: 0, color: color.faint }}>{number}</span>
      <span style={{ width: 14, flexShrink: 0 }}>{sign}</span>
      <span style={{ whiteSpace: wrap ? 'pre-wrap' : 'pre', overflowWrap: wrap ? 'anywhere' : undefined }}>{children}</span>
    </div>
  );
};

const DiffAndBranchesStep = ({ frame, fps }: DemoProps) => {
  const split = revealAt(frame, fps, 48, true);
  const edit = frame >= 92;
  const savePress = pressAt(frame, 144);
  const saved = revealAt(frame, fps, 150);
  const conflictResolved = revealAt(frame, fps, 76);
  const branchDeleted = revealAt(frame, fps, 134);

  return (
    <Shell
      title="atlas — Live Diff, Conflicts & Branches"
      toolbar={
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <BranchIcon size={20} color={color.blue} />
          <span className="font-mono" style={{ fontSize: 19, fontWeight: 600 }}>feat/reconnect</span>
          <Badge tone="blue" style={{ padding: '4px 10px', fontSize: 15 }}>↑ 1  ↓ 0</Badge>
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
            <Action active={split < 0.5} style={{ padding: '6px 13px', fontSize: 16 }}>Unified</Action>
            <Action active={split >= 0.5} style={{ padding: '6px 13px', fontSize: 16 }}>Split</Action>
            <Action active={!edit} style={{ padding: '6px 13px', fontSize: 16 }}>Review</Action>
            <Action active={edit} style={{ padding: '6px 13px', fontSize: 16 }}>Edit</Action>
            <Action active style={{ padding: '6px 13px', fontSize: 16 }}>Wrap</Action>
          </span>
        </div>
      }
    >
      <div style={{ display: 'grid', gridTemplateColumns: '1.22fr 0.78fr', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}`, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <div style={{ display: 'flex', flex: 1, minHeight: 0, overflow: 'hidden' }}>
            {split > 0.01 ? (
              <div style={{ flex: split, minWidth: 0, opacity: Math.min(1, split * 1.4), borderRight: `1px solid ${color.line}`, overflow: 'hidden' }}>
                <div style={{ padding: '12px 18px', fontSize: 17, color: color.muted, borderBottom: `1px solid ${color.line}` }}>Before · HEAD</div>
                <DiffLine number={42}>{'function reconnect() {'}</DiffLine>
                <DiffLine number={43} sign="-">{'  resetScrollback();'}</DiffLine>
                <DiffLine number={44}>{'  attachTerminal();'}</DiffLine>
                <DiffLine number={45}>{'}'}</DiffLine>
              </div>
            ) : null}
            <div style={{ flex: 1, minWidth: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 18px', fontSize: 17, color: edit ? color.blue : color.muted, borderBottom: `1px solid ${color.line}` }}>
                {edit ? (saved > 0.5 ? 'Working tree · saved' : 'Working tree · editing live') : split > 0.5 ? 'After · working tree' : 'src/session.ts · @@ -42,4 +42,4 @@'}
              </div>
              <DiffLine number={42}>{'function reconnect() {'}</DiffLine>
              {split < 0.5 ? <DiffLine number={43} sign="-">{'  resetScrollback();'}</DiffLine> : null}
              <DiffLine number={43} sign="+" selected={edit} wrap>
                {edit ? '  restoreScrollback({ keepHistory: true, restoreCursor: true });' : '  restoreScrollback();'}
              </DiffLine>
              <DiffLine number={44}>{'  attachTerminal();'}</DiffLine>
              <DiffLine number={45}>{'}'}</DiffLine>
            </div>
          </div>

          <div style={{ padding: '14px 20px', borderTop: `1px solid ${color.line}`, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
            <Action active={edit && saved < 0.5} press={savePress} style={{ padding: '7px 14px', fontSize: 16 }}>Save ⌘S</Action>
            <Done progress={saved}>Saved to working tree</Done>
            <span style={{ marginLeft: 'auto', fontSize: 16, color: color.muted }}>
              Amend Last Commit · Recent commits up to 200 files
            </span>
          </div>
        </div>

        <div style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 14 }}>
          <Group title="Conflicts & Staging" style={{ marginBottom: 0 }}>
            <ListRow
              active={conflictResolved < 0.5}
              style={{ padding: '9px 14px', fontSize: 17 }}
              trailing={
                conflictResolved > 0.5 ? (
                  <Done progress={conflictResolved} style={{ fontSize: 14, padding: '4px 10px' }}>Staged</Done>
                ) : (
                  <Action active press={pressAt(frame, 70)} style={{ fontSize: 14, padding: '5px 10px' }}>Mark Resolved</Action>
                )
              }
            >
              src/merge.ts
            </ListRow>
          </Group>

          <Group title="Branches, Stash & Remotes" style={{ marginBottom: 0 }}>
            <ListRow style={{ padding: '8px 14px', fontSize: 17 }} trailing={<Badge active={false} style={{ fontSize: 14, padding: '2px 8px' }}>Default</Badge>}>main</ListRow>
            <ListRow active style={{ padding: '8px 14px', fontSize: 17 }}>feat/reconnect</ListRow>
            <div style={{ padding: '10px 14px', display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <Badge active={false} style={{ fontSize: 14, padding: '4px 9px' }}>Stash All (incl. untracked)</Badge>
              <Badge active={false} style={{ fontSize: 14, padding: '4px 9px' }}>Pull --ff-only</Badge>
              <Badge active={false} style={{ fontSize: 14, padding: '4px 9px' }}>Sync</Badge>
            </div>
          </Group>

          <Panel
            title="Safe Branch Delete"
            style={{
              opacity: mix(0.45, 1, branchDeleted),
              transform: `translateY(${(1 - branchDeleted) * 8}px)`,
            }}
          >
            <div className="font-mono" style={{ padding: '12px 14px', fontSize: 15, lineHeight: 1.55, color: color.muted }}>
              <div style={{ color: color.green }}>Backup saved: refs/zshell/deleted-branches/…</div>
              <div>Local edits stashed · Keep or Remove Worktree on close</div>
            </div>
          </Panel>
        </div>
      </div>
    </Shell>
  );
};

const PullRequestStep = ({ frame, fps }: DemoProps) => {
  const replyText = 'Preserved scrollback across reconnects and added a check.';
  const typedReply = replyText.slice(0, typedLength(replyText, frame, 16, 72));
  const replied = revealAt(frame, fps, 82);
  const replyPress = pressAt(frame, 78);
  const resolved = revealAt(frame, fps, 114);
  const resolvePress = pressAt(frame, 108);
  const reviewMode = revealAt(frame, fps, 138);
  const submitPress = pressAt(frame, 178);
  const approved = revealAt(frame, fps, 184);

  return (
    <Shell
      title="atlas — GitHub Pull Request Review"
      toolbar={
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <BranchIcon size={20} color={color.blue} />
          <span className="font-mono" style={{ fontSize: 19, fontWeight: 600 }}>feat/reconnect</span>
          <Badge tone="green">#128 Open</Badge>
          <Badge active>PR Comments</Badge>
          <Badge active={false}>Git Proxy Ready</Badge>
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 10 }}>
            <Action style={{ padding: '6px 13px', fontSize: 16 }}>Back to Changes</Action>
            <Action style={{ padding: '6px 13px', fontSize: 16 }}>Open on GitHub</Action>
          </span>
        </div>
      }
    >
      <div style={{ display: 'grid', gridTemplateColumns: '0.92fr 1.08fr', height: '100%' }}>
        <div style={{ borderRight: `1px solid ${color.line}`, paddingTop: 14 }}>
          <div style={{ padding: '8px 20px 16px', fontSize: 20, display: 'flex', alignItems: 'center', gap: 12 }}>
            <span className="font-mono">src/session.ts</span>
            <Badge active={false} style={{ fontSize: 14, padding: '3px 9px' }}>Read-only PR diff</Badge>
          </div>
          <DiffLine number={42}>{'function reconnect() {'}</DiffLine>
          <DiffLine number={43} sign="-">{'  resetScrollback();'}</DiffLine>
          <DiffLine number={43} sign="+" selected>{'  restoreScrollback();'}</DiffLine>
          <DiffLine number={44}>{'  attachTerminal();'}</DiffLine>
          <DiffLine number={45}>{'}'}</DiffLine>
          <Panel style={{ margin: '20px 18px', padding: 18, borderColor: alpha(color.blue, 34) }}>
            <div style={{ fontSize: 17, fontWeight: 600, color: color.blue, marginBottom: 8 }}>Inline discussion · line 43</div>
            <div style={{ fontSize: 19, lineHeight: 1.55 }}>Can we keep the existing scrollback when reconnecting?</div>
          </Panel>
        </div>

        <div style={{ padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 24, fontWeight: 650 }}>
              {reviewMode > 0.5 ? 'Review Pull Request…' : 'Review discussion'}
            </span>
            <Badge tone={approved > 0.5 || resolved > 0.5 ? 'green' : 'blue'}>
              {approved > 0.5 ? 'Approved' : resolved > 0.5 ? 'Resolved' : 'Open thread'}
            </Badge>
          </div>

          <Panel style={{ padding: 18 }}>
            <div style={{ fontSize: 16, color: color.muted, marginBottom: 8 }}>Reviewer · src/session.ts:43</div>
            <div style={{ fontSize: 19, lineHeight: 1.55 }}>Can we keep the existing scrollback when reconnecting?</div>
            {replied > 0.01 ? (
              <div style={{ marginTop: 12, paddingTop: 12, borderTop: `1px solid ${color.line}`, color: color.green, fontSize: 18, opacity: replied, transform: `translateY(${(1 - replied) * 6}px)` }}>
                You: {replyText}
              </div>
            ) : null}
          </Panel>

          <div
            style={{
              padding: '14px 18px',
              border: `1px solid ${color.blue}`,
              borderRadius: 10,
              minHeight: 58,
              fontSize: 19,
              lineHeight: 1.5,
              color: color.fg,
              backgroundColor: alpha(color.blue, 3),
            }}
          >
            {reviewMode > 0.5
              ? 'Looks clean — verified reconnect preserves terminal context.'
              : replied > 0.5
                ? <span style={{ color: color.faint }}>Reply to thread…</span>
                : typedReply}
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
            {reviewMode > 0.5 ? (
              <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', opacity: linear(frame, [138, 152]) }}>
                <Action style={{ fontSize: 16, padding: '7px 14px' }}>Comment</Action>
                <Action active tone="green" style={{ fontSize: 16, padding: '7px 14px' }}>Approve</Action>
                <Action style={{ fontSize: 16, padding: '7px 14px' }}>Request Changes</Action>
                <Action active press={submitPress} style={{ fontSize: 16, padding: '7px 14px' }}>Submit Review</Action>
              </div>
            ) : (
              <>
                <Action active={replied < 0.5} press={replyPress} style={{ fontSize: 16, padding: '7px 14px' }}>Reply</Action>
                <Action active={replied >= 0.5 && resolved < 0.5} press={resolvePress} style={{ fontSize: 16, padding: '7px 14px' }}>
                  {resolved > 0.5 ? 'Reopen Discussion' : 'Resolve Discussion'}
                </Action>
              </>
            )}
          </div>

          <div style={{ marginTop: 'auto' }}>
            <Done progress={approved}>Review submitted for the displayed commit</Done>
          </div>
        </div>
      </div>
    </Shell>
  );
};

const GitBody = (props: DemoProps) =>
  props.step === 0 ? <DiffAndBranchesStep {...props} /> : <PullRequestStep {...props} />;

export const gitChapter: ChapterSpec = {
  id: 'git',
  en: 'Git & Pull Requests',
  zh: 'Git 差异、分支与审查',
  nav: 'Git 与审查',
  steps: [
    { en: 'Live editable diffs, conflicts & branch safety', zh: 'Unified 与 Split 实时编辑、冲突解决与安全删分支' },
    { en: 'GitHub pull requests right beside your diff', zh: '在代码旁阅读、回复、解决讨论并提交 PR 审查' },
  ],
  features: [
    'Unified and Split diff layouts with line wrapping and live working-tree editing and saving',
    'Conflict Mark Resolved (Stage), Amend Last Commit and recent commits up to 200 files',
    'Branches, Stash All Changes (including untracked), Pull (Fast-forward Only), Sync and safe branch delete with backup refs',
    'Worktree session close options (Keep Worktree / Remove Worktree / Cancel)',
    'GitHub PR status, inline PR Comments read-only diff, Reply, Resolve/Reopen Discussion and Comment/Approve/Request Changes review submission',
  ],
  sources: [
    'web/content/docs/git.mdx',
    'mac/zshell/AppKitGitPanelView.swift',
    'mac/zshell/DiffViewerView.swift',
    'mac/zshell/AppKitGitPullRequestView.swift',
    'mac/zshell/ProjectPullRequestReviewController.swift',
    'mac/zshell/RecentCommitsView.swift',
  ],
  Body: GitBody,
};
