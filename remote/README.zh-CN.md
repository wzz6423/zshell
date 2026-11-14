# Zshell 共享远程会话

**简体中文** | [English](README.md)

`zshell-server` 在 macOS 或 Linux 主机上管理真实 PTY。Zshell 的 macOS 应用通过 SSH
或 Tailscale 连接；关闭面板、退出应用或连接中断后，远程 shell 及其任务继续运行。
重新连接会恢复终端当前屏幕、备用屏幕、滚动历史、光标和模式。已安装的 macOS 应用
包含中继程序和主机可执行文件，客户端无需安装 Cargo。

## 在主机上安装

在 **Remote Hosts…** 中，通过 SSH 选择 **Install / Update Server**。架构相同的 Mac
使用应用内置的可执行文件；Linux 则需要选择针对其平台和架构构建的主机可执行文件。
安装会验证 SHA-256、平台、架构、版本和协议，再以原子方式替换既有文件。正在运行的
守护进程会继续使用旧文件，直到重启；重启会结束它管理的终端会话。

在 Unix 主机上构建时，安装当前 Rust 工具链并使用本仓库，包括仓库内固定的 Alacritty
终端状态实现：

```sh
cargo build --locked --release --manifest-path remote/Cargo.toml
install -d "$HOME/.local/bin"
install -m 755 remote/target/release/zshell-server "$HOME/.local/bin/zshell-server"
```

以允许客户端访问其 shell 和文件的账户运行服务。服务端无需渲染器或显示服务。
仓库[许可证](../LICENSE.md)也适用于服务端。`zshell-server --licenses` 打印随程序
分发的 Kero 源码署名和 MIT 许可声明。

## 通过 SSH 连接

先确认客户端能够通过普通 SSH 连接，包括主机密钥和密钥或 agent 认证：

```sh
ssh devbox true
```

在 Zshell 侧栏的网络菜单中选择 **Remote Hosts…**，添加名称和 `ssh://me@devbox:22`
（或已有 SSH 别名），保留默认服务端可执行文件路径 `~/.local/bin/zshell-server`。
**Connect Host** 查询真实主机目录并连接已有项目会话。**Open Remote Project** 在
远程目录中创建 shell，支持 `~` 和含空格的路径。在该项目中新建标签页和分屏会创建
更多远程会话。

SSH 执行 `zshell-server bridge`，不分配远程登录 PTY。bridge 在需要时自动启动只允许
该账户访问的守护进程，再通过标准输入输出转发分帧终端协议。OpenSSH 沿用账户已有的
配置、主机密钥检查和 agent；未知主机密钥、缺失密钥或认证失败会显示为连接错误。
主机管理器不收集密码，安装操作还会通过 `zshell-server agent-hooks install` 安装
已有的服务商集成。

文件和 Git 面板复用 Zshell 在同一主机上的 SSH 操作，不会把远程路径解析到 Mac
文件系统。它们的 SSH 认证与直接通过 Tailscale 连接终端相互独立；这些面板中的错误
不会断开终端连接。

需要使用独立 OpenSSH 配置时，在启动 Zshell 前将 `ZSHELL_SSH_CONFIG_FILE` 设为
已存在、可读文件的绝对路径。终端连接和文件/Git 操作都通过 `-F` 将该文件传给
OpenSSH。相对路径、控制字符、目录和不存在的文件会被拒绝。主机密钥检查保持启用；
独立配置可以选择自己的 identity 和 known-hosts 文件，无需修改账户默认 SSH 配置。

## 通过 Tailscale 连接

在两台机器上登录 Tailscale，并在创建会话前为主机守护进程显式启动私有监听：

```sh
zshell-server serve --listen tailscale://:7373
```

在 **Remote Hosts…** 中添加 `tailscale://devbox:7373`。支持 1 到 65535 的自定义
端口、MagicDNS 名称和 Tailscale IPv4/IPv6 地址；客户端拒绝 Tailscale 私有范围外的
地址。服务端只绑定本机当前的 Tailscale 地址，并对每个连接执行
`tailscale whois --json` 检查。默认只允许属于机器所有者同一 Tailscale 登录账户的
未标记设备连接。显式允许其他账户时执行：

```sh
zshell-server serve --listen tailscale://:7373 --allow-user alice@example.com
```

`--allow-user` 可以重复指定，不接受通配账户。带标签的对端，以及缺少用户或设备身份
的对端会被拒绝。带标签的服务端必须显式配置允许登录的账户。Tailnet ACL 仍然生效。
该访问权限允许操作服务端账户，应仅授予有权操作该账户的人。

