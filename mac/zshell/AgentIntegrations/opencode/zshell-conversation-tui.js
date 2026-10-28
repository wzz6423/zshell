// ZSHELL_INTEGRATION_ID=opencode-conversation
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

import os from "node:os";
import path from "node:path";

const socketPath = process.env.ZSHELL_AUTOMATION_SOCKET;
const token = process.env.ZSHELL_AUTOMATION_TOKEN;
const terminalID = process.env.ZSHELL_TERMINAL_ID;

function request(method, params) {
  if (process.env.ZSHELL_REMOTE_STATE) return remoteRequest(method, params);
  if (process.env.ZSHELL_AUTOMATION !== "1" || (!socketPath && !process.env.ZSHELL_REMOTE_STATE) || !token || !terminalID) {
    return Promise.resolve(false);
  }
  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    let finished = false;
    let data = "";
    const finish = (accepted = false) => {
      if (finished) return;
      finished = true;
      socket.destroy();
      resolve(accepted);
    };
    socket.setTimeout(750, () => finish());
    socket.on("connect", () => socket.write(`${JSON.stringify({
      version: 1,
      id: `zshell:opencode:session:${Date.now()}`,
      method,
      token,
      terminalID,
      params: { ...params, reporter_pid: process.pid, source: "tui" },
    })}\n`));
    socket.on("data", (chunk) => {
      data += chunk.toString();
      if (data.length > 65536) return finish();
      if (!data.includes("\n")) return;
      try { finish(JSON.parse(data.split("\n")[0]).ok === true); }
      catch { finish(); }
    });
    socket.on("error", () => finish());
    socket.on("end", () => finish());
    socket.on("close", () => finish());
  });
}

function rootIdentity(api) {
  const route = api.route.current;
  if (route.name !== "session") return null;
  let id = route.params?.sessionID;
  const sessions = api.state.session;
  const seen = new Set();
  while (typeof id === "string" && !seen.has(id)) {
    seen.add(id);
    const session = sessions?.get?.(id);
    if (!session) return;
    if (session.parentID) {
      id = session.parentID;
      continue;
    }
    const directory = session.directory;
    if (!/^ses_[A-Za-z0-9_-]{1,124}$/.test(id) || typeof directory !== "string" || !path.isAbsolute(directory)) return;
    return {
      provider: "opencode",
      sessionID: id,
      workingDirectory: directory,
      configDirectory: path.resolve(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config")),
      configurationEnvironment: Object.fromEntries([
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
        "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_TUI_CONFIG",
      ].flatMap((name) => process.env[name] ? [[name, path.resolve(process.env[name])]] : [])),
    };
  }
}

function setup(api) {
  if (process.env.ZSHELL_AUTOMATION !== "1" || (!socketPath && !process.env.ZSHELL_REMOTE_STATE) || !token || !terminalID) return;
  let reported;
  let observedRoute;
  let needsClear = false;
  let pending = false;
  let disposed = false;
  const publish = async () => {
    if (disposed) return;
    const route = api.route.current;
    const routeID = route.name === "session" ? route.params?.sessionID : null;
    if (routeID !== observedRoute) {
      observedRoute = routeID;
      needsClear = reported !== undefined && reported !== null;
    }
    if (pending) return;
    const identity = rootIdentity(api);
    // Undefined means the route has not loaded its session yet. Home is an
    // explicit null and must revoke the previous conversation binding.
    if (!needsClear && (identity === undefined || reported === (identity?.sessionID ?? null))) return;
    pending = true;
    try {
      if (needsClear) {
        if (!await request("agent.session.clear", { provider: "opencode" })) return;
        reported = null;
        needsClear = false;
      }
      if (disposed || observedRoute !== routeID || identity === undefined) return;
      const accepted = identity
        ? await request("agent.session.start", { identity })
        : await request("agent.session.clear", { provider: "opencode" });
      if (accepted) {
        reported = identity?.sessionID ?? null;
        if (observedRoute !== routeID) needsClear = reported !== null;
      }
    } finally {
      pending = false;
      if (!disposed && observedRoute !== routeID) void publish();
    }
  };
  void publish();
  const timer = setInterval(() => { void publish(); }, 250);
  const dispose = () => { disposed = true; clearInterval(timer); };
  api.lifecycle?.onDispose?.(dispose);
  return dispose;
}

export default {
  id: "zshell-conversation",
  tui: async (api) => { setup(api); },
};
