#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {spawn} from "node:child_process";
import {createHash, createPrivateKey, generateKeyPairSync, randomBytes, sign as ed25519Sign} from "node:crypto";
import {isIP} from "node:net";
import {fileURLToPath} from "node:url";
import {setTimeout as sleep} from "node:timers/promises";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const INSTALL_DIR = process.env.AGENT_HUB_INSTALL_DIR || HERE;
const STATE_DIR = path.join(INSTALL_DIR, "state");
const AGENT_KIND = process.env.AGENT_HUB_KIND === "codex" ? "codex" : "claude-code";
const IS_CODEX = AGENT_KIND === "codex";
const RUNTIME_LABEL = IS_CODEX ? "Codex" : "Claude Code";
const AGENT_ID = process.env.AGENT_HUB_ID || AGENT_KIND;
const AGENT_NAME = process.env.AGENT_HUB_NAME || RUNTIME_LABEL;
const AGENT_ROLE = process.env.AGENT_HUB_ROLE || "agent";
const TOKEN = process.env.AGENT_HUB_TOKEN || "";
const RUNTIME_BIN = IS_CODEX ? (process.env.CODEX_BIN || "codex") : (process.env.CLAUDE_BIN || "claude");
let runtimeInstance = process.env.AGENT_HUB_RUNTIME_INSTANCE || "default";
const RUNTIME_VERSION = process.env.AGENT_HUB_RUNTIME_VERSION || "";
const REQUEST_TIMEOUT_MS = Number(process.env.AGENT_HUB_TIMEOUT || 15) * 1000;
const CLI_TIMEOUT_MS = Number(process.env.AGENT_HUB_CLI_TIMEOUT || 900) * 1000;
const HEARTBEAT_INTERVAL_MS = 10_000;
const INBOX_INTERVAL_MS = 2_500;
const CONTEXT_SNAPSHOT_INTERVAL = 20;
const CONNECTOR_VERSION = "1.0.0";
const SERVICE_MODE = process.env.AGENT_HUB_SERVICE_MODE || "manual";
const CODEX_HTTP_ONLY = !["0", "false", "no", "off"].includes(
  String(process.env.AGENT_HUB_CODEX_HTTP_ONLY || "1").trim().toLowerCase(),
);
const CODEX_HTTP_PROVIDER_ARGS = CODEX_HTTP_ONLY
  ? [
      "-c", 'model_provider="agenthub-http"',
      "-c", 'model_providers.agenthub-http.name="Agent Hub ChatGPT HTTP"',
      "-c", 'model_providers.agenthub-http.base_url="https://chatgpt.com/backend-api/codex"',
      "-c", 'model_providers.agenthub-http.wire_api="responses"',
      "-c", "model_providers.agenthub-http.requires_openai_auth=true",
      "-c", "model_providers.agenthub-http.supports_websockets=false",
    ]
  : [];

function isTrustedPrivateHost(hostname) {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
  const ipVersion = isIP(host);
  if (ipVersion === 4) {
    const parts = host.split(".").map(Number);
    return parts[0] === 10
      || parts[0] === 127
      || (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127)
      || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)
      || (parts[0] === 192 && parts[1] === 168);
  }
  if (ipVersion === 6) {
    return host === "::1"
      || host.startsWith("fc")
      || host.startsWith("fd");
  }
  return host === "localhost"
    || !host.includes(".")
    || host.endsWith(".local")
    || host.endsWith(".ts.net");
}

function validateHubUrl(value) {
  const parsed = new URL(String(value || "").trim().replace(/\/$/, ""));
  if (!["http:", "https:"].includes(parsed.protocol)) throw new Error("Hub URL must use http or https");
  if (parsed.username || parsed.password || parsed.search || parsed.hash || !["", "/"].includes(parsed.pathname)) {
    throw new Error("Hub URL must be an origin without credentials, path, query or fragment");
  }
  if (!isTrustedPrivateHost(parsed.hostname)) {
    throw new Error("Hub URL must use a trusted private-network name or address");
  }
  return parsed.origin;
}

