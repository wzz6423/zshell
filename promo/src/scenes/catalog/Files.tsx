import { Img } from 'remotion';
import icon from '../../../../web/public/zshell-icon.png';
import { FolderIcon, SearchIcon } from '../../components/Icons';
import { linear, ramp } from '../../lib/motion';
import { typedLength } from '../../lib/typing';
import { alpha, color } from '../../theme';
import {
  Action,
  Badge,
  Code,
  Done,
  ListRow,
  Overlay,
  Panel,
  Setting,
  Shell,
  pressAt,
  revealAt,
  type ChapterSpec,
  type DemoProps,
} from './Frame';

const FileRow = ({ name, folder = false, indent = 0, active = false, status }: { name: string; folder?: boolean; indent?: number; active?: boolean; status?: string }) => (
  <ListRow
    active={active}
    indent={indent}
    style={{ padding: '9px 14px', fontSize: 18 }}
    trailing={status ? <span className="font-mono" style={{ fontSize: 16, fontWeight: 600, color: status === 'M' ? color.amber : color.green }}>{status}</span> : undefined}
  >
    {folder ? <FolderIcon size={19} color={color.blue} /> : <span className="font-mono" style={{ fontSize: 14, color: name.endsWith('.ts') ? color.blue : color.muted }}>{name.endsWith('.ts') ? 'TS' : '◇'}</span>}
    {name}
  </ListRow>
);

const SourceLines = ({ saved = false, find = false, wrap = false }: { saved?: boolean; find?: boolean; wrap?: boolean }) => (
  <div className="font-mono" style={{ padding: '16px 20px', fontSize: 19, lineHeight: 1.65 }}>
    {[
      <><span style={{ color: color.violet }}>export const</span> project = {'{'}</>,
      <><span style={{ color: color.blue }}>  name</span>: <span style={{ color: color.green }}>&apos;atlas&apos;</span>,</>,
      <><span style={{ color: color.blue }}>  theme</span>: <span style={{ color: color.green, backgroundColor: find ? alpha(color.amber, 20) : undefined }}>&apos;{saved ? 'system' : 'light'}&apos;</span>,</>,
      <><span style={{ color: color.blue }}>  description</span>: <span style={{ color: color.green }}>&apos;Terminal workspace for active repos.&apos;</span>,</>,
      <>{'}'};</>,
    ].map((line, index) => (
      <div key={index} style={{ display: 'flex', gap: 18, backgroundColor: index === 2 && find ? alpha(color.amber, 8) : 'transparent' }}>
        <span style={{ color: color.faint, flexShrink: 0, width: 22 }}>{index + 1}</span>
        <span style={{ whiteSpace: wrap ? 'pre-wrap' : 'pre', overflowWrap: wrap ? 'anywhere' : undefined }}>{line}</span>
      </div>
    ))}
  </div>
);

