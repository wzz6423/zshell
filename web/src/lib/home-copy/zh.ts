import type { HomeCopy } from '../home-copy'

const copy: HomeCopy = {
  languageName: '简体中文',
  title: 'Zshell — 原生 macOS 终端工作区',
  description:
    'Zshell 是原生 macOS 终端工作区，集成本地与 SSH 项目、分屏、Git 审阅、文件搜索、Markdown 预览和编码 Agent 协作。',
  nav: {
    overview: '概览',
    sections: '章节导航',
    features: '功能',
    shortcuts: '快捷键',
    faq: '常见问题',
    docs: '文档',
    download: '下载',
    menuOpen: '打开菜单',
    menuClose: '关闭菜单',
  },
  hero: {
    eyebrow: '原生 macOS 终端工作区',
    titleBefore: '终端在中心。',
    titleHighlight: '项目在掌握。',
    titleAfter: '',
    lede: '运行你的 shell 和编码 Agent，把本地与 SSH 项目、文件和 Git 审阅留在同一个原生 macOS 工作区。',
    download: '下载 macOS 版',
    docs: '阅读文档',
  },
  preview: {
    label: '工作区示意',
    tabs: ['终端', '代码审阅', 'Agent 协作'],
    captions: ['本地与 SSH 项目，每个会话各就其位。', '在产生改动的终端旁，审阅每一处变化。', '关注 Agent 状态，为当前会话准备下一条提示。'],
    projects: '项目', local: '本地', remote: 'SSH', files: '文件', changes: '改动',
    prompts: ['审阅工作区改动。', '检查键盘快捷键。', '总结改动。'],
    agents: 'Agent', running: '运行中', attention: '需要关注', queue: '提示词队列',
  },
  skipLink: '跳转到正文',
  copy: '复制',
  copied: '已复制',
  copyAria: '将「{command}」复制到剪贴板',
  features: {
    title: '工作区功能',
    docsLink: '文档',
    groups: [
      {
        name: '项目与会话', slug: 'projects',
        rows: [
          { name: '本地与 SSH 项目', detail: '分组管理项目，拖入 Finder 文件夹；保存 SSH 连接，复用密码或私钥认证。' },
          { name: '快速启动', detail: '保存、分组常用命令与 SSH 连接，从应用或 zshell 命令行启动到新项目。' },
          { name: '有序的会话', detail: '重命名、标色、固定和分组标签页；在兼容项目或窗口间转移会话，保留运行中的终端与分屏。' },
          { name: '分屏与恢复', detail: '终端和浏览器并排工作。重启后恢复布局；开启历史恢复时，也会找回之前的滚动输出。' },
        ],
      },
      {
        name: '文件与 Git', slug: 'files',
        rows: [
          { name: '项目搜索', detail: '在当前本地项目内搜索文件内容，或在打开的本地项目间按名称和路径查找文件。' },
          { name: '编辑器与 Markdown 预览', detail: '通过语法高亮阅读、编辑文件，直接预览 Markdown，无需切换应用。' },
          { name: 'Git 审阅', detail: '查看单栏或左右 diff，编辑未暂存改动，在 Git 面板中暂存、提交与推送。' },
          { name: '分支与 Worktree', detail: '新建、切换分支，管理 stash，把已有的 worktree 打开为新的终端标签页。' },
        ],
      },
      {
        name: 'Agent 与自动化', slug: 'automation',
        rows: [
          { name: 'Agent 协作', detail: '让编码 Agent 在窗格间协调工作，通过状态和待处理提示跟进进展。' },
          { name: '用量与限额', detail: '在设置中查看可用的 Claude Code 与 Codex 账户用量与提供方报告的重置时间。' },
          { name: '提示词队列', detail: '为每个会话排好后续提示词，手动发送，或由受支持的 shell 集成在就绪时依次发送。' },
          { name: '长命令通知', detail: '按需为新建 zsh 终端开启命令完成或失败通知，程序主动上报时显示进度。' },
        ],
      },
      {
        name: '设置与工具', slug: 'configuration',
        rows: [
          { name: '双终端引擎', detail: '新窗格可选 Ghostty 或 Alacritty，自定义 shell、字体、主题、透明度与模糊。' },
          { name: '推荐工具', detail: '在设置中浏览开发工具与桌面应用，使用各工具支持的安装、更新和批量操作。' },
          { name: '可迁移的设置', detail: '重映射快捷键，调整界面缩放与选中复制，导入或导出个人设置。' },
          { name: '由你控制的更新', detail: '选择自动检查与安装偏好；中国大陆优先 Gitee，其他地区优先 GitHub，并提供备用源。' },
        ],
      },
    ],
  },
  shortcuts: {
    title: '常用快捷键',
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
    title: '下载 Zshell',
    dmg: '下载 Universal DMG',
    mirror: 'Gitee 镜像',
    changelog: '更新日志',
    license: '免费、源码公开',
  },
  faq: {
    title: '常见问题',
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
        a: 'Zshell 没有遥测或分析统计。应用与工具更新检查、下载，以及已配置的 Agent 用量服务可能联网；浏览器窗格和命令行工具会发起各自的请求。',
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
}

export default copy
