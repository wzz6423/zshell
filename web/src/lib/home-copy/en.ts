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
          { name: 'Local and SSH projects', detail: 'Group projects, drop folders from Finder, and reuse saved SSH connections with password or private-key authentication.' },
          { name: 'Quick Launch', detail: 'Save and group commands or SSH connections. Open them in a fresh project from the app or the zshell CLI.' },
          { name: 'Sessions that stay organized', detail: 'Rename, color, pin, and group tabs. Move sessions between compatible projects or windows with their running terminals and splits.' },
          { name: 'Split and restore', detail: 'Keep terminals and browser panes side by side. Restore layouts on relaunch; scrollback returns when history restoration is enabled.' },
        ],
      },
      {
        name: 'Files and Git', slug: 'files',
        rows: [
          { name: 'Project search', detail: 'Search file contents in the current local project, or find files by name and path across open local projects.' },
          { name: 'Editor and Markdown preview', detail: 'Edit with syntax highlighting and preview Markdown without switching apps.' },
          { name: 'Git review', detail: 'Inspect unified or split diffs, edit unstaged changes, and stage, commit, or push from the Git panel.' },
          { name: 'Branches and worktrees', detail: 'Create and switch branches, manage stashes, and open an existing worktree in a new terminal tab.' },
        ],
      },
      {
        name: 'Agents and automation', slug: 'automation',
        rows: [
          { name: 'Agent coordination', detail: 'Let coding agents coordinate across panes while you follow status and requests for attention.' },
          { name: 'Usage and limits', detail: 'View available Claude Code and Codex account usage and reset times in Settings when the provider reports them.' },
          { name: 'Prompt queue', detail: 'Queue follow-up prompts per session. Send them manually, or let supported shell integration dispatch them when the shell is ready.' },
          { name: 'Long-command notifications', detail: 'Enable completion or failure notifications for new zsh terminals, and see progress when a program reports it.' },
        ],
      },
      {
        name: 'Settings and tools', slug: 'configuration',
        rows: [
          { name: 'Two terminal engines', detail: 'Choose Ghostty or Alacritty for new panes, with your own shell, fonts, themes, opacity, and blur.' },
          { name: 'Recommended tools', detail: 'Browse development tools and desktop apps in Settings, with supported install, update, and batch actions.' },
          { name: 'Settings that travel', detail: 'Remap shortcuts, adjust interface scale and selection copying, and import or export your settings.' },
          { name: 'Updates you control', detail: 'Choose automatic checks and installation. Updates prefer Gitee in mainland China and GitHub elsewhere, with a fallback source.' },
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
        a: 'Zshell has no telemetry or analytics. App and tool update checks, downloads, and configured agent usage services can access the network; browser panes and command-line tools make their own requests.',
      },
      {
        q: 'What happens to my sessions when I quit?',
        a: 'Projects, tabs, browser URLs, and pane layout come back on relaunch. Each terminal reopens as a fresh shell in its old directory; previous scrollback returns only when history restoration is enabled.',
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