主机管理器中的 **Share This Mac** 按所选端口和明确允许的用户，启动独立 Tailscale
监听实例。**Stop Sharing** 或退出 Zshell 只结束这个共享实例及其会话。

服务端在 `PATH`、常见 Homebrew 路径、`/usr/bin/tailscale` 和 macOS Tailscale 应用
中查找 CLI。`--tailscale /absolute/path` 可以选择其他 CLI；调用应用内 CLI 时设置
`TAILSCALE_BE_CLI=1`。

客户端和服务端位于同一台机器时，使用 SSH 或本地 CLI。Tailscale whois 识别的是机器
所有者，无法识别本地进程 UID，因此来自服务端自身 Tailscale 地址的直接 TCP 连接会
被拒绝。macOS 和 Linux 上的 Unix socket 对端凭据提供同机账户隔离。Tailscale 项目
的文件和 Git 操作通过 SSH 连接同一主机名，用户和端口取自客户端的 OpenSSH 配置。

## CLI

```sh
zshell-server start
zshell-server status
zshell-server projects
zshell-server create --project ~/repo
zshell-server list --project ~/repo
zshell-server attach --project ~/repo --session UUID
zshell-server terminate --project ~/repo --session UUID
zshell-server processes --project ~/repo --session UUID
zshell-server agent-hooks install
zshell-server --version --json
zshell-server --licenses
```

`create -- /absolute/program args` 使用显式 argv 运行程序，替代登录 shell。
`attach` 用 **Ctrl-]** 分离连接，并保留远程程序的退出状态；由信号退出时状态为
`128 + signal`。CLI 客户端可添加 `--tcp devbox:7373` 使用 Tailscale。每项会话操作
都要求提供规范化的项目目录，其他项目的会话 ID 无法通过该请求连接或终止。

默认守护进程状态目录为 `~/.local/state/zshell-remote`。使用 `--state /absolute/path`
或 `ZSHELL_REMOTE_STATE` 选择其他实例。状态目录必须属于当前账户、权限为 0700，且
不能是符号链接。控制 socket、锁和日志使用 0600 权限，守护进程还会检查 Unix 对端 UID。

## 共享、重连和结束会话

多个客户端可以查看同一个 PTY。首个连接控制输入和终端尺寸；聚焦 Zshell 终端或选择
**Take Terminal Control** 可以取得控制权，CLI 连接则立即取得控制权。其他客户端
仍会收到输出，但只有取得控制权后，键盘输入、终端查询回复和尺寸变化才会传给 PTY。
控制方断开后，最早连接且仍在线的客户端接管，并使用自己的尺寸。

Info 面板和项目侧栏显示实际连接状态；Info 还显示客户端数量、输入及尺寸控制权、
主机、端口和远程目录。**Detach Remote Session** 暂停本地连接，**Reconnect** 恢复
连接。意外断开会通过有上限的指数退避和心跳自动重连。离线时输入的按键会被丢弃，
避免之后在另一个提示符下执行。远程通知包含主机名。

关闭远程面板、项目、窗口或退出 Zshell 只分离该客户端，本地应用中的
**Quit and End All Sessions** 也遵循这一规则。要为所有客户端结束共享会话，选择
**End Remote Session…** 并确认，或使用主机 CLI 的 `terminate`。`stop` 结束该守护
进程中的所有会话。已退出的会话保留最后输出和退出状态，直到显式终止，或新会话需要
腾出会话名额；此时优先释放最早退出且没有客户端查看的会话。保存的布局分别记录远程
会话 UUID 和本地终端 UUID。

服务端最多保留 128 个会话，终端快照上限为 16 MiB，每个客户端的实时队列上限为 1 MiB。
慢客户端会被断开，不会阻塞任务或其他客户端。快照恢复终端状态时不会重放剪贴板写入、
响铃、桌面通知或终端查询。滚动历史保存在主机守护进程内存中，客户端不写入第二份副本。

只要主机守护进程仍然运行，会话就能跨越客户端或 GUI 的退出及网络中断。主机重启、
守护进程崩溃或重启后，会话不保证保留。已保存的会话不可用时会明确报告；需要新建
标签页或远程项目，而不会悄悄替换原任务。

## 文件、截图和代理对话

粘贴已复制的文件或截图时，先上传到主机私有目录，再插入经过 shell 引号转义的远程
路径。共享上传绑定当前控制方的连接和项目，使用有序分块，提交后保留七天。每批最多
32 个普通文件，每个文件最多 32 MiB，整批最多 64 MiB；目录和符号链接会被拒绝。
macOS 和 Linux 上的普通 SSH 面板复用相同的剪贴板捕获与有界 SSH 上传流程。

