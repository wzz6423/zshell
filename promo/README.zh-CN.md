# Zshell —— 宣传片

**简体中文** | [English](README.md)

**Zshell** 原生 macOS 终端工作空间的产品发布宣传片，时长 2 分 40 秒，以代码编写并渲染
为 MP4，配乐是 Scott Buckley 创作的温暖 synthwave 曲目。

## 技术栈

- [Remotion](https://www.remotion.dev) 4（React 19 + TypeScript）
- 通过 `@remotion/tailwind-v4` 使用 [Tailwind CSS v4](https://tailwindcss.com)
- 通过 [Fontsource](https://fontsource.org) 打包 JetBrains Mono 和 Geist 字体，渲染时
  无需等待字体 CDN

## 开发

在 `promo/` 目录执行以下命令；依赖由 `promo/bun.lock` 锁定。

```sh
bun install --frozen-lockfile
bun run studio     # preview and scrub at http://localhost:3000
bun run typecheck  # tsc --noEmit
bun run render     # out/zshell-launch.mp4, 1920×1080 at 60 fps
bun run render:4k  # out/zshell-launch-4k.mp4, 3840×2160 at 60 fps
```

这些脚本封装了 Remotion CLI，直接执行 `npx remotion studio` 和
`npx remotion render LaunchVideo out/zshell-launch.mp4` 效果相同。4K 文件由同一
合成通过 `--scale=2` 渲染。首次渲染会将 Chrome Headless Shell 下载到
`node_modules/.remotion`。

检查改动时可以只渲染一帧：

```sh
bunx remotion still LaunchVideo out/f1500.png --frame=1500
```

## 官网和 README 中的分发

官网与根目录的中英文 README 共用 `web/public/video/` 中纳入版本控制的
[`zshell-launch-1080p.mp4`](../web/public/video/zshell-launch-1080p.mp4) 和
[`zshell-launch-poster.jpg`](../web/public/video/zshell-launch-poster.jpg)。视频是
1920×1080、60 fps 的 H.264 导出，与 4K 母版使用同一合成和连续配乐，并启用 MP4
faststart。封面取自 4.5 秒处的标题与工作空间展示。

改动合入 `main` 且官网部署成功后，GitHub Pages 会在 `/zshell/video/` 下发布这些文件。

## 时间线

只有一个合成 `LaunchVideo`：60 fps，共 9600 帧。
[`src/timeline.ts`](src/timeline.ts) 定义每个场景的起始帧和长度，各场景从自己的第零帧
开始计数。

| 场景 | 秒数 | 源文件 | 展示内容 |
| --- | --- | --- | --- |
| 1 · 终端苏醒 | 0–5 | [`Awakening.tsx`](src/scenes/Awakening.tsx) | Shell 与 tmux 配置文件堆叠，收缩成一个点，再展开为一个 Zshell 窗口。 |
| 2 · 速度与核心工作流 | 5–15 | [`Workflow.tsx`](src/scenes/Workflow.tsx) | 输入并执行三条自动化命令：返回真实退出状态的后台分屏、启动代理、向代理发送提示。 |
| 3 · 内部机制 | 15–27 | [`UnderTheHood.tsx`](src/scenes/UnderTheHood.tsx) | 窗口倾斜并拆为四层，依次展示架构、两种终端后端、自动化边界和事件流。 |
| 4 · 完整功能介绍 | 27–147 | [`Catalog.tsx`](src/scenes/catalog/Catalog.tsx) | 十个章节展示项目与面板、外观与光标、终端交互、搜索与 Quick Terminal 控制、文件与编辑器、Git 与 PR、浏览器、代理识别与协作、持久会话与会话信息，以及包含 Quiet.md 的偏好设置和工具。 |
| 5 · 功能网格 | 147–154 | [`BentoGrid.tsx`](src/scenes/BentoGrid.tsx) | 展示 Git 暂存、提交与推送，轮次审查、代理状态、worktree 会话、远程会话、全局 Quick Terminal 与配套浏览器访问，并使用中英文标签。 |
| 6 · 结尾与开始使用 | 154–160 | [`Outro.tsx`](src/scenes/Outro.tsx) | 自动输入 Homebrew 安装命令，随后保留 Logo 和仓库地址。 |

## 说明

- 打包的配乐是 [Scott Buckley 的《Electric Dreams》](https://www.scottbuckley.com.au/library/electric-dreams/)
  中连续 160 秒（00:00–02:40）的片段，采用
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 许可。合成在 Studio 播放和
  视频导出时都使用 `public/audio/electric-dreams-tour.mp3`。来源、编辑设置和可复现的
  FFmpeg 命令记录在 [`public/audio/ATTRIBUTION.md`](public/audio/ATTRIBUTION.md)。

  发布视频时，在包括 YouTube 在内的视频简介中保留以下署名：

  > 'Electric Dreams' by Scott Buckley - released under CC-BY 4.0.
  > www.scottbuckley.com.au. https://creativecommons.org/licenses/by/4.0/
  > 00:00–02:40 excerpt. [Attribution and edit details](public/audio/ATTRIBUTION.md).

- 命令、功能名称和设置以应用源码为准。命令、参数、JSON 字段、快捷键、配置键和限制
  取自 [`web/content/docs`](../web/content/docs) 与
  [`mac/zshell/Skills/zshell-automation/SKILL.md`](../mac/zshell/Skills/zshell-automation/SKILL.md)，
  保存在 [`src/data/`](src/data)。产品变化时更新该目录中的数据。
- 场景 1 的 shell 和 tmux 文件、功能介绍界面，以及示例项目、改动和会话，都是对真实
  功能的脚本化演示。每个介绍章节在 `src/scenes/catalog/` 中记录覆盖的功能和所属
  源文件。渲染展示控件和行为，不会执行应用操作。Quick Terminal 和浏览器访问示例
  使用独立会话，浏览器连接到主工作空间中的面板。
- Zshell 没有发布性能基准，场景 3 中的仪表按文档中的自动化限制填充。
- 颜色 token 定义在 [`src/index.css`](src/index.css)，内联样式通过
  [`src/theme.ts`](src/theme.ts) 读取它们。
- 应用图标直接导入自 [`web/public/zshell-icon.png`](../web/public/zshell-icon.png)。
- 背景粒子的上升速度、摆动和柔和衰减参考官网环境粒子场
  （[`web/src/components/site-particles.tsx`](../web/src/components/site-particles.tsx)），
  但使用独立的 CSS 绘制实现，与官网粒子场没有共用代码或纹理。
- 动画只读取当前帧，不使用 `Math.random()`、定时器或 CSS transition。粒子通过
  Remotion 的 `random()` 设置种子，因此帧可以按任意顺序渲染，每次输出都相同。
- `out/` 已被忽略。工作用的渲染产物不提交；`web/public/video/` 中用于官网和 README
  分发的视频与封面纳入版本控制。
- Remotion 采用源码可见（source-available）许可。个人及最多三人的组织可以免费使用；更大的营利团队需要
  [公司许可证](https://www.remotion.dev/docs/license) 才能渲染。
