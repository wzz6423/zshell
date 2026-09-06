import { DEFAULT_LANGUAGE } from '@/lib/i18n'

export type Row = { name: string; detail: string }
export type ProofItem = { title: string; desc: string }
export type FlowStep = { phase: string; title: string; desc: string }
export type FeatureGroup = { name: string; lede: string; rows: Row[] }

export type HomeCopy = {
  /** Display name of this language, for the footer's switcher. */
  languageName: string
  title: string
  description: string
  nav: {
    features: string
    how: string
    shortcuts: string
    faq: string
    docs: string
    download: string
    menuOpen: string
    menuClose: string
  }
  hero: {
    eyebrow: string
    /** The title is one sentence with a highlighted phrase in the middle. */
    titleBefore: string
    titleHighlight: string
    titleAfter: string
    lede: string
    ledeFree: string
    download: string
    docs: string
    hints: [string, string, string]
  }
  copy: string
  copied: string
  copyAria: (command: string) => string
  /** `{count}` in the keyboard entry's title is replaced with the shortcut count. */
  proof: [ProofItem, ProofItem, ProofItem, ProofItem]
  features: {
    eyebrow: string
    titleBefore: string
    titleMuted: string
    lede: string
    groups: FeatureGroup[]
  }
  flow: {
    eyebrow: string
    title: string
    lede: string
    steps: [FlowStep, FlowStep, FlowStep]
  }
  shortcuts: {
    eyebrow: string
    title: string
    lede: string
    docsLink: string
    /**
     * Modifiers are spelled out rather than set as ⌘/⇧/⌥/⌃. Geist Mono ships no
     * subset covering U+2318, U+21E7, U+2325, or U+2303, so those glyphs always
     * fall back to another family mid-word — thinner, differently sized, and off
     * the mono grid — and go missing entirely on most non-Apple systems.
     */
    rows: Row[]
  }
  download: {
    eyebrow: string
    title: string
    /** `{minSystem}` is replaced with the release's minimum macOS version. */
    copy: string
    dmg: string
    mirror: string
    changelog: string
    notes: { version: string; system: string; license: string; licenseValue: string }
  }
  faq: {
    eyebrow: string
    title: string
    lede: string
    items: { q: string; a: string }[]
  }
  /** The author's name is a link, so the credit is split around it. */
  footerBuiltBy: { before: string; after: string }
  footerDocs: string
  footerChangelog: string
  footerTagline: string
}

