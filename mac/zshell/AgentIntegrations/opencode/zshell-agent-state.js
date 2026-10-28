// Managed by Zshell. Re-enabling AI replaces this integration.
// ZSHELL_INTEGRATION_ID=opencode
// ZSHELL_INTEGRATION_VERSION=1

import net from "node:net";
import { spawn } from "node:child_process";
function remoteRequest(method, params) {
  if (!process.env.ZSHELL_REMOTE_STATE || !process.env.ZSHELL_EXECUTABLE) return;
  return new Promise((resolve) => {
    const child = spawn(process.env.ZSHELL_EXECUTABLE, ["hook", params.provider ?? params.identity?.provider], {
      stdio: ["pipe", "ignore", "ignore"],
    });
    const timeout = setTimeout(() => { child.kill(); resolve(false); }, 3_000);
    child.on("error", () => { clearTimeout(timeout); resolve(false); });
    child.on("exit", (code) => { clearTimeout(timeout); resolve(code === 0); });
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify({ method, params }));
  });
}


const socketPath = process.env.ZSHELL_AUTOMATION_SOCKET;
const token = process.env.ZSHELL_AUTOMATION_TOKEN;
const terminalID = process.env.ZSHELL_TERMINAL_ID;
let requestSequence = Date.now() * 1000;
let requestChain = Promise.resolve();
let lastState;

function enabled() {
  return process.env.ZSHELL_AUTOMATION === "1"
    && (!!socketPath || !!process.env.ZSHELL_REMOTE_STATE)
    && !!token
    && !!terminalID;
}

function report(state, reason, attention) {
  if (`${state}:${attention ?? ""}` === lastState) return Promise.resolve();
  lastState = `${state}:${attention ?? ""}`;
  const pending = requestChain.then(() => reportOnce(state, reason, attention));
  requestChain = pending.catch(() => {});
  return pending;
}

function reportOnce(state, reason, attention) {
  if (process.env.ZSHELL_REMOTE_STATE) return remoteRequest("agent.lifecycle", { provider: "opencode", state, attention, reason });
  if (!enabled()) return Promise.resolve();

  requestSequence += 1;
  const request = {
    version: 1,
    id: `zshell:opencode:${requestSequence}`,
    method: "agent.lifecycle",
    token,
    terminalID,
    params: {
      provider: "opencode",
      state,
      attention,
      reason: reason ?? `OpenCode lifecycle: ${state}`,
    },
  };

  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      socket.destroy();
      resolve();
    };
    socket.setTimeout(15_000, finish);
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", finish);
    socket.on("error", finish);
    socket.on("end", finish);
    socket.on("close", finish);
  });
}

function stateFromStatus(status) {
  const value = typeof status === "string" ? status : status?.type;
  switch (value?.toLowerCase()) {
    case "idle": return "idle";
    case "active":
    case "busy":
    case "pending":
    case "retry":
    case "running":
    case "streaming":
    case "working": return "working";
    default: return undefined;
  }
}

export const ZshellAgentStatePlugin = async () => {
  if (!enabled()) return {};

  return {
    "chat.message": async () => report("working"),
    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      switch (type) {
        case "session.status": {
          const state = stateFromStatus(properties.status);
          if (state) await report(state);
          break;
        }
        case "tool.execute.before":
        case "tool.execute.after":
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
        case "session.compacted":
          await report("working");
          break;
        case "permission.asked":
          await report("blocked", undefined, "approval");
          break;
        case "question.asked":
          await report("blocked", undefined, "input");
          break;
        case "session.error":
          await report("blocked", undefined, "error");
          break;
        case "session.idle":
          await report("idle");
          break;
        default:
          break;
      }
    },
  };
};
