# 安全策略

**简体中文** | [English](SECURITY.md)

## 支持范围

安全修复优先覆盖最新的 Zshell 发布版本。旧版本不再维护，请通过应用内更新或
[Zshell 官网](https://wzz6423.github.io/zshell/)升级。

| 版本 | 是否支持 |
| --- | --- |
| 最新发布版本 | 是 |
| 旧版本 | 否 |

## 报告漏洞

请不要在公开的 Issue、Pull Request 或 Discussion 中报告安全漏洞。请使用
[GitHub 私密漏洞报告](https://github.com/wzz6423/zshell/security/advisories/new)，
让报告在调查期间保持私密。

请提供受影响的版本或提交、安全影响、复现步骤或概念验证，以及相关的 macOS 与安装
方式信息。请移除真实凭据和个人数据。如果某个凭据可能已经泄露，请立即吊销或轮换。

如果无法使用私密报告，请通过 [@wzz6423](https://github.com/wzz6423) 联系维护者，
不要公开披露敏感细节。

如适用，请附上 **Zshell → 关于 Zshell** 中显示的版本号。

## 影响范围

Zshell 内置 libghostty（vendored 在 `mac/Vendor/libghostty-spm`）来实现终端模拟。
属于本策略范围的是 Zshell 对它的配置和宿主集成：剪贴板访问、跨越信任边界的转义
序列处理、更新链路，以及任何能让终端输出触及会话之外数据的路径。libghostty
上游自身的漏洞也请同时报告给 Ghostty 项目：
https://github.com/ghostty-org/ghostty/security。

## 响应时间

我们的目标是在 7 个自然日内确认收到报告，并在 14 个自然日内给出初步评估或状态
更新。修复或缓解措施就绪后，我们会与报告者协调公开披露的时间。
