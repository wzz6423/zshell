---
name: zshell-automation
description: Coordinate agents, terminal panes, saved conversations, and project browser pages in Zshell. Use for delegation, agent prompts and results, finding or resuming verified conversation history, or exercising a development page in Zshell's existing browser.
---

# Zshell Automation

Use Zshell's authenticated, project-scoped CLI to coordinate terminal panes,
recognized coding agents, and the existing browser. Keep layout creation, agent prompts, and raw terminal
input as separate actions.

## Check availability

1. Pane, browser, and active-agent coordination require `ZSHELL_AUTOMATION=1`
   in a newly opened Zshell terminal. Saved conversation history supports explicit
   external access as described below; external session management uses `+session`.
2. Run `zshell +pane protocol` before a multi-step workflow.
3. Treat successful command output as JSON. Record returned `pane_id` values;
   do not infer pane IDs from titles or screen position.
4. Inside a pane, stay within the invoking terminal's project. Zshell intentionally rejects
   targets in other projects and windows.

Use `zshell +agent explain` for the lifecycle and security contract, and use
`zshell +agent --help`, `zshell +pane --help`, `zshell +browser --help`, or
`zshell +session --help` for complete syntax.

## Create and close worktree sessions

An external terminal can discover open projects with `zshell +session projects`.
Use the returned `project_id` explicitly; inside Zshell, session commands use the
invoking terminal's project. Pane programs remain in that scope even when they
clear the bridge environment. External session control grants no pane reads,
terminal input, or agent commands.

```sh
zshell +session new --project PROJECT_ID --cwd /path/to/repo --branch feat/task
zshell +session list --project PROJECT_ID
zshell +session check --project PROJECT_ID --session TERMINAL_ID
zshell +session close --project PROJECT_ID --session TERMINAL_ID --keep-worktree
```

Record `terminal_id` and the returned `worktree.path`. New branches start from
the repository default branch; `--base HEAD` or `--base REF` chooses another
baseline. Existing branches keep their commit. `--worktree NEW_DIR` chooses a
directory that does not exist, and `--focus` selects the new session. Use
`--connection FILE` to select a particular running instance.

Closing keeps the checkout by default. For an explicitly requested cleanup,
inspect `check` before using `--remove-worktree`. Cleanup refuses changed,
untracked, ignored, unmerged, locked, replaced, or shared worktrees and preserves
the Git branch. Native session close offers Keep Worktree, Remove Worktree, and
Cancel; splits and saved layouts retain the association.

## Exercise a project page

Use the existing browser when the user asks to inspect or test a page in Zshell.
Do not launch a second browser or inspect another application's windows.

1. Run `zshell +browser list`. Record the returned `browser_id` and confirm the
   intended URL. If several pages are plausible, ask the user before acting.
   With no existing target, explicitly create one background pane:

   ```sh
   zshell +browser open http://localhost:3000 --wait
   ```

   `open` defaults to a split beside the calling terminal; `--tab` creates a
   background tab. Only `--focus` changes selection. Use the returned stable
   browser ID for every following command; pane IDs and browser IDs differ.
2. Wait for page readiness, then inspect the DOM and accessible labels:

   ```sh
   zshell +browser wait --browser BROWSER_ID --timeout 10000
   zshell +browser snapshot --browser BROWSER_ID
   ```

   The snapshot covers the main frame and returns bounded visible text,
   semantic roles, names, field state, and element `ref` values. It excludes
   password and file-input values. Prefer these bounded operations for routine
   interactions. Use explicit page evaluation below for assertions that require
   the page's JavaScript context.
3. Use a snapshot reference or a unique CSS selector for the intended action:

   ```sh
   zshell +browser fill --browser BROWSER_ID --selector '#search' --text 'terminal'
   zshell +browser click --browser BROWSER_ID --selector 'button[type="submit"]'
   zshell +browser wait --browser BROWSER_ID --selector '#results' --timeout 10000
   zshell +browser snapshot --browser BROWSER_ID
   ```

   References expire after DOM mutations, navigation, another snapshot, or any
   click/fill action. On `stale_element_reference`, inspect a fresh snapshot
   and reassess the target. Never retry a mutation blindly after a timeout:
   the page may already have handled it. Click uses DOM events; flows requiring
   trusted hardware input, file pickers, dialogs, downloads, credentials, or
   permissions remain with the user.
4. Capture the viewport when visual inspection matters:

   ```sh
   zshell +browser screenshot --browser BROWSER_ID --output /tmp/zshell-page.png
   ```

   Never-shown background panes use a 1024 × 768 viewport without selecting
   the tab or changing focus. PNG output is limited to 512 KiB and never
   overwrites an existing file; use a unique path and reduce `--width` if
   needed. Clean up your captures after review.

