#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {spawn} from "node:child_process";
import {fileURLToPath} from "node:url";
import {setTimeout as sleep} from "node:timers/promises";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTALL_DIR = process.env.AGENT_HUB_INSTALL_DIR || HERE;
const STATE_DIR = path.join(INSTALL_DIR, "state");
const AGENT_ID = process.env.AGENT_HUB_ID || "openclaw";
const AGENT_NAME = process.env.AGENT_HUB_NAME || "OpenClaw";
const AGENT_ROLE = process.env.AGENT_HUB_ROLE || "agent";
const TOKEN = process.env.AGENT_HUB_TOKEN || "";
const OPENCLAW_BIN = process.env.OPENCLAW_BIN || "openclaw";
let runtimeInstance = process.env.AGENT_HUB_RUNTIME_INSTANCE || "main";
const RUNTIME_VERSION = process.env.AGENT_HUB_RUNTIME_VERSION || "";
const REQUEST_TIMEOUT_MS = Number(process.env.AGENT_HUB_TIMEOUT || 15) * 1000;
const CLI_TIMEOUT_MS = Number(process.env.AGENT_HUB_CLI_TIMEOUT || 900) * 1000;
const HEARTBEAT_INTERVAL_MS = 10_000;
const INBOX_INTERVAL_MS = 2_500;

function parseHubUrls() {
  const raw = process.env.AGENT_HUB_URLS || process.env.AGENT_HUB_URL || "http://127.0.0.1:8765";
  return [...new Set(raw.split(/[;,]/).map(value => value.trim().replace(/\/$/, "")).filter(Boolean))];
}

const HUB_URLS = parseHubUrls();
let activeHubUrl = HUB_URLS[0];
let heartbeatBusy = false;
let stopping = false;

