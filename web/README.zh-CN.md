# Zshell —— 官网

**简体中文** | [English](README.md)

**Zshell** 原生 macOS 终端工作空间的产品首页和用户文档。

## 技术栈

- [TanStack Start](https://tanstack.com/start)（React 19 + Vite 8）
- [Tailwind CSS v4](https://tailwindcss.com)
- [shadcn/ui](https://ui.shadcn.com)，使用 **Base UI** 基础组件（`@base-ui/react`）
- [Fumadocs](https://fumadocs.dev)，用于 `/docs`
- 预渲染为静态文件，部署到 [GitHub Pages](https://docs.github.com/pages)

## 开发

在 `web/` 目录执行以下命令；依赖由 `web/bun.lock` 锁定。

```sh
bun install --frozen-lockfile
bun run dev        # http://localhost:3000
bun run typecheck  # tsc --noEmit
bun test           # locale routes and complete static copy
```

## 部署到 GitHub Pages

推送到 `main` 后，[`.github/workflows/web-pages.yml`](../.github/workflows/web-pages.yml)
会构建并上传站点，自动完成部署。

站点地址是 **<https://wzz6423.github.io/zshell/>**。Pages 项目站点的路径以仓库名开头，
因此站点生成的每个 URL 都需要这个前缀：[`vite.config.ts`](vite.config.ts) 设置
`base: '/zshell/'`，[`src/router.tsx`](src/router.tsx) 从
`import.meta.env.BASE_URL` 读取同一个值并传给 `basepath`。迁移到其他路径或自定义域名时，
只需修改这一处，并为自定义域名添加记录主机名的 `public/CNAME`，在 *Settings → Pages*
中配置域名。

Vite 会改写它能识别的导入和路由链接。`public/` 文件或手动请求的下述 JSON 端点使用的
字面量路径，需要经过 `withBase()`（[`src/lib/utils.ts`](src/lib/utils.ts)）处理。
否则 URL 会相对于域名根目录解析，返回 404。两个网站工作流都会检查构建后的
`index.html` 是否保留了路径前缀，因为丢失前缀的站点仍能部署，但页面无法正常显示。

路径前缀写在构建文件的内容里：预渲染将 `/docs` 写入 `dist/client/docs/index.html`，
Pages 将整个目录挂载到 `/zshell/`。因此 `dist/client` 按原样上传。

DMG 和 appcast 是 GitHub Release 资源，站点只提供下载链接，见
[`src/lib/release.ts`](src/lib/release.ts)。

[`public/.nojekyll`](public/.nojekyll) 用于保留构建生成的、名称以 `_` 开头的资源文件，
避免 Jekyll 隐藏它们。通过 artifact 部署时不运行 Jekyll；该文件也兼顾其他站点发布方式。

`bun run build` 生成两个目录。`dist/client` 包含每个 URL 对应的静态文件，是 Pages
实际发布的站点；`dist/server` 是预渲染这些文件时使用的构建产物。`bun run preview`
在本地预览构建结果。

站点在请求时不运行服务端代码，新增 URL 需要列入 [`vite.config.ts`](vite.config.ts)
才能生成对应页面。

三组端点返回 JSON，供客户端导航后的页面读取预渲染时计算的数据：`/api/search` 是默认
语言的搜索索引，`/api/search-index/<lang>` 提供其他语言的索引，`/api/release` 是下载
按钮指向的版本，`/api/docs/<lang>` 是该语言的侧栏目录和页面标题。预渲染时直接读取
源码，之后读取生成的静态文件。[`src/lib/docs-loader.ts`](src/lib/docs-loader.ts) 使用
`createIsomorphicFn` 分离两种读取方式，避免把构建时的代码打包进浏览器。

## 语言

简体中文是 `/` 和 `/docs/git` 的默认语言。其他 16 种语言使用规范语言标签，例如
`/ja`、`/pt-BR` 和 `/zh-Hant/docs/git`。[`src/lib/i18n.ts`](src/lib/i18n.ts) 中的语言
列表与应用一致：简体中文、繁体中文、英语、日语、韩语、法语、德语、西班牙语、巴西
葡萄牙语、意大利语、荷兰语、俄语、阿拉伯语、泰语、印尼语、越南语和土耳其语。

内部语言代码 `zh` 用于保留既有的 `.zh.mdx` 文件名和默认 URL。`/zh` 和 `/zh-Hans`
首页仍是 `/` 的别名，canonical 链接指向 `/`，HTML 语言标签和 alternate 链接使用
`zh-Hans`。繁体中文始终使用 `zh-Hant`，不会解析到简体中文。更新日志由根目录的英文
更新日志生成，内容语言标记为英语。

**首页。** 同一个 [`HomePage`](src/components/home-page.tsx) 渲染
[`src/lib/home-copy/`](src/lib/home-copy/) 中的完整静态文案。每种语言都有显式路由和
独立动态加载的翻译包。保留这些显式路由：将首页改为 `/$lang` 可能使 Fumadocs 分支
合并进首页入口。新增语言时，同时添加翻译模块、路由和语言注册表条目。`bun test`
检查所有语言是否包含完整的功能、快捷键、FAQ、导航和预览文案。

**导航。** 共用的原生语言选择器支持窄屏和键盘操作。在文档中切换语言会保留页面 slug
和标题锚点。阿拉伯语将 HTML 和 Fumadocs 设置为从右到左排列；终端输出、命令、键盘
快捷键和代码块仍按从左到右排列。页面标题、描述、canonical URL、Open Graph 元数据
和语言 alternate 链接都跟随所选语言。

**文档。** MDX 位于 [`content/docs`](content/docs)。译文保留英文文件名并添加内部语言
代码，例如 `git.mdx` 对应 `git.ja.mdx`、`git.zh-Hant.mdx` 或 `git.zh.mdx`。侧栏顺序
和分组名称来自 `meta.<lang>.json`，页面标题和描述来自译文的 frontmatter。翻译标题时
保留显式标题 ID，让链接在不同语言间保持有效。缺失的译文回退到英语，同时显示已本地化
的提示，并将内容语言属性标记为英语。导航、目录控件、分页、复制和搜索界面的文案来自
[`src/lib/ui-copy.ts`](src/lib/ui-copy.ts)。

搜索在本地查询所选语言的预渲染索引，打开搜索时只下载对应语言的索引。
[`src/lib/docs-search-index.ts`](src/lib/docs-search-index.ts) 和
[`src/components/docs-search.tsx`](src/components/docs-search.tsx) 共用多语言分词器，
根据所选语言使用对应索引。

文档面向应用用户，开发相关内容见 [CONTRIBUTING.zh-CN.md](../CONTRIBUTING.zh-CN.md)。
所有文档 URL 都会预渲染；[`vite.config.ts`](vite.config.ts) 从文件名生成列表，因此
新增文档页面无需修改配置。

## 说明

- 主题定义在 [`src/styles/app.css`](src/styles/app.css)。文档通过
  `fumadocs-ui/css/shadcn.css` 映射共享配色；首页、文档和更新日志共用黑白配色与 Zisla
  的 `#007aff` 蓝色强调色。覆盖整个视口的同一个粒子背景在所有页面从顶部延伸到底部，
  复用 Zisla 的 Three.js 环境粒子纹理、大小、数量、深度和漂移方式。来源和许可证说明
  随 [`public/zisla-particles-notice.txt`](public/zisla-particles-notice.txt) 分发。
  粒子适配浅色和深色主题，标签页隐藏时暂停，启用减少动态效果时保持静止。
- 主题选择在切换页面和重新加载后保留。单个主题按钮在跟随系统、浅色和深色之间循环。
  语言和主题控件在浅色、深色模式下都使用 12px 圆角。文档侧栏底部将语言、主题和 GitHub
  控件放在同一行，每个控件高 36px。更新日志底部将语言选择器与同一个三态主题按钮
  并排放置，两者同样高 36px。
- 使用 `bunx shadcn@latest add <name>` 添加组件。项目已配置 Base UI，见
  `components.json` 中的 `"style": "base-nova"`。
- 首页在预渲染时通过 [`src/lib/release.ts`](src/lib/release.ts) 读取 Sparkle appcast
  中的最新版本；appcast 位于另一个源且不提供 CORS 响应头，浏览器无法直接读取。
  因此发布新版本后，需要重新构建站点才能更新下载信息。验证两个发布源及其 feed 后，
  验证并直接在 `main` 提交官网版本更新，再推送以触发 Pages 构建。若官网文件没有变更，
  则在已推送的 `main` 上手动触发 `Web Pages`，见
  [RELEASING.md](../mac/RELEASING.md)。保持 `src/lib/release.ts` 中的备用版本信息
  为最新值，构建无法访问 appcast 时会使用它。
- [`public/zshell-icon.png`](public/zshell-icon.png) 是共用的 Logo、favicon 和 Apple
  touch icon。根路由、站点、文档和首页导航都使用它，与 `public/` 中其他文件一样通过
  `withBase()` 生成路径。
- 首页展示带标签的工作空间示意图，包含终端、代码审查和代理视图。示意图使用 CSS 绘制，
  17 种语言的文案和说明都位于 `src/lib/home-copy/`。
- 宣传片嵌入首页末尾、页脚之前。[`src/components/launch-video.tsx`](src/components/launch-video.tsx)
  使用原生视频控件，播放时才加载视频。共用的 1080p MP4 和封面位于 `public/video/`，
  路径通过 `withBase()` 生成。配乐署名链接到 Scott Buckley 的《Electric Dreams》
  及其 CC BY 4.0 许可证。宣传片长 2 分 40 秒，包含十个章节和 40 项功能演示。
- 首页功能分组使用居中的阅读宽度，依次排列。宽屏显示两列，手机显示一列，共用布局
  保证所有支持语言的功能说明完整可见。