function parseHubUrls() {
  const raw = process.env.AGENT_HUB_URLS || process.env.AGENT_HUB_URL || "http://127.0.0.1:8765";
  const values = [];
  for (const value of raw.split(/[;,]/)) {
    try {
      values.push(validateHubUrl(value));
    } catch {}
  }
  const result = [...new Set(values)];
  if (!result.length) throw new Error("No trusted t聊 URL is configured");
  return result;
}

let hubUrls = parseHubUrls();
let activeHubUrl = hubUrls[0];
let heartbeatBusy = false;
let stopping = false;

fs.mkdirSync(STATE_DIR, {recursive: true});
const SAFE_AGENT_ID = AGENT_ID.replace(/[^a-zA-Z0-9_-]/g, "-");
const PROCESSED_FILE = path.join(STATE_DIR, `${SAFE_AGENT_ID}-processed.json`);
const CONTEXT_STATE_FILE = path.join(STATE_DIR, `${SAFE_AGENT_ID}-context.json`);
const SESSION_STATE_FILE = path.join(STATE_DIR, `${SAFE_AGENT_ID}-${IS_CODEX ? "codex" : "claude"}-sessions.json`);
const LOCK_FILE = path.join(STATE_DIR, `${SAFE_AGENT_ID}.lock`);
const DEVICE_KEY_FILE = path.join(INSTALL_DIR, "device-key.json");

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

