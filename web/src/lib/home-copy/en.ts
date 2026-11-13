import type { HomeCopy } from '../home-copy'

const copy: HomeCopy = {
  languageName: 'English',
  title: 'Zshell — A native terminal workspace for macOS',
  description:
    'A native macOS terminal workspace with local and SSH projects, split panes, Git review, file search, Markdown previews, and coding agent coordination.',
  nav: {
    overview: 'Overview',
    sections: 'Page sections',
    features: 'Features',
    shortcuts: 'Shortcuts',
    faq: 'FAQ',
    docs: 'Docs',
    download: 'Download',
    menuOpen: 'Open menu',
    menuClose: 'Close menu',
  },
  hero: {
    eyebrow: 'Native macOS terminal workspace',
    titleBefore: 'Your terminal.',
    titleHighlight: 'Your whole project.',
    titleAfter: '',
    lede: 'Run your shells and coding agents. Keep local and SSH projects, files, and Git review together in one native macOS workspace.',
    download: 'Download for macOS',
    docs: 'Read the docs',
  },
  video: {
    title: 'Launch film',
    musicCredit: { before: 'Music: ', after: ". 00:00–02:40 excerpt." },
  },
  preview: {
    label: 'Workspace illustration',
    tabs: ['Terminal', 'Code review', 'Agents'],
    captions: ['Local and SSH projects, with room for every session.', 'Inspect the changes beside the shell that made them.', 'Follow agent status and queue the next prompt.'],
    projects: 'Projects', local: 'Local', remote: 'SSH', files: 'Files', changes: 'Changes',
    prompts: ['Review the workspace changes.', 'Check the keyboard shortcuts.', 'Summarize the changes.'],
    agents: 'Agents', running: 'Running', attention: 'Needs attention', queue: 'Prompt queue',
  },
  skipLink: 'Skip to content',
  copy: 'Copy',
  copied: 'Copied',
  copyAria: 'Copy "{command}" to the clipboard',
  features: {
    title: 'Workspace features',
    docsLink: 'Docs',
    groups: [
      {
        name: 'Projects and sessions', slug: 'projects',
        rows: [
          { name: 'Local and SSH projects', detail: "Group local and saved SSH projects with password or key authentication, including remote roots reached through directory symlinks." },
          { name: 'Quick Launch', detail: 'Save and group commands or SSH connections. Open them in a fresh project from the app or the zshell CLI.' },
          { name: 'Sessions that stay organized', detail: "Rename, color, pin and group tabs; move running sessions between compatible projects or windows. Double-click empty project-sidebar space to create a session." },
          { name: 'Split and restore', detail: "Keep terminals and browser panes side by side, close split panes from their headers, and restore layouts on relaunch. Closing asks to save unsaved edits; scrollback follows the history setting." },
          { name: "Persistent and shared sessions", detail: "Keep local jobs running after quitting; share host-owned sessions and inspect their processes over SSH or Tailscale. Pair a browser to operate this Mac’s new local panes over private LAN or Tailscale HTTPS, with revocable access." },
          { name: "Workspace templates", detail: "Save, edit, import and export tabs, splits, startup commands and browser URLs. Apply a template to create fresh local or saved remote-host workspaces." },
        ],
      },
      {
        name: 'Files and Git', slug: 'files',
        rows: [
          { name: "Project files", detail: "Browse refreshed local and SSH trees. Import Finder files and folders; create, rename, edit and recover trashed remote files. Upload files or clipboard images to remote terminals, and search local content or names across open projects." },
          { name: "Editor and Markdown preview", detail: "Syntax highlighting, Markdown preview, local image previews up to 64 MiB, and Quick Look. Recover drafts and compare external edits before saving." },
          { name: 'Git review', detail: "Review unified or split diffs with wrapping enabled by default; edit, stage, commit and push. Large commits show 200 files and count those omitted." },
          { name: 'Branches and worktrees', detail: "Create and switch branches, manage stashes and isolated worktree sessions. Delete unmerged local branches after confirmation, with commit recovery references and stashed local changes." },
          { name: "Pull requests and Git proxy", detail: "See GitHub PR status, read and reply to discussions beside diffs, resolve or reopen threads, and submit comments, approvals or change requests. Configure a proxy for Git and new terminals." },
          { name: "Project browser", detail: "Preview remote localhost through SSH, import Chrome or Firefox cookies, history and tabs, block ads and trackers, and install compatible local WebExtensions from a directory or ZIP after reviewing permissions." },
        ],
      },
      {
        name: 'Agents and automation', slug: 'automation',
        rows: [
          { name: 'Agent coordination', detail: "Coordinate agents across panes, follow status and attention requests, and review each turn’s changes. Optionally keep the Mac awake during local agent work or while Zshell runs." },
          { name: "Agent recognition rules", detail: "Add, edit, import or export recognition rules. Enable screen inference independently while native lifecycle and program reports take priority." },
          { name: 'Prompt queue', detail: "Queue follow-up prompts per session. Send manually by default, or enable automatic sending after a command finishes at an empty prompt in the original zsh shell." },
          { name: 'Long-command notifications', detail: "Keep terminal and Agent notification history, filter unread, failed or pending items, and return to the originating pane. See progress when a program reports it." },
          { name: "Conversation history and forks", detail: "Search, archive, resume or fork saved Codex, Claude Code, OpenCode and Pi conversations with native context, locally or on supported remote hosts." },
          { name: "Background tasks and browser automation", detail: "Wait for background command results, follow live workspace events, and let agents inspect, interact with or capture project browser pages and save logins." },
        ],
      },
      {
        name: 'Settings and tools', slug: 'configuration',
        rows: [
          { name: 'Two terminal engines', detail: "Choose Ghostty or Alacritty for new panes. Set themes, backgrounds, cursors, column spacing, OpenType features, ligatures, minimum contrast and padding colors." },
          { name: 'Recommended tools', detail: "Manage supported tool installations and updates in Settings. Quiet.md offers official project and download links for local notes and rich text editing." },
          { name: 'Settings that travel', detail: "Search settings, remap shortcuts, adjust interface scale and import or export preferences. Set mouse and trackpad speeds separately, right-click actions and starting directories; configure TERM for new shells in config.toml." },
          { name: 'Updates you control', detail: 'Choose automatic checks and installation. Updates prefer Gitee in mainland China and GitHub elsewhere, with a fallback source.' },
          { name: "Command history, completion and hints", detail: "Find commands with duration and exit status; jump to output or insert without running. Keep shell scrollback when quitting Zshell with Vim or an agent open. Use zsh completion and keyboard hints." },
          { name: "Profiles and Quick Terminal", detail: "Apply terminal profiles by host, user, directory or program. Reuse Quick Terminal workspaces or start fresh, and choose Dock or menu bar presence." },
        ],
      },
    ],
  },
  shortcuts: {
    title: 'Keyboard shortcuts',
    docsLink: 'All shortcuts',
    rows: [
      { name: 'Cmd+N', detail: 'new project' },
      { name: 'Cmd+T', detail: 'new session' },
      { name: 'Cmd+W', detail: 'close the focused pane' },
      { name: 'Cmd+1–9', detail: 'switch project' },
      { name: 'Ctrl+1–9', detail: 'switch tab' },
      { name: 'Ctrl+Tab', detail: 'open the tab switcher' },
      { name: 'Cmd+P', detail: 'command palette' },
      { name: 'Cmd+D / Cmd+Shift+D', detail: 'split right / split down' },
      { name: 'Opt+Cmd+arrows', detail: 'focus the pane in that direction' },
      { name: 'Cmd+[ / Cmd+]', detail: 'cycle pane focus' },
      { name: 'Cmd+Shift+Return', detail: 'zoom the focused pane' },
      { name: 'Ctrl+Cmd+arrows / =', detail: 'resize / equalize panes' },
      { name: 'Cmd+B / Cmd+Shift+B', detail: 'toggle the left / right sidebar' },
      { name: 'Cmd+Shift+G / E / I', detail: 'git / files / info panel' },
      { name: 'Cmd+F / Cmd+G', detail: 'find / find next' },
      { name: 'Cmd+K', detail: 'clear the terminal' },
      { name: 'Cmd+S', detail: 'save the open file' },
      { name: 'Cmd+L / Cmd+R', detail: 'focus address bar / reload browser' },
      { name: 'Cmd+Shift+A', detail: 'next agent needing attention' },
    ],
  },
  download: {
    title: 'Download Zshell',
    dmg: 'Download Universal DMG',
    mirror: 'Gitee mirror',
    changelog: 'Changelog',
    license: 'Free, source-available',
  },
  faq: {
    title: 'FAQ',
    items: [
      {
        q: 'Is zshell free?',
        a: 'Yes. Free to download, no subscription, no account.',
      },
      {
        q: 'Does it replace my shell?',
        a: 'No. zshell hosts the shell you already run and leaves your prompt, aliases, and dotfiles untouched. Terminal panes can use Ghostty or Alacritty.',
      },
      {
        q: 'Does it collect any data?',
        a: "Zshell has no telemetry or analytics. App and tool update checks and downloads access the network; browser panes and command-line tools make their own requests.",
      },
      {
        q: 'What happens to my sessions when I quit?',
        a: "Workspace layouts return on relaunch. With session persistence enabled, local shells and jobs keep running; shared remote sessions remain on their host. Otherwise, panes resume verified agent conversations or open fresh shells. Scrollback returns when history restoration is enabled.",
      },
      {
        q: 'Is this an IDE?',
        a: 'No — the terminal stays the center of gravity. The git and files panels exist so you can review and ship what happens in the terminal without switching to an editor.',
      },
    ],
  },
  footerBuiltBy: { before: 'Built by ', after: '' },
  footerDocs: 'Docs',
  footerChangelog: 'Changelog',
}

export default copy
