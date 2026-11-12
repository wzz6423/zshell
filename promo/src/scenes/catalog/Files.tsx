import { Img } from 'remotion';
import icon from '../../../../web/public/zshell-icon.png';
import { FolderIcon, SearchIcon } from '../../components/Icons';
import { linear, ramp } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import { Action, Badge, Code, Done, ListRow, Panel, Setting, Shell, type ChapterSpec, type DemoProps } from './Frame';

const FileRow = ({ name, folder = false, indent = 0, active = false, status }: { name: string; folder?: boolean; indent?: number; active?: boolean; status?: string }) => (
  <ListRow active={active} indent={indent} trailing={status ? <span style={{ fontSize: 20, color: status === 'M' ? color.amber : color.green }}>{status}</span> : undefined}>
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 12 }}>{folder ? <FolderIcon size={24} color={color.blue} /> : <span style={{ fontSize: 18, color: name.endsWith('.ts') ? color.blue : color.muted }}>{name.endsWith('.ts') ? 'TS' : '◇'}</span>}{name}</span>
  </ListRow>
);

const SourceLines = ({ saved = false, find = false, wrap = false, short = false }: { saved?: boolean; find?: boolean; wrap?: boolean; short?: boolean }) => (
  <div className="font-mono" style={{ padding: 24, fontSize: 23, lineHeight: 1.6 }}>
    {[
      <><span style={{ color: color.violet }}>export const</span> project = {'{'}</>,
      <><span style={{ color: color.blue }}>  name</span>: <span style={{ color: color.green }}>'atlas'</span>,</>,
      <><span style={{ color: color.blue }}>  title</span>: <span style={{ color: color.green }}>'Your next workspace'</span>,</>,
      <><span style={{ color: color.blue }}>  theme</span>: <span style={{ color: color.green, backgroundColor: find ? alpha(color.amber, 18) : undefined }}>'{saved ? 'system' : 'light'}'</span>,</>,
      <><span style={{ color: color.blue }}>  description</span>: <span style={{ color: color.green }}>'A terminal workspace for all your projects.'</span>,</>,
      <>{'}'};</>,
      <><span style={{ color: color.violet }}>export default</span> project;</>,
    ].filter((_line, index) => !short || index !== 2 && index !== 4).map((line, index) => <div key={index} style={{ display: 'flex', gap: 24, backgroundColor: index === 3 && find ? alpha(color.amber, 7) : 'transparent' }}><span style={{ color: color.faint, flexShrink: 0, width: 25 }}>{index + 1}</span><span style={{ whiteSpace: wrap ? 'pre-wrap' : 'pre', overflowWrap: wrap ? 'anywhere' : undefined }}>{line}</span></div>)}
  </div>
);