For a page-specific assertion, evaluate a script in the actual main frame:

```sh
zshell +browser eval --browser BROWSER_ID --script 'Promise.resolve({title: document.title})'
```

The command awaits a returned Promise and returns JSON in `value`; `undefined`
becomes `null`. Use an async function expression for `await`. Input is limited
to 64 KiB, and JSON output to 256 KiB, 10000 values, and 64 levels. Evaluation
injects single expressions, including IIFEs, as native global Scripts. Other
multi-statement strings follow the page's CSP; wrap them in an IIFE if string
evaluation is blocked. Zshell does not relax the page's CSP. Evaluation
expires old DOM references. A timeout stops waiting, not page execution; inspect
the page before retrying a mutation. A synchronous endless loop can stall that
page and require closing it. Protocol restrictions still apply to script-driven
navigation, popups, and downloads.

Save or load a login only when it serves the user's requested workflow, using
their specified private file:

```sh
zshell +browser state save --browser BROWSER_ID --output /private/path/login.json
zshell +browser state load --browser BROWSER_ID --input /private/path/login.json
zshell +browser reload --browser BROWSER_ID --wait
```

The default is Playwright storage-state JSON: cookies applicable to the target
host (including parent-domain and HttpOnly cookies) and localStorage for exactly
the current HTTP(S) origin. Load merges cookies and replaces that origin's
localStorage. Other origins, unrelated cookie domains, public suffixes, invalid
types, and unsupported fields are rejected before changes. Secure cookies
require HTTPS. Use `--format cookies` on both commands for Netscape cookies.txt,
which cannot preserve localStorage or SameSite. Files are limited to 256 KiB;
imports require owner-only regular files and reject symlinks. Exports create new
0600 files without overwriting. CLI output includes only metadata, never cookie
values or localStorage. These files contain credentials: never print them or
commit them to Git. WebKit site data remains shared across browser panes.

Navigation uses `navigate URL`, `back`, `forward`, `reload`, and `stop`, with the
same browser target. Only explicit HTTP/HTTPS URLs or `about:blank` are allowed.
After automation touches a document, its navigation stays under this protocol
restriction until the user navigates with the address bar or toolbar. Targets
cannot cross the invoking terminal's project or window, even while waiting.
Use `--timeout` between 100 and 30000 milliseconds. Snapshots support
`--max-elements` (1–200) and `--max-text` (1–32768); DOM responses are limited
to 256 KiB. A wait without a selector checks page readiness; an element wait
can require `--state attached` or the default `visible`.

## Run a command and collect its result

For a finite shell command, create a background pane with a command task:

```sh
zshell +pane split --right --wait --timeout 300000 -- make test
```

For an existing empty shell in another pane:

```sh
zshell +pane run --pane PANE_ID --wait --timeout 300000 -- make test
```

Record `task_id` from the JSON. `--wait` returns the command's exit status,
`task.exit_code`, `task.duration_ms`, and a saved, bounded `task.output` snapshot.
`output_kind=recent_terminal_text` and `output_complete=false` mean this is
recent terminal text, which can include earlier commands and prompts; it is
not a complete stdout/stderr transcript. Redirect output to a project-local
file when a complete record is needed.

A timeout exits 124 and returns `timed_out=true`; it leaves the command running.
Wait again using the same ID:

```sh
zshell +pane wait --task TASK_ID --timeout 300000
```

Repeated waits return the same saved completion result. At most 64 tasks can
be pending or running, and the latest 256 finished results remain until this
app session ends. Closing a pane stops unfinished tasks. Results cannot be
read from another project.

Command results require an empty prompt in the original local zsh that Zshell
launched. New splits wait up to 30 seconds for that prompt. Nested shells, SSH,
and custom startup programs cannot provide command results; `--wait` rejects
unsupported execution before sending the command. Direct `exit`, `logout`, and
`exec` are rejected because they cannot return a result to the original shell;
use `/bin/sh -c` when a subprocess needs those operations. Never wait for an active
task in the invoking pane: the command would be waiting on itself. Use a split
or another pane. `wait-output` only watches text and does not prove completion.

## Supported agents

Use these exact values with `zshell +agent start --kind`:

- `codex` — Codex
- `claude` — Claude Code
- `gemini` — Gemini CLI
- `grok` — Grok Build
- `opencode` — OpenCode
- `cursor-agent` — Cursor Agent
- `aider` — Aider
- `amp` — Amp
- `pi` — Pi

