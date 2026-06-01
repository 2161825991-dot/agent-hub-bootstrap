#!/usr/bin/env python3
"""
AgentHub MCP Server

Zero-dependency stdio MCP server that exposes the local Agent Hub HTTP API
as MCP tools. It is intentionally small and conservative so OpenClaw/Hermes
can use it without installing extra packages.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DEFAULT_HUB_URL = os.environ.get("AGENT_HUB_URL", "http://127.0.0.1:8765").rstrip("/")
TOKEN_PATH = ROOT / ".agent_hub_token"
DEFAULT_TOKEN = os.environ.get("AGENT_HUB_TOKEN") or (
    TOKEN_PATH.read_text(encoding="utf-8").strip() if TOKEN_PATH.exists() else ""
)


TOOLS = [
    {
        "name": "agenthub_register",
        "description": "Register an agent with Agent Hub and mark it online.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agent_id": {"type": "string"},
                "name": {"type": "string"},
                "role": {"type": "string"},
                "endpoint": {"type": ["string", "null"]},
            },
            "required": ["agent_id", "name", "role"],
        },
    },
    {
        "name": "agenthub_heartbeat",
        "description": "Send heartbeat for an agent.",
        "inputSchema": {
            "type": "object",
            "properties": {"agent_id": {"type": "string"}},
            "required": ["agent_id"],
        },
    },
    {
        "name": "agenthub_inbox",
        "description": "Get pending messages for an agent. Messages include conversation_id.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agent_id": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 200},
            },
            "required": ["agent_id"],
        },
    },
    {
        "name": "agenthub_send_message",
        "description": "Send a message to a user or agent through Agent Hub.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": ["integer", "null"]},
                "from_agent": {"type": "string"},
                "to_agent": {"type": "string"},
                "type": {"type": "string"},
                "content": {"type": "string"},
                "conversation_id": {"type": ["string", "null"]},
                "reply_to": {"type": ["string", "null"]},
            },
            "required": ["from_agent", "to_agent", "type", "content"],
        },
    },
    {
        "name": "agenthub_ack",
        "description": "Acknowledge a message after it has been safely handled.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "message_id": {"type": "string"},
                "agent_id": {"type": "string"},
            },
            "required": ["message_id", "agent_id"],
        },
    },
    {
        "name": "agenthub_claim_task",
        "description": "Claim a task for an agent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "integer"},
                "agent_id": {"type": "string"},
            },
            "required": ["task_id", "agent_id"],
        },
    },
    {
        "name": "agenthub_complete_task",
        "description": "Mark a task done and store a result.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "integer"},
                "agent_id": {"type": "string"},
                "result": {"type": "string"},
            },
            "required": ["task_id", "agent_id", "result"],
        },
    },
    {
        "name": "agenthub_get_chat",
        "description": "Read chat messages for a task/group.",
        "inputSchema": {
            "type": "object",
            "properties": {"task_id": {"type": "integer"}},
            "required": ["task_id"],
        },
    },
    {
        "name": "agenthub_list_tasks",
        "description": "List tasks, optionally filtered by status, role, or priority.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {"type": ["string", "null"]},
                "role": {"type": ["string", "null"]},
                "priority": {"type": ["string", "null"]},
            },
        },
    },
    {
        "name": "agenthub_status",
        "description": "Get Agent Hub status, agents, and delivery counts.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


class McpError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def hub_request(method, path, body=None):
    url = DEFAULT_HUB_URL + path
    headers = {"Content-Type": "application/json"}
    if DEFAULT_TOKEN:
        headers["Authorization"] = f"Bearer {DEFAULT_TOKEN}"
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise McpError(-32001, f"Agent Hub HTTP {exc.code}: {detail[:1000]}")
    except Exception as exc:
        raise McpError(-32002, f"Agent Hub request failed: {exc}")


def text_content(value):
    return [{"type": "text", "text": json.dumps(value, ensure_ascii=False, indent=2)}]


def call_tool(name, args):
    args = args or {}
    if name == "agenthub_register":
        body = {
            "id": args["agent_id"],
            "name": args["name"],
            "role": args["role"],
            "endpoint": args.get("endpoint"),
        }
        return hub_request("POST", "/api/agents/register", body)

    if name == "agenthub_heartbeat":
        return hub_request("POST", f"/api/agents/{urllib.parse.quote(args['agent_id'])}/heartbeat", {})

    if name == "agenthub_inbox":
        limit = int(args.get("limit") or 50)
        agent_id = urllib.parse.quote(args["agent_id"])
        return hub_request("GET", f"/api/agents/{agent_id}/inbox?after_seq=0&limit={limit}")

    if name == "agenthub_send_message":
        body = {
            "task_id": args.get("task_id"),
            "from": args["from_agent"],
            "to": args["to_agent"],
            "type": args["type"],
            "content": args["content"],
            "conversation_id": args.get("conversation_id"),
            "reply_to": args.get("reply_to"),
        }
        return hub_request("POST", "/api/messages", body)

    if name == "agenthub_ack":
        msg_id = urllib.parse.quote(args["message_id"])
        return hub_request("POST", f"/api/messages/{msg_id}/ack", {"agent_id": args["agent_id"]})

    if name == "agenthub_claim_task":
        return hub_request("POST", f"/api/tasks/{int(args['task_id'])}/claim", {"agent_id": args["agent_id"]})

    if name == "agenthub_complete_task":
        return hub_request(
            "POST",
            f"/api/tasks/{int(args['task_id'])}/complete",
            {"agent_id": args["agent_id"], "result": args["result"]},
        )

    if name == "agenthub_get_chat":
        return hub_request("GET", f"/api/chat/{int(args['task_id'])}/messages")

    if name == "agenthub_list_tasks":
        params = {
            key: value
            for key, value in {
                "status": args.get("status"),
                "role": args.get("role"),
                "priority": args.get("priority"),
            }.items()
            if value
        }
        qs = urllib.parse.urlencode(params)
        return hub_request("GET", "/api/tasks" + (f"?{qs}" if qs else ""))

    if name == "agenthub_status":
        return hub_request("GET", "/status")

    raise McpError(-32602, f"Unknown tool: {name}")


def handle_request(request):
    method = request.get("method")
    req_id = request.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "agenthub-mcp", "version": "0.1.0"},
            },
        }

    if method == "notifications/initialized":
        return None

    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}}

    if method == "tools/call":
        params = request.get("params", {})
        result = call_tool(params.get("name"), params.get("arguments") or {})
        return {"jsonrpc": "2.0", "id": req_id, "result": {"content": text_content(result), "isError": False}}

    if req_id is None:
        return None

    raise McpError(-32601, f"Method not found: {method}")


def respond_error(req_id, error):
    if isinstance(error, McpError):
        payload = {"code": error.code, "message": error.message}
        if error.data is not None:
            payload["data"] = error.data
    else:
        payload = {"code": -32603, "message": str(error)}
    return {"jsonrpc": "2.0", "id": req_id, "error": payload}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            response = handle_request(request)
        except Exception as exc:
            req_id = None
            try:
                req_id = json.loads(line).get("id")
            except Exception:
                pass
            response = respond_error(req_id, exc)
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