const TreeOperations = ({ frame }: { frame: number }) => {
  const created = frame >= 32;
  const renamed = frame >= 74;
  const trashed = frame >= 136;
  const imported = frame >= 204;
  const utility = Math.min(3, Math.floor(frame / 60));
  const utilityActions = [
    ['Open to the Side', 'cd Here'], ['Reveal in Finder', 'Open in Default App'], ['Copy Path', 'Copied'], ['Import Files…', 'Copied into assets'],
  ][utility];
  const label = frame < 32 ? 'New File…' : frame < 74 ? 'Rename' : frame < 116 ? 'New Folder…' : frame < 136 ? 'Move to Trash' : 'Import Files…';
  return (
    <Shell title="atlas — Files" toolbar={<div style={{ display: 'flex', alignItems: 'center', gap: 18 }}><span style={{ fontSize: 24, fontWeight: 650 }}>Files</span><span className="font-mono" style={{ fontSize: 22, color: color.muted }}>~/src/atlas</span><span style={{ marginLeft: 'auto' }}><Action active>{label}</Action></span></div>}>
      <div style={{ display: 'grid', gridTemplateColumns: '430px 1fr', height: '100%' }}>
        <div style={{ padding: 20, borderRight: `1px solid ${color.line}` }}>
          <FileRow name="src" folder />
          <FileRow name="config.ts" indent={30} status="M" />
          {created ? <FileRow name={renamed ? 'welcome.ts' : 'untitled.ts'} indent={30} active={!imported} status="A" /> : null}
          {!trashed ? <FileRow name="obsolete.ts" indent={30} active={frame >= 104} /> : null}
          {frame >= 116 ? <FileRow name="assets" folder active={frame >= 166} /> : null}
          {imported ? <FileRow name="zshell-icon.png" indent={30} active status="A" /> : null}
          <FileRow name="README.md" />
          <FileRow name="package.json" />
          <div style={{ marginTop: 22 }}>{imported ? <Done>Copied into assets</Done> : trashed ? <Done>Moved to Trash</Done> : created ? <Done>{renamed ? 'Renamed · open panes updated' : 'File created'}</Done> : <Badge>New File… / New Folder…</Badge>}</div>
        </div>
        <div style={{ padding: 28, position: 'relative' }}>
          <Panel title={imported ? 'assets/zshell-icon.png' : renamed ? 'src/welcome.ts' : 'src/config.ts'} style={{ height: 318 }}>
            {imported ? <div style={{ display: 'grid', placeItems: 'center', height: 'calc(100% - 49px)', backgroundColor: color.raised }}><Img src={icon} style={{ width: 220, height: 220 }} /></div> : <SourceLines saved={renamed} short />}
          </Panel>
          <div style={{ marginTop: 20, display: 'flex', alignItems: 'center', gap: 18 }}><Action active>{utilityActions[0]}</Action>{utility === 2 ? <Done>Copied</Done> : utility === 3 ? <Badge tone={imported ? 'green' : 'blue'}>{imported ? 'Copied into assets' : '+ Copy'}</Badge> : <Action active={frame % 60 >= 28}>{utilityActions[1]}</Action>}</div>
          <Panel style={{ marginTop: 18, padding: '15px 20px', minHeight: 48 }}>{utility === 0 ? <div className="font-mono" style={{ display: 'flex', gap: 24, fontSize: 22 }}><span style={{ color: color.blue }}>config.ts · new split</span><span>› cd ~/src/atlas/src</span></div> : utility === 1 ? <div style={{ display: 'flex', gap: 24, fontSize: 22 }}><span style={{ color: color.blue }}>Finder · ~/src/atlas/src</span><span>{frame % 60 >= 28 ? 'welcome.ts opened in default app' : 'welcome.ts selected'}</span></div> : utility === 2 ? <div className="font-mono" style={{ fontSize: 22, color: color.blue }}>Clipboard: ~/src/atlas/src/welcome.ts</div> : <div style={{ display: 'flex', alignItems: 'center', gap: 18, fontSize: 22 }}><span>{imported ? 'assets/zshell-icon.png' : 'Finder → assets'}</span><span style={{ color: color.muted }}>原文件保留，复制到项目</span></div>}</Panel>
          {frame >= 186 && frame < 204 ? <Panel title="An item named zshell-icon.png already exists" style={{ position: 'absolute', left: 110, right: 70, top: 235, boxShadow: `0 20px 60px ${alpha(color.shadow, 18)}` }}><div style={{ padding: 24, display: 'flex', gap: 14 }}><Action>Cancel</Action><Action>Skip</Action><Action active={frame >= 195}>Replace</Action></div></Panel> : null}
          {frame >= 166 && !imported ? <Panel style={{ position: 'absolute', left: 390 - ramp(frame, [170, 202], [0, 650]), top: 90 + ramp(frame, [170, 202], [0, 120]), width: 290, padding: 24, boxShadow: `0 18px 40px ${alpha(color.shadow, 17)}` }}><div style={{ color: color.muted, fontSize: 20, marginBottom: 14 }}>Finder</div><div style={{ fontSize: 23 }}>zshell-icon.png</div><div style={{ marginTop: 14 }}><Badge>+ Copy</Badge></div></Panel> : null}
        </div>
      </div>
    </Shell>
  );
};