const TreeAndSearchStep = ({ frame, fps }: DemoProps) => {
  const renamed = frame >= 48;
  const dragCard = revealAt(frame, fps, 54) * (1 - revealAt(frame, fps, 108));
  const dragProgress = ramp(frame, [58, 98]);
  const collision = revealAt(frame, fps, 94) * (1 - revealAt(frame, fps, 128));
  const imported = revealAt(frame, fps, 124);
  const contentMode = revealAt(frame, fps, 114);
  const openedLine = revealAt(frame, fps, 174);
  const fileQuery = 'src/config'.slice(0, typedLength('src/config', frame, 10, 44));
  const contentQuery = 'restoreScrollback'.slice(0, typedLength('restoreScrollback', frame, 120, 158));

  return (
    <Shell
      title="atlas — Project files & search"
      toolbar={
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <Badge active={contentMode < 0.5}>Cmd+P · Find Files Across Projects</Badge>
          <Badge active={contentMode >= 0.5} tone="violet">Search File Contents · Aa</Badge>
          <span style={{ marginLeft: 'auto', fontSize: 17, color: color.muted }}>
            New File · Rename · Move to Trash · Finder Drag Import · cd Here
          </span>
        </div>
      }
    >
      <div style={{ display: 'grid', gridTemplateColumns: '380px 1fr', height: '100%', position: 'relative' }}>
        <div style={{ padding: 18, borderRight: `1px solid ${color.line}`, display: 'flex', flexDirection: 'column' }}>
          <FileRow name="src" folder />
          <FileRow name="config.ts" indent={22} status="M" />
          <FileRow name={renamed ? 'welcome.ts' : 'untitled.ts'} indent={22} active={imported < 0.3} status="A" />
          <FileRow name="assets" folder active={dragCard > 0.2 || imported > 0.3} />
          <div style={{ maxHeight: `${imported * 44}px`, opacity: imported, overflow: 'hidden' }}>
            <FileRow name="zshell-icon.png" indent={22} active status="A" />
          </div>
          <FileRow name="README.md" />
          <FileRow name="package.json" />
          <div style={{ marginTop: 'auto', display: 'flex', flexDirection: 'column', gap: 8 }}>
            <Done progress={imported} style={{ fontSize: 15 }}>Copied into assets · original kept</Done>
            {imported < 0.4 ? (
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                <Badge active={false} style={{ fontSize: 14, padding: '4px 9px' }}>Open to Side</Badge>
                <Badge active={false} style={{ fontSize: 14, padding: '4px 9px' }}>Reveal</Badge>
                <Badge active={false} style={{ fontSize: 14, padding: '4px 9px' }}>Copy Path</Badge>
              </div>
            ) : null}
          </div>
        </div>

        <div style={{ padding: 24, position: 'relative', display: 'flex', flexDirection: 'column', gap: 18 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, border: `1px solid ${color.blue}`, padding: '13px 18px', borderRadius: 10, fontSize: 21 }}>
            <SearchIcon size={21} color={color.blue} />
            <span className="font-mono">{contentMode >= 0.5 ? contentQuery : fileQuery}</span>
            <span style={{ marginLeft: 'auto', color: color.muted, fontSize: 17 }}>
              {contentMode >= 0.5 ? 'Aa · Match Case' : '⌘P · All local projects'}
            </span>
          </div>

          {contentMode < 0.5 ? (
            <Panel title="Fuzzy file search across projects">
              <ListRow active={frame >= 38} trailing={<Badge style={{ fontSize: 15, padding: '3px 10px' }}>atlas</Badge>}>src/config.ts</ListRow>
              <ListRow trailing={<Badge tone="violet" style={{ fontSize: 15, padding: '3px 10px' }}>docs-site</Badge>}>src/config/navigation.ts</ListRow>
              <ListRow trailing={<Badge style={{ fontSize: 15, padding: '3px 10px' }}>atlas</Badge>}>src/config/theme.ts</ListRow>
              <div style={{ padding: '12px 16px', fontSize: 17, color: color.muted, borderTop: `1px solid ${color.line}` }}>
                Selecting a result switches to its project and opens the file immediately.
              </div>
            </Panel>
          ) : (
            <div style={{ display: 'grid', gridTemplateColumns: '0.92fr 1.08fr', gap: 18, flex: 1, minHeight: 0, opacity: contentMode }}>
              <Panel title="Literal content results · atlas">
                <ListRow active={openedLine > 0.3} trailing={<Badge style={{ fontSize: 15, padding: '3px 9px' }}>:43</Badge>}>src/session.ts</ListRow>
                <div className="font-mono" style={{ padding: '2px 18px 12px', fontSize: 17, color: color.muted }}>restoreScrollback();</div>
                <ListRow trailing={<Badge style={{ fontSize: 15, padding: '3px 9px' }}>:71</Badge>}>src/reconnect.ts</ListRow>
                <div className="font-mono" style={{ padding: '2px 18px 12px', fontSize: 17, color: color.muted }}>restoreScrollback(state);</div>
              </Panel>
              <Panel title="src/session.ts · line 43" style={{ opacity: openedLine, transform: `translateY(${(1 - openedLine) * 10}px)` }}>
                <Code lines={['function reconnect() {', '  restoreScrollback();', '  attachTerminal();', '}']} style={{ fontSize: 18 }} />
                <div style={{ padding: '0 18px 16px' }}><Done progress={openedLine}>Jumped directly to matching line</Done></div>
              </Panel>
            </div>
          )}

          <Overlay progress={collision} style={{ position: 'absolute', left: 24, right: 24, bottom: 24, zIndex: 6 }}>
            <Panel title="zshell-icon.png already exists in assets" style={{ boxShadow: `0 22px 54px ${alpha(color.shadow, 22)}` }}>
              <div style={{ padding: 16, display: 'flex', alignItems: 'center', gap: 12 }}>
                <Action style={{ fontSize: 16, padding: '7px 14px' }}>Cancel</Action>
                <Action style={{ fontSize: 16, padding: '7px 14px' }}>Skip</Action>
                <Action active press={pressAt(frame, 114)} style={{ fontSize: 16, padding: '7px 14px' }}>Replace</Action>
                <span style={{ marginLeft: 'auto', fontSize: 16, color: color.muted }}>Rollback protects untouched files</span>
              </div>
            </Panel>
          </Overlay>
        </div>

        <Overlay
          progress={dragCard}
          style={{
            position: 'absolute',
            left: 560 - dragProgress * 370,
            top: 152 + dragProgress * 22,
            width: 246,
            zIndex: 7,
          }}
        >
          <Panel style={{ padding: 14, boxShadow: `0 20px 44px ${alpha(color.shadow, 20)}` }}>
            <div style={{ fontSize: 14, color: color.muted, marginBottom: 4 }}>Finder drag import</div>
            <div style={{ fontSize: 18, fontWeight: 600 }}>zshell-icon.png</div>
            <div style={{ marginTop: 8 }}><Badge style={{ fontSize: 14, padding: '3px 9px' }}>+ Copy</Badge></div>
          </Panel>
        </Overlay>
      </div>
    </Shell>
  );
};