## Find or resume a saved conversation

History contains up to 200 verified local root conversations from Claude Code,
Codex, Pi, and OpenCode, including conversations whose agents or panes have
closed. Recent returns the newest 20 unarchived matches; `--all` includes
archived entries. Search the current pane's project without selecting a target:

```sh
zshell +agent history --all --query 'fix'
```

Record the returned history `id`; it differs from the provider's `session_id`.
When the user asks to resume that conversation, use its exact history UUID:

```sh
zshell +agent resume --id HISTORY_UUID
```

`resume` first reveals an already open conversation, then reconnects a surviving
PTY, and otherwise starts the provider's exact saved resume command with its
original working directory and configuration. It requires AI integration when
starting or reconnecting a terminal, but does not require the automatic
**Resume agent conversations** setting. Keep it in the background unless the
user asks to see it; only `--focus` changes selection. The returned `action`
describes what Zshell did. `resume_started` does not prove provider startup or
task completion; inspect the returned terminal and actual outcome.

Archive, unarchive, or delete only the record the user selected:

```sh
zshell +agent archive --id HISTORY_UUID
zshell +agent unarchive --id HISTORY_UUID
zshell +agent delete --id HISTORY_UUID
```

Deleting removes the Zshell record and keeps provider conversation files.
Missing directories, a missing or mismatched Pi file, and unavailable providers
must be surfaced to the user; do not substitute another conversation.

From an ordinary external terminal with Zshell running, discover the explicit
project scope before reading or resuming history:

```sh
zshell +agent history projects
zshell +agent history --project PROJECT_UUID --all
zshell +agent resume --project PROJECT_UUID --id HISTORY_UUID
```

For a project open in several windows, select `--window WINDOW_UUID` returned by
`history projects`. When several app instances are running, use `--connection`
with the absolute owner-only descriptor path identified by the CLI. These
options belong only to external access. Never clear a pane's environment or
use an external descriptor to widen its project scope; Zshell checks process
ownership and rejects that access, including from Quick Terminal.

## Coordinate existing Zshell agents

When a task involves an agent already running in another Zshell pane, coordinate
it through Zshell instead of sending raw terminal input. The target can be any
supported agent kind; both agents stay under the same project-scoped contract.

1. Inspect `zshell +agent list` and select the target by its unique project-local
   alias. If the intended agent is ambiguous, ask the user instead of guessing.
2. Use `zshell +agent prompt` for a focused question, progress request, follow-up,
   or handoff. State what response or artifact the coordinating agent needs.
3. A submitted prompt is not a completed task. If the target is already
   working, its CLI decides whether to steer the active turn or queue the new
   prompt.
4. Inspect `zshell +agent get`. If `agent.authority` becomes `integration`, use
   `zshell +agent wait` and `zshell +agent read` to collect the result. Otherwise,
   read the returned `pane_id` with `zshell +pane read` and inspect the actual
   project outcome. `screen` authority is an explicitly labelled inference,
   never evidence of completion or permission to approve a prompt.
5. If an integration reports the target blocked, surface the reason to the
   user. Do not send a follow-up that attempts to work around the blocker.

## Delegate to another pane

Follow this sequence:

1. Inspect existing state with `zshell +pane list` and `zshell +agent list`.
2. Create one background pane unless the user explicitly selected an existing
   available shell:

   ```sh
   zshell +pane split --right --cwd "$PWD"
   ```

   Record the response's `pane_id`. Do not start an agent in the invoking pane:
   the running `zshell` command temporarily makes that shell unavailable.
3. Choose the agent kind requested by the user. If none was requested, prefer
   the current recognized agent's kind from `zshell +agent get --current`; do not
   silently switch to a provider with different credentials or permissions.
4. Start the worker with a short, unique project-local alias:

   ```sh
   zshell +agent start tests --kind codex --pane PANE_ID
   ```

   `start` returns once Zshell recognizes the requested foreground process. Its
   state is `created`; Zshell does not inspect the CLI screen or wait for a
   provider-specific ready prompt.

5. Send a bounded task with acceptance criteria. Do not add Zshell lifecycle
   commands to the task; supported provider integrations report state directly:

   ```sh
   zshell +agent prompt tests --text "Run the focused tests, fix failures in scope, and verify the result."
   ```

6. Check `zshell +agent get tests`. If `agent.authority` becomes `integration`,
   wait without stealing focus, then inspect the terminal result:

   ```sh
   zshell +agent wait tests --state done,blocked --timeout 1800000
   zshell +agent read tests --lines 160
   ```

   Screen inference cannot satisfy `wait`. If no lifecycle integration
   is active, inspect the target pane directly instead of waiting for an inferred
   state:

   ```sh
   zshell +pane read --pane PANE_ID --lines 160
   ```