const en: HomeCopy = {
  languageName: 'English',
  title: 'Zshell — A native terminal workspace for macOS',
  description:
    'Zshell is a fast, keyboard-first terminal workspace for macOS. Projects, sessions, browser panes, git diffs, and coding agents — all in one native window.',
  nav: {
    features: 'Features',
    how: 'How it works',
    shortcuts: 'Shortcuts',
    faq: 'FAQ',
    docs: 'Docs',
    download: 'Download',
    menuOpen: 'Open menu',
    menuClose: 'Close menu',
  },
  hero: {
    eyebrow: 'Native macOS terminal workspace',
    titleBefore: 'Your terminal, with the ',
    titleHighlight: 'whole project',
    titleAfter: ' around it.',
    lede: 'A native macOS workspace built around the terminal — projects, persistent sessions, files, and git in one window.',
    ledeFree: 'Free, no telemetry, no subscription.',
    download: 'Download for macOS',
    docs: 'Read the docs',
    hints: ['Free & source-available', 'Ghostty or Alacritty inside', 'No account, no telemetry'],
  },
  copy: 'Copy',
  copied: 'Copied',
  copyAria: (command) => `Copy "${command}" to the clipboard`,
  proof: [
    {
      title: '100% native',
      desc: 'An AppKit app through and through — fast to launch, quiet on battery, no Electron.',
    },
    {
      title: '2 GPU backends',
      desc: 'New panes run Ghostty or Alacritty, both GPU-accelerated, both with images.',
    },
    {
      title: '0 telemetry',
      desc: 'No analytics, no account, no subscription. The update check is the only call home.',
    },
    {
      title: '{count} shortcuts',
      desc: 'Every action has a key. Switch, split, commit, ship — hands never leave the keyboard.',
    },
  ],
  features: {
    eyebrow: 'Features',
    titleBefore: 'Everything around the shell, ',
    titleMuted: 'nothing in its way.',
    lede: 'The terminal stays the center of gravity; the panels exist so you never have to leave it.',
    groups: [
      {
        name: 'projects & sessions',
        lede: 'Structure for long-running work, not just the last command you ran.',
        rows: [
          {
            name: 'Projects, not windows',
            detail:
              'each repo is a project in the sidebar — Cmd+1–9 switches, Cmd+N adds one',
          },
          {
            name: 'Sessions per project',
            detail:
              'open as many terminal tabs as a project needs with Cmd+T, each with its own directory and scrollback',
          },
          {
            name: 'Split panes',
            detail:
              'Cmd+D splits right, Cmd+Shift+D splits down, Opt+Cmd+arrows moves focus between panes',
          },
          {
            name: 'Browser panes',
            detail:
              'open a site or local server beside its terminal, with native tabs, splits, and restored URLs',
          },
          {
            name: 'Restored on relaunch',
            detail:
              'quit and reopen: projects, tabs, and pane layout come back, each shell fresh beneath its previous scrollback',
          },
          {
            name: 'Command palette',
            detail: 'Cmd+P to jump to any project or session, or run any command',
          },
        ],
      },
      {
        name: 'review & ship',
        lede: 'See what changed and get it committed without leaving the window.',
        rows: [
          {
            name: 'Git panel',
            detail:
              'stage, unstage, discard, and commit — amend included — beside the shell that made the changes',
          },
          {
            name: 'Inline diffs',
            detail:
              'review unified or split diffs in place, and edit live unstaged changes directly',
          },
          {
            name: 'Branch work',
            detail:
              'switch or create a branch, fetch, fast-forward pull, push, publish a new upstream, or stash',
          },
          {
            name: 'Files panel',
            detail:
              'browse the working tree, open a file, edit it with syntax highlighting, Cmd+S to save',
          },
          {
            name: 'Session info',
            detail:
              'the processes running under a session and the TCP ports they are listening on',
          },
        ],
      },
      {
        name: 'the terminal itself',
        lede: 'Your shell, your config, your fonts — hosted, not replaced.',
        rows: [
          {
            name: 'Your shell, unchanged',
            detail:
              'zsh, fish, or bash exactly as you configured it — prompt, aliases, dotfiles and all',
          },
          {
            name: 'Two native backends',
            detail:
              'choose Ghostty or Alacritty for new panes; both are GPU-accelerated and support images',
          },
          {
            name: 'Agent-aware',
            detail:
              'let coding agents delegate work and coordinate across Zshell panes while you follow status, notifications, and approvals',
          },
          {
            name: 'Desktop notifications',
            detail:
              'a bell in an unfocused session, or a notification escape from a long-running command, reaches Notification Center',
          },
          {
            name: 'Progress reports',
            detail:
              'OSC 9;4 progress shows as a slim bar above the terminal, error and pause states included',
          },
          {
            name: 'Fonts',
            detail:
              'ships with JetBrains Mono and Nerd Font symbols; swap in any monospace family and size',
          },
          {
            name: 'Quiet updates',
            detail:
              'new builds check in with Sparkle and install in the background, on their own',
          },
        ],
      },
    ],
  },
  flow: {
    eyebrow: 'How it works',
    title: 'Open. Work. Ship.',
    lede: 'One window for the whole loop, from cloning to pushing.',
    steps: [
      {
        phase: '01 — Open',
        title: 'Add a project',
        desc: 'Cmd+N points Zshell at a repo. It lands in the sidebar, next to everything else you’re juggling.',
      },
      {
        phase: '02 — Work',
        title: 'Split, browse, delegate',
        desc: 'Terminals, browsers, and editors share the window. Coding agents can drive panes while you watch.',
      },
      {
        phase: '03 — Ship',
        title: 'Review and commit',
        desc: 'The git panel sits beside the shell that made the changes. Diff, edit, commit, push — done.',
      },
    ],
  },
  shortcuts: {
    eyebrow: 'Shortcuts',
    title: 'Hands on the keyboard.',
    lede: 'The ones you’ll use every hour. The full list lives in the docs.',
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
    eyebrow: 'Download',
    title: 'Start in one window.',
    copy: 'Free for macOS {minSystem} and later. Install with Homebrew, or download the dmg.',
    dmg: 'Download Universal DMG',
    mirror: 'Gitee mirror',
    changelog: 'Changelog',
    notes: {
      version: 'Latest version',
      system: 'Requires',
      license: 'License',
      licenseValue: 'Free, source-available',
    },
  },
  faq: {
    eyebrow: 'FAQ',
    title: 'Questions, answered.',
    lede: 'The short version: it hosts your shell, it doesn’t replace it.',
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
        a: 'No telemetry, no analytics. Its only automatic network request is the update check; browser pages and agent CLIs make only the requests you ask them to.',
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
  footerTagline: 'A native terminal workspace for macOS.',
}

const zh: HomeCopy = {
  languageName: '中文',
  title: 'Zshell — 原生 macOS 终端工作区',
  description:
    'Zshell 是面向 macOS 的原生终端工作区：快速、键盘优先。项目、会话、浏览器窗格、git diff 和编码 agent，都在同一个窗口里。',
  nav: {
    features: '功能',
    how: '工作方式',
    shortcuts: '快捷键',
    faq: '常见问题',
    docs: '文档',
    download: '下载',
    menuOpen: '打开菜单',
    menuClose: '关闭菜单',
  },
  hero: {
    eyebrow: '原生 macOS 终端工作区',
    titleBefore: '你的终端，',
    titleHighlight: '整个项目',
    titleAfter: '都在身边。',
    lede: '以终端为中心的原生 macOS 工作区——项目、可恢复的会话、文件和 git，都在同一个窗口里。',
    ledeFree: '免费，无遥测，无订阅。',
    download: '下载 macOS 版',
    docs: '阅读文档',
    hints: ['免费、源码公开', '内置 Ghostty / Alacritty', '无需账号，没有遥测'],
  },
  copy: '复制',
  copied: '已复制',
  copyAria: (command) => `将「${command}」复制到剪贴板`,
  proof: [
    {
      title: '100% 原生',
      desc: '彻头彻尾的 AppKit 应用——启动快、省电，没有 Electron。',
    },
    {
      title: '2 个 GPU 后端',
      desc: '新窗格可选 Ghostty 或 Alacritty，都是 GPU 加速，都支持图片。',
    },
    {
      title: '0 遥测',
      desc: '没有分析统计，无需账号和订阅，唯一自动发起的请求是更新检查。',
    },
    {
      title: '{count} 个快捷键',
      desc: '每个操作都有键位。切换、分屏、提交、推送，手不离键盘。',
    },
  ],
  features: {
    eyebrow: '功能',
    titleBefore: '围绕 shell 的一切，',
    titleMuted: '一样不多。',
    lede: '终端始终是核心；这些面板的存在，是为了让你不必离开终端。',
    groups: [
      {
        name: '项目与会话',
        lede: '为长期进行的工作提供结构，而不只是记住上一条命令。',
        rows: [
          {
            name: '按项目组织，而不是窗口',
            detail: '每个仓库对应侧边栏里的一个项目——Cmd+1–9 切换，Cmd+N 新建',
          },
          {
            name: '一个项目，多个会话',
            detail:
              'Cmd+T 想开几个终端标签页就开几个，每个都有自己的工作目录和滚动历史',
          },
          {
            name: '分屏',
            detail: 'Cmd+D 向右分，Cmd+Shift+D 向下分，Opt+Cmd+方向键在窗格间切换焦点',
          },
          {
            name: '浏览器窗格',
            detail: '把网页或本地服务放在终端旁边；支持标签页、分屏和 URL 恢复',
          },
          {
            name: '重启后原样恢复',
            detail:
              '退出再打开，项目、标签页和窗格布局都还在；每个 shell 重新启动，之前的输出留在上方',
          },
          {
            name: '命令面板',
            detail: 'Cmd+P 跳到任意项目或会话，也能直接执行命令',
          },
        ],
      },
      {
        name: '审阅与提交',
        lede: '不用离开窗口，看清改了什么、提交到哪里。',
        rows: [
          {
            name: 'Git 面板',
            detail:
              '暂存、取消暂存、丢弃、提交（含 amend）——就在产生改动的那个 shell 旁边',
          },
          {
            name: '内联 diff',
            detail: '在窗口里看单栏或左右 diff，还能直接编辑实时、未暂存的改动',
          },
          {
            name: '分支操作',
            detail:
              '切换或新建分支，fetch、fast-forward 拉取、推送、发布 upstream，或 stash',
          },
          {
            name: '文件面板',
            detail: '浏览工作区，打开文件编辑；语法高亮，Cmd+S 保存',
          },
          {
            name: '会话信息',
            detail: '当前会话在跑哪些进程，以及它们监听的 TCP 端口',
          },
        ],
      },
      {
        name: '终端本身',
        lede: '你的 shell、配置和字体原封不动——是承载，不是替代。',
        rows: [
          {
            name: '你的 shell，原封不动',
            detail:
              'zsh、fish 还是 bash，你怎么配的就怎么用——提示符、别名、dotfiles 一个不少',
          },
          {
            name: '两个原生后端',
            detail: '新窗格可选 Ghostty 或 Alacritty；两者都有 GPU 加速并支持图片',
          },
          {
            name: '与 AI Agent 协作',
            detail: '让编码 agent 在 Zshell 窗格间分派和协调工作，你通过状态、通知和批准掌握进度',
          },
          {
            name: '桌面通知',
            detail:
              '未聚焦的会话响铃，或跑了很久的命令发来通知，都会出现在系统通知中心',
          },
          {
            name: '进度显示',
            detail:
              '程序上报的 OSC 9;4 进度会变成终端上方的细进度条，错误和暂停也能看出来',
          },
          {
            name: '字体',
            detail: '内置 JetBrains Mono 和 Nerd Font 符号；也可以换成任何等宽字体和字号',
          },
          {
            name: '静默更新',
            detail: '通过 Sparkle 在后台检查并安装新版本，不用你操心',
          },
        ],
      },
    ],
  },
  flow: {
    eyebrow: '工作方式',
    title: '打开。工作。交付。',
    lede: '从克隆到推送，整个闭环都在一个窗口里。',
    steps: [
      {
        phase: '01 — 打开',
        title: '添加项目',
        desc: 'Cmd+N 指向一个仓库，它就出现在侧边栏里，和你手头的其他项目排在一起。',
      },
      {
        phase: '02 — 工作',
        title: '分屏、浏览、派活',
        desc: '终端、浏览器和编辑器同处一个窗口；编码 agent 可以驱动窗格，你看着它干。',
      },
      {
        phase: '03 — 交付',
        title: '审阅并提交',
        desc: 'Git 面板就在产生改动的 shell 旁边。看 diff、改文件、提交、推送，一站完成。',
      },
    ],
  },
  shortcuts: {
    eyebrow: '快捷键',
    title: '手不离键盘。',
    lede: '这些是每小时都会用到的。完整列表在文档里。',
    docsLink: '全部快捷键',
    rows: [
      { name: 'Cmd+N', detail: '新建项目' },
      { name: 'Cmd+T', detail: '新建会话' },
      { name: 'Cmd+W', detail: '关闭当前窗格' },
      { name: 'Cmd+1–9', detail: '切换项目' },
      { name: 'Ctrl+1–9', detail: '切换标签页' },
      { name: 'Ctrl+Tab', detail: '打开标签页切换器' },
      { name: 'Cmd+P', detail: '命令面板' },
      { name: 'Cmd+D / Cmd+Shift+D', detail: '向右分屏 / 向下分屏' },
      { name: 'Opt+Cmd+arrows', detail: '聚焦该方向的窗格' },
      { name: 'Cmd+[ / Cmd+]', detail: '循环切换窗格焦点' },
      { name: 'Cmd+Shift+Return', detail: '放大当前窗格' },
      { name: 'Ctrl+Cmd+arrows / =', detail: '调整窗格大小 / 等分' },
      { name: 'Cmd+B / Cmd+Shift+B', detail: '切换左 / 右侧边栏' },
      { name: 'Cmd+Shift+G / E / I', detail: 'git / 文件 / 信息面板' },
      { name: 'Cmd+F / Cmd+G', detail: '查找 / 查找下一个' },
      { name: 'Cmd+K', detail: '清空终端' },
      { name: 'Cmd+S', detail: '保存当前文件' },
      { name: 'Cmd+L / Cmd+R', detail: '聚焦地址栏 / 重新加载浏览器' },
      { name: 'Cmd+Shift+A', detail: '下一个需要注意的 agent' },
    ],
  },
  download: {
    eyebrow: '下载',
    title: '从一个窗口开始。',
    copy: '免费，需要 macOS {minSystem} 或更高版本。用 Homebrew 安装，或直接下载 dmg。',
    dmg: '下载 Universal DMG',
    mirror: 'Gitee 镜像',
    changelog: '更新日志',
    notes: {
      version: '最新版本',
      system: '系统要求',
      license: '许可',
      licenseValue: '免费、源码公开',
    },
  },
  faq: {
    eyebrow: '常见问题',
    title: '问题与回答。',
    lede: '简单说：它承载你的 shell，而不是取代它。',
    items: [
      {
        q: 'zshell 免费吗？',
        a: '是的。免费下载，无需订阅，也不需要账号。',
      },
      {
        q: '它会替换我的 shell 吗？',
        a: '不会。zshell 运行的就是你本来在用的 shell，提示符、别名和 dotfiles 都不受影响。终端窗格可以使用 Ghostty 或 Alacritty。',
      },
      {
        q: '它会收集数据吗？',
        a: '没有遥测，也没有分析统计。唯一自动发起的是更新检查；浏览器页面和 agent CLI 只会发送你要求的请求。',
      },
      {
        q: '退出之后我的会话会怎样？',
        a: '项目、标签页、浏览器 URL 和窗格布局都会恢复。每个终端在原目录里启动新 shell；只有打开了历史恢复，之前的滚动内容才会回来。',
      },
      {
        q: '这是一个 IDE 吗？',
        a: '不是——终端始终是核心。git 和文件面板是为了让你不用切到编辑器，也能审阅并提交终端里完成的工作。',
      },
    ],
  },
  footerBuiltBy: { before: '由 ', after: ' 打造' },
  footerDocs: '文档',
  footerChangelog: '更新日志',
  footerTagline: '原生 macOS 终端工作区。',
}

const COPY: Record<string, HomeCopy> = { en, zh }

export function homeCopy(lang: string): HomeCopy {
  return COPY[lang] ?? COPY[DEFAULT_LANGUAGE]
}

/** Fills `{token}` placeholders in copy templates (shortcut count, min system). */
export function formatCopy(
  template: string,
  values: Readonly<Record<string, string | number>>,
): string {
  return template.replace(/\{(\w+)\}/g, (match, key: string) =>
    key in values ? String(values[key]) : match,
  )
}