const FindFiles = ({ frame }: { frame: number }) => {
  const contents = frame >= 118;
  const opened = frame >= 188;
  const query = contents ? 'restoreScrollback' : 'src/config';
  return (
    <Shell title={contents ? 'atlas — Search File Contents' : 'Command Palette — Find Files'} sidebar={<><ListRow active>atlas</ListRow><ListRow>docs-site</ListRow><div style={{ fontSize: 22, color: color.muted, margin: '26px 16px' }}>{contents ? '当前本地项目' : '当前窗口的本地项目'}</div></>}>
      <div style={{ padding: 30 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16, border: `1px solid ${color.blue}`, padding: '16px 20px', borderRadius: 10, fontSize: 24, marginBottom: 26 }}><SearchIcon size={25} color={color.blue} />{query.slice(0, typedLength(query, contents ? frame - 118 : frame, 0, 26))}<span style={{ marginLeft: 'auto', color: color.muted, fontSize: 20 }}>{contents ? 'Aa · Return' : '⌘P'}</span></div>
        <div style={{ display: 'grid', gridTemplateColumns: contents ? '0.9fr 1.1fr' : '1fr', gap: 24 }}>
          <Panel title={contents ? 'Search results' : 'Files across projects'}>
            {contents ? <>
              <ListRow active={opened} trailing={<Badge>43</Badge>}>src/session.ts</ListRow>
              <div className="font-mono" style={{ padding: '8px 24px 22px', fontSize: 22, color: color.muted }}>restoreScrollback();</div>
              <ListRow trailing={<Badge>71</Badge>}>src/reconnect.ts</ListRow>
              <div className="font-mono" style={{ padding: '8px 24px 22px', fontSize: 22, color: color.muted }}>restoreScrollback(state);</div>
              <div style={{ padding: 22 }}><Action>Stop Search</Action></div>
            </> : <>
              <ListRow active={frame >= 42} trailing={<Badge>atlas</Badge>}>src/config.ts</ListRow>
              <ListRow trailing={<Badge tone="violet">docs-site</Badge>}>src/config/navigation.ts</ListRow>
              <ListRow trailing={<Badge>atlas</Badge>}>src/config/theme.ts</ListRow>
              <div style={{ padding: 24, fontSize: 23, color: color.muted }}>按文件名或路径查找，结果标明所属项目</div>
            </>}
          </Panel>
          {contents ? <Panel title="src/session.ts · line 43" style={{ opacity: linear(frame, [178, 192]) }}><Code lines={['function reconnect() {', '  restoreScrollback();', '  attachTerminal();', '}']} /><div style={{ margin: 24 }}><Done>Opened at matching line</Done></div></Panel> : null}
        </div>
        <div style={{ fontSize: 23, color: color.muted, marginTop: 26 }}>{contents ? '内容搜索跳到匹配行，支持区分大小写' : frame >= 68 ? '选择结果，切到对应项目并打开文件' : '无需切换项目，先找到需要的文件'}</div>
      </div>
    </Shell>
  );
};