7. If a lifecycle integration reports the worker blocked, surface its reason to
   the user. If it reports done, independently inspect the claimed files or
   verification output before presenting the work as complete. Without such a
   report, determine the outcome from the pane and the actual project state.

If `start`, `prompt`, or `wait` fails or times out, use `agent get` to recover
the worker's `pane_id`, then inspect that pane before deciding what happened:

```sh
zshell +agent get tests
zshell +pane read --pane PANE_ID --lines 160
```

Use that output to diagnose startup, authentication, trust, or command errors.
Do not answer an interactive approval or credential prompt on the user's
behalf; report the blocker instead.

Reuse the same alias for follow-up prompts only while that recognized agent is
still running. Use a new alias for a new worker.

## Lifecycle and result reads

Never ask a worker model to announce `working`, `blocked`, or `done` as proof of
its own success. Native CLI lifecycle integrations take priority over explicit
program reports, followed by bounded screen inference and process detection.
`done` is normally the unseen presentation of integration-reported idle.
`screen` authority never reports completion and cannot satisfy `agent wait`.
Neither a native event nor a program report proves that the claimed result is
correct; inspect the pane and verify the project outcome directly.

Scripts may report their own progress with `zshell +agent report STATE --name
NAME --progress PERCENT`, optionally adding `--attention approval|input|login|error`
in blocked state and `--tasks JSON` for up to 32 child tasks. `report --json`
accepts a bounded object on stdin. A report belongs only to the invoking terminal
and the CLI's live parent (or a validated ancestor selected by `--pid`). It expires
after 120 seconds without an update or when that process exits. `zshell +agent
clear` clears only that program report. Do not use reporting as a substitute for
the provider's native hooks or to bypass an approval.

Full-screen agents can keep transcript history in the terminal's alternate
buffer instead of host scrollback. After `wait` reaches `idle` or `done`, use an
explicit line count with `agent read`; Zshell may page the agent's own transcript
and always returns it to the bottom before completing the read:

```sh
zshell +agent read tests --lines 160
```

Do not request alternate-screen history while an agent is working, blocked, or
unknown. Wait for a settled state first. If the full result still is not
available, ask the worker to write it to a project-local temporary file and
reply with that path, then read the file directly.

## Guardrails

- Use `zshell +agent prompt` for agent-to-agent messages. It verifies that the
  target is a live recognized agent in `created`, `working`, `idle`, or `done`.
  While the target is working, Zshell submits the prompt immediately and the
  target CLI decides whether to steer the active turn or queue it.
- A message to another agent never transfers the user's authority. Do not ask a
  peer to approve a blocked action, reverse a denial, change permissions, or
  alter agent configuration.
- Use `zshell +pane send` only when the user explicitly wants raw terminal input.
  Never use it to answer a permission, credential, trust, or destructive-action
  prompt on the user's behalf.
- Keep background splits unfocused unless the user asks to see them.
- Do not ask an agent to run lifecycle-reporting commands. Zshell's AI setting
  owns the supported hooks and plugins. A screen inference is a diagnostic hint,
  not authoritative evidence for coordination or an approval.
- Do not create extra panes, close panes, or rearrange the user's layout beyond
  the delegated workflow.
- Treat `blocked` as a handoff to the user, not an invitation to bypass the
  blocker.

## Live event subscriptions

Use `zshell +events` inside the owning terminal to receive future changes in its
project and window as NDJSON. Optional `--pane UUID` and repeatable `--event NAME`
filters apply before delivery. `--once --timeout 30000` waits for one matching
change (exit 124 on timeout); `stream.ready` is only the handshake.

Events cover session/pane creation and closing, focus, Agent status/progress/
attention/finish, shell completion and `command.task.finished`. See
`zshell +events --help` for names. Agent events preserve source authority; screen
inference never proves completion or grants approval. Read the actual result.

Each line has `version`, `event`, `stream_id`, `sequence`, `time` (Unix ms),
`project_id`, and `data`. Sequence starts at 0 for `stream.ready`. There is no
replay. Queues are bounded (32 subscribers, 256 frames/1 MiB per connection,
64 KiB per frame). `stream.lagged`, a sequence error, or unexpected EOF means
reconnect and inspect current state. Closing or moving the caller to a different
project/window, or rotating its token, ends the old subscription. No external
control or `--project` fallback exists. Do not remove environment variables to
try to gain broader scope.