const PreviewAndProtectionStep = ({ frame, fps }: DemoProps) => {
  const mode = frame < 82 ? 'code' : frame < 154 ? 'markdown' : 'image';
  const saved = frame >= 52;
  const savePress = pressAt(frame, 48);
  const conflictResolved = revealAt(frame, fps, 140);
  const remoteRestored = revealAt(frame, fps, 182);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.08fr 0.92fr', gap: 24, height: '100%' }}>
      <Shell
        title="atlas — Editor & Previews"
        toolbar={
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Badge active={mode === 'code'}>config.ts</Badge>
            <Badge active={mode === 'markdown'} tone="violet">README.md · Preview</Badge>
            <Badge active={mode === 'image'} tone="cyan">Image ≤ 64 MiB · Quick Look</Badge>
            <span style={{ marginLeft: 'auto' }}>
              <Action active={mode === 'code' && !saved} press={savePress} style={{ padding: '6px 13px', fontSize: 16 }}>
                {mode === 'code' ? 'Save ⌘S' : mode === 'markdown' ? 'Edit / Preview' : 'Fit to Window'}
              </Action>
            </span>
          </div>
        }
      >
        <div style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
          {mode === 'code' ? (
            <>
              <div style={{ padding: '10px 20px', borderBottom: `1px solid ${color.line}`, display: 'flex', alignItems: 'center', gap: 14, fontSize: 17 }}>
                <span style={{ color: color.muted }}>Find</span>
                <span className="font-mono" style={{ color: color.blue }}>light</span>
                <span style={{ color: color.muted }}>→ Replace:</span>
                <span className="font-mono" style={{ color: color.green }}>system</span>
                <Badge style={{ marginLeft: 'auto', fontSize: 15, padding: '3px 10px' }}>Wrap · VS Code / Zed / Cursor</Badge>
              </div>
              <SourceLines saved={saved} find wrap />
              <div style={{ padding: '6px 20px' }}>
                {saved ? <Done progress={revealAt(frame, fps, 52)}>Saved · syntax highlight &amp; wrap preserved</Done> : <Badge tone="amber">Unsaved draft backed up automatically</Badge>}
              </div>
            </>
          ) : mode === 'markdown' ? (
            <div style={{ padding: 28, opacity: linear(frame, [82, 96]) }}>
              <div style={{ display: 'flex', gap: 22, alignItems: 'center' }}>
                <Img src={icon} style={{ width: 92, height: 92 }} />
                <div>
                  <div style={{ fontSize: 32, fontWeight: 700, marginBottom: 6 }}>Atlas workspace</div>
                  <div style={{ fontSize: 20, color: color.muted }}>Keep your terminal, files and diffs together.</div>
                </div>
              </div>
              <div style={{ marginTop: 24, fontSize: 20, lineHeight: 1.85 }}>
                • Rendered Markdown preserves edits &amp; undo history<br />
                • Remembers your preferred Edit or Preview mode
              </div>
              <div style={{ marginTop: 20 }}><Done>Markdown Preview · edits preserved</Done></div>
            </div>
          ) : (
            <div style={{ height: '100%', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 18, backgroundColor: alpha(color.raised, 55), opacity: linear(frame, [154, 168]) }}>
              <Img src={icon} style={{ width: 210, height: 210, transform: `scale(${0.92 + 0.08 * ramp(frame, [154, 184])})` }} />
              <Badge tone="cyan">Direct PNG/JPEG/HEIC/WebP ≤ 64 MiB · Native Quick Look for other formats</Badge>
            </div>
          )}
        </div>
      </Shell>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 20, height: '100%' }}>
        <Shell title="Draft Recovery & Save Conflict Guard" style={{ flex: 1 }}>
          <div style={{ padding: 18 }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 14 }}>
              <Panel title="On Disk (external edit)">
                <Code lines={["theme: 'dark',", 'fontSize: 14']} style={{ fontSize: 16, padding: '10px 14px' }} />
              </Panel>
              <Panel title="Your Draft (backed up)">
                <Code lines={["theme: 'system',", 'fontSize: 16']} style={{ fontSize: 16, padding: '10px 14px' }} />
              </Panel>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <Action style={{ fontSize: 15, padding: '6px 12px' }}>Keep Draft</Action>
              <Action style={{ fontSize: 15, padding: '6px 12px' }}>Reload from Disk</Action>
              <Action active press={pressAt(frame, 134)} style={{ fontSize: 15, padding: '6px 12px' }}>Overwrite File</Action>
              <Done progress={conflictResolved} style={{ marginLeft: 'auto', fontSize: 14 }}>Verified</Done>
            </div>
          </div>
        </Shell>

        <Shell title="lab — SSH Remote Editor" style={{ height: 220, flexShrink: 0 }}>
          <div style={{ padding: 16 }}>
            <Setting label="Allow remote file changes" checked={1} />
            <div style={{ padding: '12px 14px 0', display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
              <Badge active={false}>Create · Rename · Save</Badge>
              <Badge tone="violet">.zshell-trash recoverable</Badge>
              <Done progress={remoteRestored} style={{ marginLeft: 'auto', fontSize: 15 }}>Restored Last Remote Item</Done>
            </div>
          </div>
        </Shell>
      </div>
    </div>
  );
};

