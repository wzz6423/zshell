---
name: zshell-automation
description: Coordinate coding agents and terminal panes inside Zshell. Use when delegating work to another Zshell pane, starting or prompting a coding agent, coordinating existing Zshell agents, waiting for agent state, or reading a result.
---

# Zshell Automation

Use Zshell's authenticated, project-scoped CLI to coordinate terminal panes and
recognized coding agents. Keep layout creation, agent prompts, and raw terminal
input as separate actions.

## Check availability

1. Require `ZSHELL_AUTOMATION=1`. If it is absent, explain that the command must
   run inside a newly opened Zshell terminal.
2. Run `zshell +pane protocol` before a multi-step workflow.
3. Treat successful command output as JSON. Record returned `pane_id` values;
   do not infer pane IDs from titles or screen position.
4. Stay within the invoking terminal's project. Zshell intentionally rejects
   targets in other projects and windows.

Use `zshell +agent explain` for the lifecycle and security contract, and use
`zshell +agent --help` or `zshell +pane --help` for complete syntax.

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
   project outcome; Zshell does not infer lifecycle from terminal text.
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

   Zshell does not infer progress from terminal text. If no lifecycle integration
   is active, inspect the target pane directly instead of waiting for a guessed
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

Never ask a worker model to report `working`, `blocked`, or `done`. Zshell accepts
semantic state from native CLI lifecycle integrations and never classifies the
rendered terminal screen. `done` is the unseen presentation of integration-
reported idle, not a state the model must announce. For an agent without an
active integration, do not use `agent wait` as proof of progress or completion;
read its pane and verify the project outcome directly.

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
  owns the supported hooks and plugins; other agents have no inferred fallback.
- Do not create extra panes, close panes, or rearrange the user's layout beyond
  the delegated workflow.
- Treat `blocked` as a handoff to the user, not an invitation to bypass the
  blocker.
