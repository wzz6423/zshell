# Zshell

**简体中文** | [English](README.md)

Zshell 是一个面向开发者的原生 macOS 终端工作空间，让 shell、项目、源代码和 AI
编码代理同时推进。它把终端放在主位，同时让文件、diff、仓库状态和项目控制随手可查。

Zshell 需要 macOS 15.6 或更高版本。

## 亮点

- 原生 AppKit 界面，管理项目、标签页和分屏
- 默认使用 libghostty，可选 Alacritty 后端
- 内置浏览器标签页与面板
- 文件树、Git 状态和可编辑的 diff
- 命令面板、项目内文件搜索和本地路径链接
- AI 代理可以派发后台工作并跨 Zshell 面板协作，状态由服务商上报，审批由人掌控

## 开始使用

从 [Zshell 官网](https://wzz6423.github.io/zshell/)下载最新版本，或使用 Homebrew 安装：

```sh
brew install wzz6423/tap/zshell
```

### 从源码运行

需要完整安装 Xcode，以及 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md) 中说明的开发依赖。

```sh
git clone --recurse-submodules https://github.com/wzz6423/zshell.git
cd zshell
cp mac/Config/Local.example.xcconfig mac/Config/Local.xcconfig
# 在 mac/Config/Local.xcconfig 中把 DEVELOPMENT_TEAM 设为你的 Apple Development 证书对应的团队 ID。
make run
```

`make run` 会构建并启动使用独立标识的 Debug 版应用。在分享构建产物或排查签名失败
之前，请先阅读[本地签名说明](CONTRIBUTING.zh-CN.md#本地开发签名)。

## 仓库结构

- [`mac/`](mac/) —— macOS 应用、Xcode 工程、依赖，以及构建和发布脚本。
- [`web/`](web/README.md) —— 官网和用户文档。
- [`skills/`](skills/) —— 面向编码代理的[应用开发](skills/zshell-app-development/SKILL.md)和[发布](skills/zshell-release/SKILL.md)流程。

根目录的 `Makefile` 提供 `run`、`update`、`stop`、`build-package` 和 `clean`。
`mac/` 和 `web/` 需要分别安装 Bun 依赖，两者各有自己的 lockfile。

## 文档

| 文档 | 用途 |
| --- | --- |
| [用户文档](https://wzz6423.github.io/zshell/docs) | 了解应用的工作流和设置。 |
| [贡献指南](CONTRIBUTING.zh-CN.md) | 搭建环境、配置本地签名、构建、验证并提交 Pull Request。 |
| [发布指南](mac/RELEASING.md) | 仅维护者：Developer ID、公证、Sparkle 和 R2 发布流程。 |
| [安全策略](SECURITY.zh-CN.md) | 支持的版本范围和私密漏洞报告方式。 |
| [本地化指南](mac/LOCALIZATION.md) | 翻译并测试应用文案。 |
| [官网指南](web/README.md) | 构建和维护静态站点及其用户文档。 |

## 参与贡献

欢迎提交 Issue 和 Pull Request，请先阅读[贡献指南](CONTRIBUTING.zh-CN.md)。安全漏洞
请通过 [GitHub 安全公告](https://github.com/wzz6423/zshell/security/advisories/new)
私下报告，不要开公开 Issue。

[gitee.com/wzz6423/zshell](https://gitee.com/wzz6423/zshell) 镜像了本仓库的所有分支，
方便在访问 GitHub 较慢的网络下克隆。它只接收已经合入 GitHub 的内容，因此 Issue 和
Pull Request 请在 GitHub 提交。

参与本项目即表示你同意遵守[行为准则](CODE_OF_CONDUCT.zh-CN.md)。

## 许可证

[PolyForm Noncommercial License 1.0.0](LICENSE.md) —— 可免费用于个人、教育、研究
等非商业用途。
