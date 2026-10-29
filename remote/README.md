# Zshell shared remote sessions

`zshell-server` owns real PTYs on a macOS or Linux host. Zshell's macOS app
attaches over SSH or Tailscale; closing a pane, quitting the app, or losing a
connection leaves the remote shell and its jobs running. Reconnecting restores
the terminal's current screen, alternate screen, scrollback, cursor and modes.
The installed macOS app includes its relay and a host executable; the client
does not need Cargo.

## Install on the host

In **Remote Hosts…**, choose **Install / Update Server** over SSH. A Mac with
the same architecture uses the bundled executable; for Linux, choose a host
executable built for its platform and architecture. Installation verifies
SHA-256, platform, architecture, version and protocol before atomically
replacing the existing executable. An active daemon keeps its old executable
until restarted; restarting ends its terminal sessions.

To build on a Unix host, install a current Rust toolchain and use this repository,
including its vendored Alacritty terminal state implementation:

```sh
cargo build --locked --release --manifest-path remote/Cargo.toml
install -d "$HOME/.local/bin"
install -m 755 remote/target/release/zshell-server "$HOME/.local/bin/zshell-server"
```

Run it as the account whose shell and files clients may access. The server has
no renderer or display-server dependency. The repository's [license](../LICENSE.md)
also applies to the server. `zshell-server --licenses` prints the bundled Kero
source attribution and MIT notice.

## Connect with SSH

First verify ordinary SSH from the client, including the host key and your
key/agent authentication:

```sh
ssh devbox true
```

In Zshell's sidebar network menu choose **Remote Hosts…**, add a name and
`ssh://me@devbox:22` (or an existing SSH alias), and keep the default server
executable `~/.local/bin/zshell-server`. **Connect Host** queries the real host
catalog and attaches its existing project sessions. **Open Remote Project**
creates a shell in the remote directory, including `~` and paths with spaces.
New tabs and splits in that project create more remote sessions.

SSH executes `zshell-server bridge` without a remote login PTY. The bridge
automatically starts the account's owner-only daemon when needed, then forwards
the framed terminal protocol through stdio. OpenSSH retains the account's
existing configuration, host-key checks and agent; unknown host keys, missing
keys or authentication failures are shown as connection errors. The host
manager does not collect passwords. Its installation action also installs the
existing provider integrations with `zshell-server agent-hooks install`.

Files and Git reuse Zshell's existing SSH operations on the same host. They
never resolve a remote path against the Mac's filesystem. Their SSH authentication
is separate from a direct Tailscale terminal connection; an error in these panels
does not disconnect the terminal.

For an advanced setup using a separate OpenSSH configuration, set
`ZSHELL_SSH_CONFIG_FILE` to an existing readable absolute file before launching
Zshell. Both terminal connections and Files/Git pass it to OpenSSH with `-F`.
Relative paths, control characters, directories and missing files are rejected.
Host-key checking remains enabled; the separate file can select its own identity
and known-hosts file without editing the account's default SSH configuration.

## Connect with Tailscale

Sign both machines into Tailscale, and run the host daemon with an explicit
private listener before creating sessions:

```sh
zshell-server serve --listen tailscale://:7373
```

Add `tailscale://devbox:7373` in **Remote Hosts…**. Custom ports from 1 through
65535 are supported. MagicDNS names and Tailscale IPv4/IPv6 addresses work; the
client rejects addresses outside Tailscale's private ranges. The server binds
only its current Tailscale addresses and checks `tailscale whois --json` for
each connection. By default only untagged devices belonging to the machine
owner's exact Tailscale login are allowed. To allow another account explicitly:

```sh
zshell-server serve --listen tailscale://:7373 --allow-user alice@example.com
```

`--allow-user` can be repeated and does not accept wildcard logins. Tagged peers
and peers without a user/device identity are rejected. A tagged server must
use explicit allowed logins. Tailnet ACLs still apply. Keep this account-level
access limited to people who may operate the server's account.

**Share This Mac** in the host manager starts a separate, explicit Tailscale
listener with the selected port and exact allowed users. **Stop Sharing** or
quitting Zshell ends only that sharing instance and its sessions.

The server searches `PATH`, common Homebrew locations, `/usr/bin/tailscale`,
and the macOS Tailscale app. `--tailscale /absolute/path` selects another CLI;
the app CLI is invoked with `TAILSCALE_BE_CLI=1`.

For a client on the server itself, use SSH or the local CLI. Tailscale whois
identifies a machine owner rather than a local process UID, so direct TCP from
the server's own Tailscale address is rejected. Unix-socket peer credentials
provide that same-machine boundary on macOS and Linux. Files and Git on a
Tailscale project use SSH to the same hostname and the user/port in the client's
OpenSSH configuration.

## CLI

```sh
zshell-server start
zshell-server status
zshell-server projects
zshell-server create --project ~/repo
zshell-server list --project ~/repo
zshell-server attach --project ~/repo --session UUID
zshell-server terminate --project ~/repo --session UUID
zshell-server agent-hooks install
zshell-server --version --json
zshell-server --licenses
```

`create -- /absolute/program args` runs explicit argv instead of a login shell.
`attach` uses **Ctrl-]** to detach and preserves the remote program's exit status,
including `128 + signal` for a signal exit. CLI clients can add `--tcp devbox:7373`
to use Tailscale. Every session operation requires its canonical project directory;
an ID from another project cannot be attached or terminated through that request.

