# Ghostty 补丁

**简体中文** | [English](README.md)

本目录统一保存 `libghostty-spm` 构建流程使用的本地 Ghostty 上游补丁。

## 规则

- 保留补丁编号，使应用顺序稳定。
- 上游上下文稳定时，优先使用标准 unified diff（`.patch`）。
- 只有上游上下文不够稳定、无法可靠生成 diff 时，才使用可执行补丁脚本（`.sh`）。
- 特定版本的变体与原补丁放在一起，在 `Script/apply-patches.sh` 中根据上游 API
  标记选择。
- 扩展新版 Ghostty 的 Darwin 静态库构建路径时，保留已更名的内部库输出。
- 本目录中的每个补丁都必须可以安全地重复执行。
- `Script/build-ghostty.sh` 自动应用这里的补丁，macOS、iOS 和 Mac Catalyst
  构建都会使用它们。

## 当前目标

该补丁流程用于为沙盒中的 iOS、macOS 和 Mac Catalyst 集成保留主机管理 I/O 的能力，
将上游改动集中在补丁中维护。

## 输入法组合文本

`0013-shape-preedit-graphemes.patch` 在渲染器管理的字素快照中保留组合重音、emoji
选择符和 ZWJ 序列。预编辑复用终端已有的字形塑形缓存和字形图集，包括彩色 emoji，
不会将尚未提交的文本写入终端单元格。组合文本在右边缘向左移动，只有超过一整行时
才裁去开头的完整字素。

该补丁包含针对 `preedit` 的 Zig 测试。使用已构建的 Zshell Debug 应用时，
`python3 mac/tests/test_terminal_preedit.py --derived-data <path>` 会检查 macOS
上实际呈现的像素、UTF-16 状态、取消组合文本以及 PTY 隔离。