function base64url(value) {
  return Buffer.from(value).toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function ensureDeviceKey() {
  const existing = readJson(DEVICE_KEY_FILE, null);
  if (
    existing?.algorithm === "Ed25519"
    && typeof existing.key_id === "string"
    && typeof existing.public_key === "string"
    && typeof existing.private_key === "string"
  ) {
    return existing;
  }
  const {privateKey} = generateKeyPairSync("ed25519");
  const jwk = privateKey.export({format: "jwk"});
  const publicKey = Buffer.from(jwk.x, "base64url");
  const value = {
    algorithm: "Ed25519",
    key_id: `ed25519-${createHash("sha256").update(publicKey).digest("hex").slice(0, 24)}`,
    public_key: jwk.x,
    private_key: jwk.d,
    created_at: new Date().toISOString(),
  };
  writeJson(DEVICE_KEY_FILE, value);
  try {
    fs.chmodSync(DEVICE_KEY_FILE, 0o600);
  } catch {}
  return value;
}

function signedHeaders(method, endpoint, rawBody) {
  const key = ensureDeviceKey();
  const timestamp = String(Math.floor(Date.now() / 1000));
  const nonce = base64url(randomBytes(18));
  const bodyHash = createHash("sha256").update(rawBody).digest("hex");
  const canonical = `${method.toUpperCase()}\n${endpoint}\n${timestamp}\n${nonce}\n${bodyHash}`;
  const privateKey = createPrivateKey({
    key: {
      kty: "OKP",
      crv: "Ed25519",
      x: key.public_key,
      d: key.private_key,
    },
    format: "jwk",
  });
  const signature = base64url(ed25519Sign(null, Buffer.from(canonical, "utf8"), privateKey));
  return {
    Authorization: `Bearer ${TOKEN}`,
    "Content-Type": "application/json",
    "X-AgentHub-Key-Id": key.key_id,
    "X-AgentHub-Timestamp": timestamp,
    "X-AgentHub-Nonce": nonce,
    "X-AgentHub-Content-SHA256": bodyHash,
    "X-AgentHub-Signature": signature,
  };
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
      console.log(`t聊 connector is already running (PID ${oldPid}).`);
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
const contextStates = readJson(CONTEXT_STATE_FILE, {});
const warmContexts = new Set();

function remember(messageId) {
  if (!messageId) return;
  processed.add(String(messageId));
  writeJson(PROCESSED_FILE, [...processed].slice(-2000));
}

function rememberContext(conversationId, message, snapshotUsed, resolvedDocument = null) {
  const metadata = resolvedDocument || message.context_document || {};
  if (!metadata.policy_hash) return;
  const previous = contextStates[conversationId] || {};
  contextStates[conversationId] = {
    policy_hash: metadata.policy_hash,
    revision: metadata.revision || previous.revision || 0,
    turns_since_snapshot: snapshotUsed ? 1 : Number(previous.turns_since_snapshot || 0) + 1,
    last_message_id: message.message_id || null,
    context_through_message_id: message.context_document?.through_message_id || message.message_id || null,
    updated_at: new Date().toISOString(),
  };
  warmContexts.add(conversationId);
  const entries = Object.entries(contextStates)
    .sort((left, right) => String(right[1]?.updated_at || "").localeCompare(String(left[1]?.updated_at || "")))
    .slice(0, 500);
  writeJson(CONTEXT_STATE_FILE, Object.fromEntries(entries));
}

async function api(method, endpoint, body = undefined) {
  if (!TOKEN) return {ok: false, status: 401, error: "missing device token"};
  const rawBody = body === undefined ? "" : JSON.stringify(body);
  const urls = [activeHubUrl, ...hubUrls.filter(url => url !== activeHubUrl)];
  let lastError = "Hub is unreachable";
  for (const hubUrl of urls) {
    const controller = new AbortController();
    const timeoutMs = endpoint.includes("/inbox?")
      ? Math.max(REQUEST_TIMEOUT_MS, 35_000)
      : REQUEST_TIMEOUT_MS;
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(`${hubUrl}${endpoint}`, {
        method,
        headers: signedHeaders(method, endpoint, rawBody),
        body: body === undefined ? undefined : rawBody,
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
  return api("POST", `/agent/v1/agents/${encodeURIComponent(AGENT_ID)}/connection-report`, {
    stage,
    preflight_status: "ok",
    runtime_path: RUNTIME_BIN,
    runtime_version: RUNTIME_VERSION,
    runtime_instance: runtimeInstance,
    environment: `${os.platform()}-${os.arch()}`,
    connector_status: "running",
    service_status: "running",
    connector_version: CONNECTOR_VERSION,
    service_mode: SERVICE_MODE,
    ...extra,
  });
}

async function register() {
  return api("POST", "/agent/v1/agents/register", {
    id: AGENT_ID,
    name: AGENT_NAME,
    role: AGENT_ROLE,
    platform: os.platform() === "win32" ? "windows" : os.platform() === "darwin" ? "macos" : "linux",
    connect_mode: "client",
    device_label: os.hostname(),
    agent_kind: AGENT_KIND,
    runtime_instance: runtimeInstance,
    runtime_version: RUNTIME_VERSION,
    environment: `${os.platform()}-${os.arch()}`,
    permission_profile: "standard",
    capabilities: ["chat", "tasks", "mentions", "persistent_sessions"],
  });
}

function commandForRuntime(args) {
  const lower = RUNTIME_BIN.toLowerCase();
  if (process.platform === "win32" && (lower.endsWith(".cmd") || lower.endsWith(".bat"))) {
    return {command: process.env.ComSpec || "cmd.exe", args: ["/d", "/s", "/c", RUNTIME_BIN, ...args]};
  }
  if (process.platform === "win32" && lower.endsWith(".ps1")) {
    return {command: "powershell.exe", args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", RUNTIME_BIN, ...args]};
  }
  return {command: RUNTIME_BIN, args};
}

function runCommand(command, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {cwd: INSTALL_DIR, windowsHide: true, env: process.env});
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk.toString(); });
    child.stderr.on("data", chunk => { stderr += chunk.toString(); });
    // Codex appends piped stdin to the prompt. This connector never sends stdin,
    // so close the pipe immediately instead of leaving the CLI waiting for EOF.
    child.stdin.end();
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`${RUNTIME_LABEL} timed out after ${Math.round(timeoutMs / 1000)} seconds`));
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

function extractClaudeReply(raw) {
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    return {text: raw.trim(), sessionId: ""};
  }
  if (data?.is_error) throw new Error(data.result || data.subtype || "Claude Code returned an error");
  return {
    text: typeof data?.result === "string" ? data.result.trim() : raw.trim(),
    sessionId: typeof data?.session_id === "string" ? data.session_id.trim() : "",
  };
}

function extractCodexReply(raw) {
  let sessionId = "";
  let text = "";
  let failure = "";
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event?.type === "thread.started" && typeof event.thread_id === "string") {
      sessionId = event.thread_id.trim();
    }
    if (
      event?.type === "item.completed"
      && event.item?.type === "agent_message"
      && typeof event.item.text === "string"
    ) {
      text = event.item.text.trim();
    }
    if (event?.type === "turn.failed" || event?.type === "error") {
      failure = String(event.error?.message || event.message || event.error || "Codex returned an error");
    }
  }
  if (!text && failure) throw new Error(failure.slice(0, 1600));
  if (!text) throw new Error("Codex did not return an agent message");
  return {text, sessionId};
}