const ReadAndEdit = ({ frame }: { frame: number }) => {
  const mode = frame < 95 ? 'code' : frame < 166 ? 'markdown' : frame < 203 ? 'image' : 'quickLook';
  const saved = frame >= 54;
  return (
    <Shell title="atlas — Editor" sidebar={<><FileRow name="src" folder /><FileRow name="config.ts" indent={20} active={mode === 'code'} status={saved ? undefined : 'M'} /><FileRow name="README.md" active={mode === 'markdown'} /><FileRow name="zshell-icon.png" active={mode === 'image'} /><FileRow name="diagram.svg" active={mode === 'quickLook'} /></>}>
      <div style={{ padding: '17px 24px', borderBottom: `1px solid ${color.line}`, display: 'flex', alignItems: 'center', gap: 18 }}>
        <span style={{ fontSize: 23 }}>{mode === 'code' ? 'config.ts' : mode === 'markdown' ? 'README.md' : mode === 'image' ? 'zshell-icon.png' : 'diagram.svg'}</span>
        <span style={{ marginLeft: 'auto' }}>{mode === 'code' ? <><Action active={frame >= 36}>Wrap lines</Action><span style={{ marginLeft: 12 }}><Action active={frame >= 42 && frame < 54}>Save ⌘S</Action></span></> : mode === 'markdown' ? <><Action active={frame < 127}>Edit</Action><span style={{ marginLeft: 12 }}><Action active={frame >= 127}>Preview</Action></span></> : mode === 'image' ? <div style={{ display: 'flex', gap: 12 }}><Action active={frame >= 175 && frame < 190}>+ Zoom</Action><Action active={frame >= 190}>Fit to Window</Action><Badge>{frame >= 175 && frame < 190 ? '125%' : 'Fit'}</Badge></div> : <Badge>Quick Look</Badge>}</span>
      </div>
      <div style={{ position: 'relative', height: 'calc(100% - 76px)' }}>
        {mode === 'code' ? <>
          {frame >= 18 ? <div style={{ padding: '12px 28px', borderBottom: `1px solid ${color.line}`, display: 'flex', gap: 16, fontSize: 22 }}><span style={{ color: color.muted }}>Find</span><span style={{ color: color.blue }}>light</span><span style={{ marginLeft: 'auto', color: color.muted }}>1 of 1 · Replace</span></div> : null}
          <SourceLines saved={saved} find={frame >= 18} wrap={frame >= 36} />
          <div style={{ margin: '6px 28px' }}>{saved ? <Done>Saved</Done> : <Badge tone="amber">Unsaved changes</Badge>}</div>
          {frame >= 65 ? <Panel style={{ position: 'absolute', right: 24, top: 74, width: 300, padding: 10, boxShadow: `0 14px 35px ${alpha(color.shadow, 15)}` }}><ListRow active>Open in VS Code</ListRow><ListRow>Open in Zed</ListRow><ListRow>Open in Cursor</ListRow></Panel> : null}
        </> : mode === 'markdown' ? frame < 127 ? <Code lines={['# Atlas workspace', '', 'Keep your terminal, files and diffs together.', '', '![Zshell](./assets/zshell-icon.png)', '', '- Preview local projects', '- Review the changes you made']} /> : <div style={{ padding: 32 }}><div style={{ display: 'flex', gap: 30, alignItems: 'center' }}><Img src={icon} style={{ width: 125, height: 125 }} /><div><div style={{ fontSize: 36, fontWeight: 700, marginBottom: 14 }}>Atlas workspace</div><div style={{ fontSize: 24, color: color.muted }}>Keep your terminal, files and diffs together.</div></div></div><div style={{ marginTop: 34, fontSize: 25, lineHeight: 1.8 }}>• Preview local projects<br />• Review the changes you made</div><div style={{ marginTop: 28 }}><Done>Rendered Markdown · edits preserved</Done></div></div> : mode === 'image' ? <div style={{ height: '100%', display: 'grid', placeItems: 'center', backgroundColor: color.raised }}><Img src={icon} style={{ width: frame >= 175 && frame < 190 ? 412 : 330, height: frame >= 175 && frame < 190 ? 412 : 330 }} /></div> : <div style={{ padding: 34 }}><div style={{ fontSize: 25, color: color.muted, marginBottom: 28 }}>diagram.svg — native Quick Look</div><svg width="100%" height="300" viewBox="0 0 920 300"><path d="M230 150H410M570 150H740" stroke="#98a0b3" strokeWidth="3" />{[['Terminal', 30], ['Workspace', 370], ['Review', 710]].map(([name, x]) => <g key={name}><rect x={Number(x)} y="90" width="180" height="120" rx="18" fill="#eef1f8" stroke="#ced4e3" /><text x={Number(x) + 90} y="160" textAnchor="middle" fill="#12141d" fontSize="27">{name}</text></g>)}</svg><div style={{ fontSize: 23, color: color.muted }}>源码、Markdown、图片与其他预览留在面板</div></div>}
      </div>
    </Shell>
  );
};