fs.mkdirSync(STATE_DIR, {recursive: true});
const SAFE_AGENT_ID = AGENT_ID.replace(/[^a-zA-Z0-9_-]/g, "-");
const PROCESSED_FILE = path.join(STATE_DIR, `${SAFE_AGENT_ID}-processed.json`);
const LOCK_FILE = path.join(STATE_DIR, `${SAFE_AGENT_ID}.lock`);

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  const temp = `${file}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  fs.renameSync(temp, file);
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function acquireLock() {
  if (fs.existsSync(LOCK_FILE)) {
    const oldPid = Number(fs.readFileSync(LOCK_FILE, "utf8").trim());
    if (oldPid && processExists(oldPid)) {
      console.log(`Agent Hub connector is already running (PID ${oldPid}).`);
      process.exit(0);
    }
    fs.rmSync(LOCK_FILE, {force: true});
  }
  fs.writeFileSync(LOCK_FILE, String(process.pid), {flag: "wx"});
}

function releaseLock() {
  try {
    if (Number(fs.readFileSync(LOCK_FILE, "utf8").trim()) === process.pid) fs.rmSync(LOCK_FILE, {force: true});
  } catch {}
}

const processed = new Set(readJson(PROCESSED_FILE, []).map(String));

function remember(messageId) {
  if (!messageId) return;
  processed.add(String(messageId));
  writeJson(PROCESSED_FILE, [...processed].slice(-2000));
}

async function api(method, endpoint, body = undefined) {
  if (!TOKEN) return {ok: false, status: 401, error: "missing device token"};
  const urls = [activeHubUrl, ...HUB_URLS.filter(url => url !== activeHubUrl)];
  let lastError = "Hub is unreachable";
  for (const hubUrl of urls) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const response = await fetch(`${hubUrl}${endpoint}`, {
        method,
        headers: {Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json"},
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
      });
      const text = await response.text();
      let payload;
      try {
        payload = text ? JSON.parse(text) : {};
      } catch {
        payload = {ok: false, error: text || response.statusText};
      }
      payload.status = response.status;
      if (response.ok) {
        activeHubUrl = hubUrl;
        return payload;
      }
      lastError = payload.error || `HTTP ${response.status}`;
      if (response.status < 500) return {ok: false, status: response.status, error: lastError, ...payload};
    } catch (error) {
      lastError = error?.name === "AbortError" ? "request timed out" : String(error?.message || error);
    } finally {
      clearTimeout(timer);
    }
  }
  return {ok: false, status: 0, error: lastError};
}

async function report(stage, extra = {}) {
  return api("POST", `/api/agents/${encodeURIComponent(AGENT_ID)}/connection-report`, {
    stage,
    preflight_status: "ok",
    runtime_path: OPENCLAW_BIN,
    runtime_version: RUNTIME_VERSION,
    runtime_instance: runtimeInstance,
    environment: `${os.platform()}-${os.arch()}`,
    connector_status: "running",
    service_status: "running",
    ...extra,
  });
}

async function register() {
  return api("POST", "/api/agents/register", {
    id: AGENT_ID,
    name: AGENT_NAME,
    role: AGENT_ROLE,
    platform: os.platform() === "win32" ? "windows" : os.platform() === "darwin" ? "macos" : "linux",
    connect_mode: "client",
    device_label: os.hostname(),
    agent_kind: "openclaw",
    runtime_instance: runtimeInstance,
    runtime_version: RUNTIME_VERSION,
    environment: `${os.platform()}-${os.arch()}`,
    permission_profile: "standard",
    capabilities: ["chat", "tasks", "mentions", "persistent_sessions"],
  });
}

function commandForOpenClaw(args) {
  const lower = OPENCLAW_BIN.toLowerCase();
  if (process.platform === "win32" && (lower.endsWith(".cmd") || lower.endsWith(".bat"))) {
    return {command: process.env.ComSpec || "cmd.exe", args: ["/d", "/s", "/c", OPENCLAW_BIN, ...args]};
  }
  if (process.platform === "win32" && lower.endsWith(".ps1")) {
    return {command: "powershell.exe", args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", OPENCLAW_BIN, ...args]};
  }
  return {command: OPENCLAW_BIN, args};
}

function runCommand(command, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {cwd: INSTALL_DIR, windowsHide: true, env: process.env});
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk.toString(); });
    child.stderr.on("data", chunk => { stderr += chunk.toString(); });
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`OpenClaw timed out after ${Math.round(timeoutMs / 1000)} seconds`));
    }, timeoutMs);
    child.on("error", error => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", code => {
      clearTimeout(timer);
      if (code !== 0) reject(new Error((stderr || stdout || `exit code ${code}`).trim().slice(0, 1600)));
      else resolve(stdout.trim());
    });
  });
}

function extractReply(raw) {
  try {
    const data = JSON.parse(raw);
    const payloads = data?.result?.payloads || [];
    const texts = payloads.map(item => item?.text).filter(Boolean);
    if (texts.length) return texts.join("\n\n").trim();
    const meta = data?.result?.meta?.agentMeta || {};
    return meta.finalAssistantVisibleText || meta.finalAssistantRawText || data.summary || raw;
  } catch {
    return raw.trim();
  }
}

function buildPrompt(message, conversationId) {
  const instruction = message.hub_instruction || {};
  const participants = message.participants || instruction.participants || [];
  const rules = instruction.rules || [];
  const context = (message.group_context || []).slice(-12).map(item =>
    `- ${item.from_agent} -> ${item.to_agent} [${item.type}]: ${item.content || ""}`
  ).join("\n") || "None.";
  return [
    "You are working inside an Agent Hub multi-agent group chat.",
    `Group: #${message.task_id || "unknown"} ${instruction.task_title || ""}`,
    `Members: ${participants.join(", ") || "unknown"}`,
    `Persistent conversation: ${conversationId}`,
    `Sender: ${message.from || "unknown"}`,
    "",
    "Collaboration rules:",
    ...rules.map((rule, index) => `${index + 1}. ${rule}`),
    "",
    "Recent group context:",
    context,
    "",
    "Current message:",
    message.content || "",
    "",
    "Return only the message that should be posted back to the group.",
  ].join("\n");
}

async function sendMessage(message, type, content, suffix) {
  return api("POST", "/api/messages", {
    task_id: message.task_id,
    from: AGENT_ID,
    to: "user",
    type,
    content,
    reply_to: message.message_id,
    conversation_id: message.conversation_id,
    client_message_id: `${message.message_id}:${suffix}`,
  });
}

async function ack(messageId) {
  return api("POST", `/api/messages/${encodeURIComponent(messageId)}/ack`, {agent_id: AGENT_ID});
}

