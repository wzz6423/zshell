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
  video: {
    title: '宣传片',
    musicCredit: { before: '配乐：', after: "。使用 00:00–02:40 片段。" },
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
          { name: '本地与 SSH 项目', detail: "分组管理本地与 SSH 项目，复用密码或私钥认证；支持通过远程目录符号链接打开项目。" },
          { name: '快速启动', detail: '保存、分组常用命令与 SSH 连接，从应用或 zshell 命令行启动到新项目。' },
          { name: '有序的会话', detail: "重命名、标色、固定和分组标签页，在兼容项目或窗口间转移运行中的会话；双击项目侧栏空白处即可创建会话。" },
          { name: '分屏与恢复', detail: "终端与浏览器并排工作，通过窗格标题栏关闭分屏，重启后恢复布局。未保存的编辑会提示保存；滚动输出按历史恢复设置找回。" },
          { name: "持久会话与远程共享", detail: "退出后可继续运行本地任务，通过 SSH 或 Tailscale 共享远端会话并查看进程；配对浏览器，经私有局域网或 Tailscale HTTPS 操作这台 Mac 新建的本地窗格，随时撤销访问。" },
          { name: "工作区模板", detail: "保存、编辑、导入和导出标签页、分屏、启动命令与浏览器地址；应用模板，创建新的本地或已保存远程主机工作区。" },
        ],
      },
      {
        name: '文件与 Git', slug: 'files',
        rows: [
          { name: "项目文件", detail: "浏览后台刷新的本地与 SSH 文件树，导入 Finder 文件和文件夹；新建、重命名、编辑或从远程回收区恢复文件。向远程终端上传文件或剪贴板图片，在本地搜索内容或跨项目查找名称。" },
          { name: "编辑器与 Markdown 预览", detail: "语法高亮编辑、Markdown 预览、本地图片预览（最大 64 MiB）、Quick Look；恢复未保存草稿，比较外部修改后再保存。" },
          { name: 'Git 审阅', detail: "查看单栏或左右 diff，默认自动换行，编辑、暂存、提交和推送；大提交展示前 200 个文件并标明省略数量。" },
          { name: '分支与 Worktree', detail: "新建、切换分支，管理 stash 和独立 worktree 会话；确认后删除未合并的本地分支，自动保留提交恢复引用并暂存本地改动。" },
          { name: "Pull Request 与 Git 代理", detail: "查看 GitHub PR 状态，在 diff 旁阅读、回复及解决或重开讨论，提交评论、批准或请求修改；为 Git 和新建终端配置代理。后台检查时保留当前 PR 状态。" },
          { name: "项目浏览器", detail: "通过 SSH 预览远程 localhost，导入 Chrome 或 Firefox 的 Cookie、历史和标签页，拦截广告与跟踪器；审阅权限后，从文件夹或 ZIP 安装兼容的本地 WebExtensions 扩展。" },
        ],
      },
      {
        name: 'Agent 与自动化', slug: 'automation',
        rows: [
          { name: 'Agent 协作', detail: "让 Agent 跨窗格协调工作，跟进状态与待处理请求，审阅每轮对话的改动；可选择在本地 Agent 工作或 Zshell 运行期间保持 Mac 唤醒。" },
          { name: "Agent 识别规则", detail: "添加、编辑、导入和导出识别规则，独立控制屏幕推断；原生生命周期与程序上报状态优先。" },
          { name: '提示词队列', detail: "为每个会话准备后续提示词，默认手动发送；开启自动发送后，在命令完成且原始 zsh 返回空提示符时依次发送。" },
          { name: '长命令通知', detail: "保留终端与 Agent 通知历史，筛选未读、失败或待处理项目，返回通知来源窗格；程序主动上报时显示进度。" },
          { name: "对话历史与分叉", detail: "搜索、归档、恢复或分叉 Codex、Claude Code、OpenCode 和 Pi 的历史对话，保留原生上下文，支持本地及兼容的远程主机。" },
          { name: "后台任务与浏览器自动化", detail: "等待后台命令结果，订阅工作区实时事件，让 Agent 检查、操作或截图项目浏览器页面，并保存登录状态。" },
        ],
      },
      {
        name: '设置与工具', slug: 'configuration',
        rows: [
          { name: '双终端引擎', detail: "为新窗格选择 Ghostty 或 Alacritty，设置主题、背景、光标、列间距、OpenType 特性、连字、最低对比度和边缘填充配色。" },
          { name: '推荐工具', detail: "在设置中安装、更新或批量管理支持的工具；Quiet.md 提供官方项目与下载入口，用于本地笔记和富文本编辑。" },
          { name: '可迁移的设置', detail: "搜索设置、调整快捷键和界面缩放、导入或导出偏好；分别设置鼠标和触控板滚速、右键操作和启动目录，在 config.toml 配置新 shell 的 TERM。" },
          { name: '由你控制的更新', detail: '选择自动检查与安装偏好；中国大陆优先 Gitee，其他地区优先 GitHub，并提供备用源。Universal 和 Apple Silicon 安装包在 Apple 芯片上原生运行。' },
          { name: "命令历史、补全与键盘提示", detail: "查找命令的耗时、退出状态与原始输出，插入命令后自行执行；Vim 或 Agent 仍运行时退出 Zshell，也保留先前的 shell 滚动输出；支持 zsh 补全与键盘文字提示。" },
          { name: "终端配置与快速终端", detail: "按主机、用户、目录或程序自动应用终端配置；复用快速终端工作区或每次新建，并选择 Dock、菜单栏显示方式。" },
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
        a: "Zshell 没有遥测或分析统计。应用与工具更新检查、下载可能联网；浏览器窗格和命令行工具会发起各自的请求。",
      },
      {
        q: '退出之后我的会话会怎样？',
        a: "重启后会恢复工作区布局。开启会话持久化后，本地 shell 和任务会继续运行；共享远程会话保留在主机上。其他情况下，窗格会恢复已验证的 Agent 对话或新建 shell；开启历史恢复时会找回滚动输出。",
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