const claudeSessions = readJson(SESSION_STATE_FILE, {});

function rememberClaudeSession(conversationId, sessionId) {
  if (!conversationId || !sessionId || claudeSessions[conversationId] === sessionId) return;
  claudeSessions[conversationId] = sessionId;
  writeJson(SESSION_STATE_FILE, claudeSessions);
}

function buildLegacyPrompt(message, conversationId) {
  const instruction = message.hub_instruction || {};
  const participants = message.participants || instruction.participants || [];
  const rules = instruction.rules || [];
  const context = (message.group_context || []).slice(-12).map(item =>
    `- ${item.from_agent} -> ${item.to_agent} [${item.type}]: ${item.content || ""}`
  ).join("\n") || "None.";
  const memories = (message.approved_memories || []).slice(0, 10).map(item =>
    `- [${item.scope_type}] ${item.content || ""}`
  ).join("\n") || "None.";
  return [
    "You are working inside a t聊 multi-agent group chat.",
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
    "User-approved memory:",
    memories,
    "",
    "Current message:",
    message.content || "",
    "",
    "Return only the message that should be posted back to the group.",
  ].join("\n");
}

async function buildPrompt(message, conversationId) {
  const metadata = message.context_document || null;
  if (!metadata?.policy_hash || !metadata?.url) {
    return {prompt: buildLegacyPrompt(message, conversationId), snapshotUsed: false, resolvedDocument: null};
  }
  const state = contextStates[conversationId] || {};
  const snapshotUsed = metadata.sync_mode === "full"
    || !warmContexts.has(conversationId)
    || !state.policy_hash
    || state.policy_hash !== metadata.policy_hash
    || Number(state.turns_since_snapshot || 0) >= CONTEXT_SNAPSHOT_INTERVAL - 1;
  if (!snapshotUsed) {
    const delta = message.context_delta || {};
    const deltaContent = typeof delta.content === "string" ? delta.content : "";
    if (
      deltaContent
      && delta.content_sha256
      && createHash("sha256").update(deltaContent, "utf8").digest("hex") !== delta.content_sha256
    ) {
      throw new Error("group context delta checksum mismatch");
    }
    const unreadSection = deltaContent
      ? [
          "Unread messages from other group members since your previous successful turn:",
          deltaContent,
          "",
        ]
      : [];
    return {
      snapshotUsed: false,
      resolvedDocument: metadata,
      prompt: [
        "Continue the existing t聊 group conversation. The shared context is already loaded in this persistent session.",
        ...unreadSection,
        `Sender: ${message.from || "unknown"}`,
        "",
        "New message:",
        message.content || "",
        "",
        "Return only the message that should be posted back to the group. Do not restate the stored context.",
      ].join("\n"),
    };
  }
  const response = await api("GET", metadata.url);
  if (!response.ok || !response.document?.content) {
    throw new Error(response.error || "failed to read the group context document");
  }
  return {
    snapshotUsed: true,
    resolvedDocument: response.document,
    prompt: [
      "You are working inside a t聊 multi-agent group chat.",
      `Persistent conversation: ${conversationId}`,
      "Load the following Hub-managed context snapshot. Do not rewrite or quote it unless needed.",
      "",
      response.document.content,
      "",
      `Current sender: ${message.from || "unknown"}`,
      "Current message:",
      message.content || "",
      "",
      "Return only the message that should be posted back to the group.",
    ].join("\n"),
  };
}