远程代理状态和进度转发到已有的面板状态、事件流和通知。使用 `agent-hooks install`
安装 Claude Code、Codex、OpenCode 和 Pi 集成。原生 hook 要求可信的本地对端、
进程所有权和会话身份，远程 TCP 客户端不能冒充服务商 hook。程序上报的 OSC 7501
记录仍是优先级较低的状态来源。

中断轮次时，Claude Code 不会发出完成 hook。在忙碌界面按 Esc 或 Ctrl-C 后，守护
进程等待输入界面稳定恢复，再将父轮次切回空闲。新的 hook 或输入会取消这项检查；
活跃子任务和已完成记录保留各自状态。本地应用在两个终端后端中使用同样带保护条件的
检查，也覆盖继承 Ghostty 前台进程组的直接启动路径。使用
`mac/tests/test_native_agent_interrupts.py` 复现本地原生服务商路径；其文件头列出
隔离构建和已安装 CLI 的环境变量。

共享 Codex app-server hook 将已验证的完整对话 ID 绑定到唯一的前台 TUI 标题，也
覆盖在标题输出后才连接的客户端。托管集成添加 Codex 的 `session-id` 标题项，保留
其他标题项；无法唯一确定的身份保持未绑定。

账户私有的 `conversations.json` 在守护进程重启后仍保留最多 200 个服务商对话身份，
文件上限为 2 MiB。应用将各主机的项目历史导入 **Agent Conversation History**。
恢复操作复用正在运行的对话，或在对应主机上用准确的服务商会话 ID、原目录和配置
启动对话，不会把主机路径解析到 Mac，也不会选择最新对话代替目标对话。服务商配置
和 Pi 会话文件必须仍然可用。这份持久化对话历史与实时终端及其内存中的滚动历史独立。

## 作为服务运行

Linux 上保存为 `~/.config/systemd/user/zshell-remote.service`：

```ini
[Unit]
Description=Zshell remote terminal sessions
After=network.target

[Service]
ExecStart=%h/.local/bin/zshell-server serve
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=default.target
```

在 `ExecStart` 中添加 `--listen tailscale://:7373` 和允许登录的账户，以启用 Tailscale。
执行 `systemctl --user daemon-reload` 和
`systemctl --user enable --now zshell-remote`。如果服务需要在最后一个登录退出后继续
运行，请与主机管理员配置 user lingering。

macOS 上保存 LaunchAgent 到 `~/Library/LaunchAgents/sh.zshell.remote.plist`，
将 `/Users/you` 替换为实际账户主目录：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>sh.zshell.remote</string>
  <key>ProgramArguments</key><array>
    <string>/Users/you/.local/bin/zshell-server</string>
    <string>serve</string>
    <string>--state</string><string>/Users/you/.local/state/zshell-remote</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
```

用 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/sh.zshell.remote.plist`
加载。请在创建会话前配置服务；为已运行的守护进程切换监听，需要先结束其会话再重启。

## 验证

```sh
cargo test --locked --manifest-path remote/Cargo.toml
cargo build --locked --manifest-path remote/Cargo.toml
python3 remote/tests/test_cli.py --binary remote/target/debug/zshell-server
python3 remote/tests/test_agents.py --binary remote/target/debug/zshell-server
python3 -B remote/tests/test_tailscale_lookup.py --binary remote/target/debug/zshell-server
```

CLI 探针使用临时状态、真实 PTY 和生产标准输入输出 bridge。隔离的 Linux root
验证使用 `--require-other-uid` 时，还会证明即使 socket 文件系统权限允许连接，其他
UID 仍会被拒绝。Tailscale 查找探针使用私有模拟 CLI 检查五秒截止时间、输出限制和
继承的管道，不会打开网络监听。macOS 应用 surface 探针见
`mac/tests/test_remote_session_surfaces.py`。

### 分叉代理对话

应用历史菜单和 `zshell +agent fork` 使用 `agentFork`，传入远程历史中准确的项目、
服务商和对话 ID。服务端始终创建新 PTY，并调用 `codex fork ID`、
`claude --resume ID --fork-session`、`opencode --session ID --fork` 或
`pi --fork FILE`。源 PTY 和历史记录保留。只有新面板上报不同且经过验证的服务商
身份后，应用才确认成功。原生分叉功能不可用时，更新服务端和服务商 CLI；分叉仍未
确认时，检查服务商输出及 hook 信任条件。