async function processMessage(message) {
  const messageId = message.message_id;
  if (!messageId) return;
  if (processed.has(messageId)) {
    await ack(messageId);
    return;
  }
  if (message.type === "agent.ping") {
    const sent = await sendMessage(message, "agent.pong", `[${AGENT_NAME}] pong`, "pong");
    if (sent.ok) {
      await ack(messageId);
      remember(messageId);
    }
    return;
  }
  applyRuntimeSelection(await api("POST", `/api/agents/${encodeURIComponent(AGENT_ID)}/heartbeat`, {}));

  const conversationId = message.conversation_id || `agenthub-task-${message.task_id}`;
  message.conversation_id = conversationId;
  await api("POST", `/api/tasks/${message.task_id}/claim`, {agent_id: AGENT_ID});
  await sendMessage(message, "task.progress", `${AGENT_NAME} 正在处理`, "progress");
  const cliArgs = ["agent"];
  if (runtimeInstance) cliArgs.push("--agent", runtimeInstance);
  cliArgs.push(
    "--session-id", conversationId,
    "--message", buildPrompt(message, conversationId),
    "--json",
    "--timeout", String(Math.round(CLI_TIMEOUT_MS / 1000)),
  );
  try {
    const invocation = commandForOpenClaw(cliArgs);
    const raw = await runCommand(invocation.command, invocation.args, CLI_TIMEOUT_MS + 30_000);
    const reply = extractReply(raw) || "已处理，但 OpenClaw 没有返回可显示的文本。";
    const sent = await sendMessage(message, "task.result", reply, "result");
    if (!sent.ok) throw new Error(sent.error || "failed to send result");
  } catch (error) {
    const text = `OpenClaw 处理失败：${String(error?.message || error).slice(0, 1400)}`;
    const sent = await sendMessage(message, "task.error", text, "error");
    await report("failed", {
      connector_status: "running",
      last_error_code: "RUNTIME_EXEC_FAILED",
      last_error: text,
    });
    if (!sent.ok) return;
  }
  const acked = await ack(messageId);
  if (acked.ok) remember(messageId);
}

async function heartbeat() {
  if (heartbeatBusy || stopping) return null;
  heartbeatBusy = true;
  try {
    const result = await api("POST", `/api/agents/${encodeURIComponent(AGENT_ID)}/heartbeat`, {});
    applyRuntimeSelection(result);
    if (result.ok && result.ready) await report("ready", {approval_status: "approved"});
    return result;
  } finally {
    heartbeatBusy = false;
  }
}

function applyRuntimeSelection(result) {
  const selected = String(result?.runtime_instance || "").trim();
  if (!selected || selected === runtimeInstance) return;
  runtimeInstance = selected;
  const configFile = path.join(INSTALL_DIR, "agenthub.json");
  const config = readJson(configFile, null);
  if (config && typeof config === "object") {
    config.runtime_instance = selected;
    writeJson(configFile, config);
  }
  console.log(`Agent Hub selected OpenClaw instance: ${selected}`);
}

async function main() {
  if (!TOKEN) throw new Error("AGENT_HUB_TOKEN is missing");
  acquireLock();
  process.on("exit", releaseLock);
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => {
      stopping = true;
      releaseLock();
      process.exit(0);
    });
  }

  console.log(`Agent Hub OpenClaw connector starting: ${AGENT_ID}`);
  const registered = await register();
  if (!registered.ok) console.log(`Registration pending: ${registered.error || registered.status}`);
  const firstHeartbeat = await heartbeat();
  if (!firstHeartbeat?.ready) await report("awaiting_approval", {approval_status: "pending"});
  const heartbeatTimer = setInterval(() => void heartbeat(), HEARTBEAT_INTERVAL_MS);
  heartbeatTimer.unref();

  let backoff = INBOX_INTERVAL_MS;
  while (!stopping) {
    const inbox = await api("GET", `/api/agents/${encodeURIComponent(AGENT_ID)}/inbox?limit=20`);
    if (inbox.ok) {
      backoff = INBOX_INTERVAL_MS;
      for (const message of inbox.messages || []) await processMessage(message);
    } else if (inbox.status !== 403) {
      console.log(`Hub reconnecting: ${inbox.error || "unknown error"}`);
      backoff = Math.min(backoff * 2, 30_000);
    }
    await sleep(backoff);
  }
}

main().catch(async error => {
  console.error(String(error?.stack || error));
  try {
    await report("failed", {
      connector_status: "stopped",
      service_status: "failed",
      last_error_code: "CONNECTOR_START_FAILED",
      last_error: String(error?.message || error).slice(0, 1600),
    });
  } catch {}
  releaseLock();
  process.exit(1);
});