async function sendMessage(message, type, content, suffix) {
  return api("POST", "/agent/v1/messages", {
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

async function ack(messageId, contextApplied = true) {
  return api("POST", `/agent/v1/messages/${encodeURIComponent(messageId)}/ack`, {
    agent_id: AGENT_ID,
    context_applied: Boolean(contextApplied),
  });
}

async function runRuntimePrompt(prompt, conversationId) {
  const sessionId = claudeSessions[conversationId] || "";
  const cliArgs = IS_CODEX
    ? sessionId
      ? ["exec", ...CODEX_HTTP_PROVIDER_ARGS, "resume", "--skip-git-repo-check", "--json", sessionId, prompt]
      : ["exec", ...CODEX_HTTP_PROVIDER_ARGS, "--sandbox", "read-only", "--skip-git-repo-check", "--json", prompt]
    : ["-p", "--output-format", "json", "--permission-mode", "default", ...(sessionId ? ["--resume", sessionId] : []), prompt];
  const invocation = commandForRuntime(cliArgs);
  const raw = await runCommand(invocation.command, invocation.args, CLI_TIMEOUT_MS + 30_000);
  const result = IS_CODEX ? extractCodexReply(raw) : extractClaudeReply(raw);
  rememberClaudeSession(conversationId, result.sessionId);
  return result.text.trim();
}

function reloadEndpoints() {
  const config = readJson(path.join(INSTALL_DIR, "agenthub.json"), {});
  const values = [];
  for (const value of String(config.hub_urls || config.hub_url || "").split(/[;,]/)) {
    try {
      values.push(validateHubUrl(value));
    } catch {}
  }
  if (values.length) {
    hubUrls = [...new Set(values)];
    if (!hubUrls.includes(activeHubUrl)) activeHubUrl = hubUrls[0];
  }
  return {hub_urls: hubUrls, active_hub_url: activeHubUrl};
}

async function executeSafeCommand(command) {
  const type = command?.command_type;
  if (type === "probe") {
    const invocation = commandForRuntime(["--version"]);
    const output = await runCommand(invocation.command, invocation.args, 30_000);
    // 只取版本号第一行，避免多行警告被服务端拒绝
    const versionLine = output.split('\n').find(l => /^\d+\.\d+/.test(l)) || output.slice(0, 64);
    return {result: {runtime: versionLine.slice(0, 128), hub_url: activeHubUrl}};
  }
  if (type === "reload_endpoints") return {result: reloadEndpoints()};
  if (type === "retry_delivery") return {result: {ready: true}};
  if (type === "restart_connector") return {result: {restarting: true}, exitAfter: true};
  throw new Error(`Unsupported t聊 command: ${type || "unknown"}`);
}

async function handleCommand(command) {
  if (!command?.id) return;
  let success = false;
  let result = null;
  let error = null;
  let exitAfter = false;
  try {
    const outcome = await executeSafeCommand(command);
    result = outcome.result;
    exitAfter = Boolean(outcome.exitAfter);
    success = true;
  } catch (caught) {
    error = String(caught?.message || caught).slice(0, 1600);
  }
  await api(
    "POST",
    `/agent/v1/agents/${encodeURIComponent(AGENT_ID)}/commands/${encodeURIComponent(command.id)}/result`,
    {success, result, error},
  );
  if (exitAfter && success) {
    stopping = true;
    releaseLock();
    process.exit(75);
  }
}

async function processVerification(message) {
  let output = "";
  let success = false;
  let error = null;
  try {
    output = await runRuntimePrompt(
      "This is a t聊 health check. Reply with exactly AGENTHUB_READY and nothing else.",
      `${AGENT_ID}-verification`,
    );
    success = output.split(/\r?\n/).some(line => line.trim() === "AGENTHUB_READY");
  } catch (caught) {
    error = String(caught?.message || caught).slice(0, 1600);
  }
  const response = await api(
    "POST",
    `/agent/v1/agents/${encodeURIComponent(AGENT_ID)}/verification-result`,
    {message_id: message.message_id, success, output, error},
  );
  if (response.status === 200 || response.status === 422) remember(message.message_id);
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
  if (message.type === "agent.verify") {
    await processVerification(message);
    return;
  }
  applyRuntimeSelection(await api("POST", `/agent/v1/agents/${encodeURIComponent(AGENT_ID)}/heartbeat`, {
    connector_version: CONNECTOR_VERSION,
    service_mode: SERVICE_MODE,
  }));

  const conversationId = message.conversation_id || `agenthub-task-${message.task_id}`;
  message.conversation_id = conversationId;
  await api("POST", `/agent/v1/tasks/${message.task_id}/claim`, {agent_id: AGENT_ID});
  await sendMessage(message, "task.progress", `${AGENT_NAME} 正在处理`, "progress");
  let contextApplied = false;
  try {
    const prompt = await buildPrompt(message, conversationId);
    const reply = await runRuntimePrompt(prompt.prompt, conversationId)
      || `已处理，但 ${RUNTIME_LABEL} 没有返回可显示的文本。`;
    const sent = await sendMessage(message, "task.result", reply, "result");
    if (!sent.ok) throw new Error(sent.error || "failed to send result");
    rememberContext(conversationId, message, prompt.snapshotUsed, prompt.resolvedDocument);
    contextApplied = true;
  } catch (error) {
    const text = `${RUNTIME_LABEL} 处理失败：${String(error?.message || error).slice(0, 1400)}`;
    const sent = await sendMessage(message, "task.error", text, "error");
    await report("failed", {
      connector_status: "running",
      last_error_code: "RUNTIME_EXEC_FAILED",
      last_error: text,
    });
    if (!sent.ok) return;
  }
  const acked = await ack(messageId, contextApplied);
  if (acked.ok) remember(messageId);
}

async function heartbeat() {
  if (heartbeatBusy || stopping) return null;
  heartbeatBusy = true;
  try {
    const result = await api("POST", `/agent/v1/agents/${encodeURIComponent(AGENT_ID)}/heartbeat`, {
      connector_version: CONNECTOR_VERSION,
      service_mode: SERVICE_MODE,
    });
    applyRuntimeSelection(result);
    if (result.ok && result.command) await handleCommand(result.command);
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
  console.log(`t聊 selected ${RUNTIME_LABEL} runtime: ${selected}`);
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

  console.log(`t聊 ${RUNTIME_LABEL} connector starting: ${AGENT_ID}`);
  const registered = await register();
  if (!registered.ok) console.log(`Registration pending: ${registered.error || registered.status}`);
  const firstHeartbeat = await heartbeat();
  if (!firstHeartbeat?.ready) await report("awaiting_approval", {approval_status: "pending"});
  const heartbeatTimer = setInterval(() => void heartbeat(), HEARTBEAT_INTERVAL_MS);
  heartbeatTimer.unref();

  let backoff = INBOX_INTERVAL_MS;
  while (!stopping) {
    const inbox = await api(
      "GET",
      `/agent/v1/agents/${encodeURIComponent(AGENT_ID)}/inbox?limit=1&wait=25&context_mode=compact-v1`,
    );
    if (inbox.ok) {
      applyRuntimeSelection(inbox);
      backoff = (inbox.messages || []).length ? 100 : 500;
      for (const message of inbox.messages || []) await processMessage(message);
    } else if (inbox.status !== 403) {
      console.log(`Hub reconnecting: ${inbox.error || "unknown error"}`);
      backoff = Math.min(backoff * 2, 30_000);
    }
    await sleep(backoff);
  }
}

if (process.argv[2] === "keygen") {
  const key = ensureDeviceKey();
  console.log(JSON.stringify({key_id: key.key_id, public_key: key.public_key}));
} else {
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
}