const FilesBody = (props: DemoProps) =>
  props.step === 0 ? <TreeAndSearchStep {...props} /> : <PreviewAndProtectionStep {...props} />;

export const filesChapter: ChapterSpec = {
  id: 'files',
  en: 'Files & editor',
  zh: '文件树、搜索与编辑',
  nav: '文件与编辑',
  steps: [
    { en: 'Project file tree, Finder import & fast search', zh: '文件树操作、拖入复制与跨项目内容搜索' },
    { en: 'Code, Markdown, images, drafts & SSH editing', zh: '源码、Markdown、图片预览与草稿冲突保护' },
  ],
  features: [
    'Project-rooted local and SSH file tree with Material icons, Git status colors and dimmed ignored paths',
    'New File, New Folder, Rename following open panes, Move to Trash, Finder drag-and-drop import with Replace/Skip/Cancel rollback',
    'Cross-project fuzzy file search (Cmd+P) and current-project literal content search jumping to matching line',
    'Syntax-highlighted source editor, Find and Replace, line wrapping, external editors (VS Code/Zed/Cursor)',
    'Rendered Markdown Edit/Preview, direct local image preview up to 64 MiB and native Quick Look',
    'Unsaved draft backups (Recover Drafts), external save-conflict comparison and SSH remote editing with .zshell-trash recovery',
  ],
  sources: [
    'web/content/docs/files.mdx',
    'mac/zshell/AppKitFileTreePanel.swift',
    'mac/zshell/FileTreeImportController.swift',
    'mac/zshell/ProjectFileSearch.swift',
    'mac/zshell/FileContentSearchModel.swift',
    'mac/zshell/SourceTextEditor.swift',
    'mac/zshell/FileViewerView.swift',
    'mac/zshell/EditorDraftRecoveryController.swift',
    'mac/zshell/FileSaveConflictController.swift',
    'mac/zshell/RemoteFileService.swift',
  ],
  Body: FilesBody,
};