const DraftsAndConflicts = ({ frame }: { frame: number }) => {
  const recovery = frame < 52;
  const remote = frame >= 160;
  const reload = frame >= 83 && frame < 108;
  const localSaved = frame >= 144 && frame < 160;
  const remoteCRUD = remote && frame < 186;
  const trashed = frame >= 225 && frame < 233;
  const restored = frame >= 233;
  const done = recovery ? frame >= 30 : remote ? frame >= 218 : reload || localSaved;
  const action = recovery ? 'Restore Draft' : remote ? frame < 168 ? 'New File…' : frame < 176 ? 'Rename' : frame < 186 ? 'Save' : frame < 218 ? 'Overwrite File' : frame < 225 ? 'Save' : frame < 233 ? 'Move to Remote Trash' : 'Restore Last Remote Item' : frame < 74 ? 'Compare…' : frame < 83 ? 'Keep Draft' : frame < 108 ? 'Reload from Disk' : 'Overwrite File';
  return (
    <Shell title={recovery ? 'Recover Drafts' : remote ? 'lab — Remote Editor' : 'atlas — Save Conflict'}>
      <div style={{ display: 'grid', gridTemplateColumns: '0.73fr 1.27fr', gap: 28, padding: 30, height: '100%', boxSizing: 'border-box' }}>
        <div>
          <div style={{ fontSize: 27, fontWeight: 650, marginBottom: 22 }}>{recovery ? 'Recover unsaved drafts' : remote ? 'Remote file changes' : 'Protect against save conflicts'}</div>
          <Panel>
            {recovery ? <><Setting label="Back up unsaved drafts" checked /><ListRow active>src/config.ts</ListRow><ListRow>src/session.ts · worktree diff</ListRow>{frame < 45 ? <ListRow active={frame >= 35}>README.md</ListRow> : null}</> : remote ? <><Setting label="Allow remote file changes" checked /><ListRow>lab · /srv/atlas/src</ListRow><FileRow name="config.ts" status="M" />{frame >= 164 && !trashed ? <FileRow active name={frame < 172 ? 'untitled.ts' : 'settings.ts'} status={frame < 218 ? 'A' : undefined} /> : null}{trashed ? <ListRow>.zshell-trash · settings.ts</ListRow> : null}<div style={{ padding: 16, fontSize: 22, color: color.muted }}>{restored ? 'Original path restored' : trashed ? 'Remote trash keeps recoverable contents' : remoteCRUD ? 'Created → renamed → saved' : 'Remote version changed externally'}</div></> : <><Setting label="Protect against save conflicts" checked /><ListRow active>config.ts · {reload || localSaved ? 'saved' : 'unsaved draft'}</ListRow><ListRow>{reload ? 'Reloaded from disk' : localSaved ? 'Overwrite completed' : 'Disk version updated externally'}</ListRow></>}
          </Panel>
          <div style={{ marginTop: 24 }}><Action active>{recovery && frame >= 35 ? 'Delete Backup' : action}</Action></div>
          <div style={{ marginTop: 26 }}>{done ? <Done>{recovery ? 'Draft restored · unsaved' : remote ? restored ? 'Remote item restored' : trashed ? 'Moved to remote trash' : 'Remote file saved' : reload ? 'Disk version loaded' : 'File overwritten after comparison'}</Done> : <Badge tone="amber">{recovery ? 'Review backup before restoring' : remote ? remoteCRUD ? 'Remote changes allowed' : 'Remote version rechecked' : frame >= 74 && frame < 83 ? 'Draft kept · save cancelled' : 'External change detected'}</Badge>}</div>
          <div style={{ marginTop: 26, fontSize: 23, color: color.muted, lineHeight: 1.6 }}>{recovery ? frame >= 45 ? 'README backup deleted · open edits kept' : '意外退出后恢复编辑，保存前仍检查文件版本' : remote ? '远端编辑、创建、重命名与可恢复删除' : '先比较磁盘版本，再决定如何保存'}</div>
        </div>
        <Panel title={recovery ? done ? 'src/config.ts · restored editor' : 'Draft preview' : remote ? remoteCRUD || frame >= 218 ? 'lab · src/settings.ts' : '“config.ts” changed on the remote host.' : reload || localSaved ? 'config.ts · editor' : '“config.ts” changed on disk.'}>
          {recovery ? <><SourceLines saved /><div style={{ padding: '6px 28px 24px', fontSize: 23, color: color.muted }}>{done ? 'Unsaved draft · disk unchanged' : 'Saved backup · today'}</div></> : remoteCRUD || remote && frame >= 218 ? <><Code lines={['export const settings = {', "  theme: 'system',", '  fontSize: 16,', '};']} /><div style={{ padding: 24 }}>{remoteCRUD ? <Badge>{action}</Badge> : <Done>{restored ? 'Restored to /srv/atlas/src/settings.ts' : trashed ? 'Recoverable in .zshell-trash' : 'Remote contents published'}</Done>}</div></> : reload || localSaved ? <><Code lines={reload ? ['export const theme =', "  'dark';", '', 'export const fontSize = 14;'] : ['export const theme =', "  'system';", '', 'export const fontSize = 16;']} /><div style={{ padding: 24 }}><Done>{reload ? 'Reloaded from Disk' : 'Saved · overwrite approved'}</Done></div></> : <>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', minHeight: 330 }}>
              <div style={{ borderRight: `1px solid ${color.line}` }}><div style={{ padding: '22px 24px', fontSize: 22, color: color.muted }}>{remote ? 'Remote version' : 'On Disk'}</div><Code lines={['export const theme =', "  'dark';", '', 'export const fontSize = 14;']} /></div>
              <div><div style={{ padding: '22px 24px', fontSize: 22, color: color.blue }}>Your Draft</div><Code lines={['export const theme =', "  'system';", '', 'export const fontSize = 16;']} /></div>
            </div>
            <div style={{ padding: 24, borderTop: `1px solid ${color.line}`, display: 'flex', flexWrap: 'wrap', gap: 14 }}><Action active={frame >= 74 && frame < 83}>Keep Draft</Action><Action>{remote ? 'Reload from Remote' : 'Reload from Disk'}</Action><Action active={remote || frame >= 108}>Overwrite File</Action></div>
          </>}
        </Panel>
      </div>
    </Shell>
  );
};