The default daemon state is `~/.local/state/zshell-remote`. `--state /absolute/path`
or `ZSHELL_REMOTE_STATE` selects another instance. State directories must be
owned by the account, have mode 0700, and not be symlinks. The control
socket, lock and log use 0600; the daemon also checks the Unix peer's UID.

## Sharing, reconnecting and ending sessions

Multiple clients can view one PTY. The first attachment controls input and
terminal size; focusing a Zshell terminal or choosing **Take Terminal Control**
claims control. CLI attachments claim control immediately. Other clients still
receive output. Their keyboard input, terminal-query replies and resize events
do not reach the PTY until they take control. When the controller disconnects,
the earliest remaining client takes over using its own dimensions.

The Info panel and project sidebar show the actual connection state; Info also
shows client count, ownership of input/size, host, port and remote directory.
**Detach Remote Session** pauses a local connection and **Reconnect** resumes it.
Unexpected disconnections reconnect with bounded exponential backoff and a
heartbeat. Keystrokes typed while offline are discarded, so they cannot execute
later at a different prompt. Remote notifications include the host name.

Closing a remote pane/project/window or quitting Zshell only detaches that
client, including **Quit and End All Sessions** in the local app. To end shared
work for everyone, choose **End Remote Session…** and confirm, or use the host
CLI's `terminate`. `stop` ends all sessions in that daemon. Exited sessions keep
their final output and exit status until explicitly terminated. Saved layouts
remember the remote session UUID separately from the local terminal UUID.

The server retains at most 128 sessions, a 16 MiB terminal snapshot and a 1 MiB
live queue per client. A slow client is disconnected without blocking the job or
other clients. Snapshots restore terminal state without repeating clipboard
writes, bells, desktop notifications or terminal queries. Terminal scrollback is
kept in the host daemon's memory; the client does not write a second scrollback copy.

Persistence covers client/GUI lifetimes and network outages while the host
daemon remains alive. It does not promise survival across host reboots, daemon
crashes or daemon restarts. An unavailable saved session is reported explicitly;
create a new tab or remote project instead of silently replacing its job.

## Files, screenshots and Agent conversations

Pasting copied files or screenshots uploads them to a private host directory
before inserting shell-quoted remote paths. Shared uploads are bound to the
controlling attachment and project, use ordered chunks, and remain available
for seven days after commit. Limits are 32 regular files, 32 MiB per file and
64 MiB per batch; directories and symbolic links are rejected. Ordinary SSH
panes on macOS and Linux reuse the same clipboard capture and bounded SSH
upload path.

Remote Agent state and progress are forwarded to the existing pane status,
event stream and notifications. Install the existing Claude Code, Codex,
OpenCode and Pi integrations with `agent-hooks install`. Native hooks require
trusted local peer/process ownership and the session identity; a remote TCP
client cannot impersonate a provider hook. Program-reported OSC 7501 records
remain a lower-priority status source.

Shared Codex app-server hooks bind verified full conversation IDs to unique
foreground TUI titles, including a client that attaches after the title was
printed. The managed integration adds Codex's `session-id` title item without
replacing other title items; ambiguous identities remain unbound.

The account-private `conversations.json` retains up to 200 provider identities
across daemon restarts, with a 2 MiB file limit. The app imports each host's
project history into **Agent Conversation History**. Resume reuses a live
conversation or launches the exact provider session ID, original directory
and configuration on that host. It never resolves host paths against the Mac
or chooses the latest conversation. Provider configuration and Pi session files
must remain available. This persisted conversation history is independent of
the live terminal and its in-memory scrollback.

## Run as a service

For Linux, save this as `~/.config/systemd/user/zshell-remote.service`:

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

Add `--listen tailscale://:7373` and any allowed logins to `ExecStart` to enable
Tailscale. Run `systemctl --user daemon-reload` and
`systemctl --user enable --now zshell-remote`. If the service must remain alive
after the last login, configure user lingering with your host administrator.

For macOS, save a LaunchAgent in `~/Library/LaunchAgents/sh.zshell.remote.plist`,
replacing `/Users/you` with the account's actual home:

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

Load it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/sh.zshell.remote.plist`.
Configure a service before creating sessions: switching an already running daemon
to a new listener requires ending its sessions and restarting it.

## Verify

```sh
cargo test --locked --manifest-path remote/Cargo.toml
cargo build --locked --manifest-path remote/Cargo.toml
python3 remote/tests/test_cli.py --binary remote/target/debug/zshell-server
python3 remote/tests/test_agents.py --binary remote/target/debug/zshell-server
```

The CLI probe uses temporary state, real PTYs and the production stdio bridge.
An isolated Linux root run with `--require-other-uid` additionally proves rejection
of a different UID even if the socket's filesystem permissions allow connecting.
The macOS app surface probe is documented in `mac/tests/test_remote_session_surfaces.py`.

### Fork an Agent conversation

The app’s history menu and `zshell +agent fork` use `agentFork` with an exact project, provider and conversation ID from remote history. The server always creates a new PTY and invokes `codex fork ID`, `claude --resume ID --fork-session`, `opencode --session ID --fork`, or `pi --fork FILE`. The source PTY and history record are preserved. The app confirms success only after the new pane reports a different, verified provider identity. Update the server and provider CLI when native fork support is unavailable; review provider output and hook trust if the fork remains unconfirmed.