const FilesBody = ({ step, frame, fps }: DemoProps) => {
  const tick = frame * 60 / fps;
  return <div style={{ height: '100%', padding: 24, boxSizing: 'border-box' }}>{step === 0 ? <TreeOperations frame={tick} /> : step === 1 ? <FindFiles frame={tick} /> : step === 2 ? <ReadAndEdit frame={tick} /> : <DraftsAndConflicts frame={tick} />}</div>;
};

export const filesChapter: ChapterSpec = {
  id: 'files', en: 'Read. Edit. Stay in context.', zh: '文件和修改，留在终端旁边',
  steps: [
    { en: 'Manage files in the project tree', zh: '创建、重命名、废纸篓与拖入复制' },
    { en: 'Find the file. Jump to the line.', zh: '跨项目找路径，内容搜索直达匹配行' },
    { en: 'Source and preview, side by side', zh: '代码、Markdown、图片与 Quick Look' },
    { en: 'Keep your drafts safe', zh: '草稿恢复、保存冲突与远端编辑' },
  ],
  features: [
    'Project-rooted file tree; local background refresh and periodic SSH directory refresh',
    'Filename-aware Material file icons; Git status colors and badges; dimmed ignored paths',
    'New File / New Folder / Rename; renaming follows already-open files and folder descendants',
    'Move to Trash; Open / Open to the Side / Copy Path / cd Here / Reveal in Finder / default app',
    'Import Files through menu or Finder drag-and-drop into local tree; copies preserve originals',
    'Import collision Replace / Skip / Cancel with rollback; folder replacement replaces whole folder',
    'Command-palette fuzzy file-name / relative-path search across local projects in the window; project-name context on results',
    'Selecting a search result switches to its project and opens its file',
    'Literal current-local-project file-content search; match case / stop; jumps to the matching editor line',
    'Editable source pane; syntax highlighting / Find / Find and Replace / Save / line wrapping',
    'External editor choices VS Code / Zed / Cursor / System Default',
    'Rendered .md Markdown with Edit / Preview; keeps edits and undo history and remembers preferred mode',
    'Direct local PNG / JPEG / GIF / HEIC / WebP / TIFF / BMP / ICNS previews; native Quick Look for supported other formats',
    'Unsaved-close handling and cancel preserving affected workspace; clean preview refresh without replacing dirty buffer',
    'Unsaved local file and worktree-diff draft backups; unexpected-exit restoration; Recover Drafts / Restore Draft / Delete Backup',
    'Restore Draft opens unsaved source without writing disk; recovery retains pre-edit version for save-conflict checks',
    'Save conflicts: Compare / Keep Draft / Reload from Disk / Overwrite File; protection also covers editable worktree diffs',
    'SSH source editing / saves / create / rename / Move to Remote Trash / Restore Last Remote Item',
    'Allow remote file changes setting; remote-version conflict comparison / Reload from Remote / overwrite version recheck',
  ],
  sources: [
    'web/content/docs/files.mdx', 'mac/zshell/AppKitFileTreePanel.swift', 'mac/zshell/FileTreeModel.swift',
    'mac/zshell/FileTreeImportController.swift', 'mac/zshell/ProjectFileSearch.swift', 'mac/zshell/FileContentSearchModel.swift',
    'mac/zshell/SourceTextEditor.swift', 'mac/zshell/FileViewerView.swift', 'mac/zshell/ExternalEditor.swift',
    'mac/zshell/EditorDraftRecoveryController.swift', 'mac/zshell/FileSaveConflictController.swift',
  ],
  Body: FilesBody,
};
