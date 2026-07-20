#!/usr/bin/env python3
import argparse
import ipaddress
import json
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

ALLOWED_NETWORKS = (
    ipaddress.ip_network((0x0A000000, 8)),
    ipaddress.ip_network((0xAC100000, 12)),
    ipaddress.ip_network((0xC0A80000, 16)),
    ipaddress.ip_network((0x64400000, 10)),
    ipaddress.ip_network("fc00::/7"),
)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


HTTP_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    NoRedirectHandler(),
)


def is_allowed_address(address):
    value = ipaddress.ip_address(address)
    return value.is_loopback or any(value in network for network in ALLOWED_NETWORKS)


def validate_hub(hub):
    parsed = urllib.parse.urlsplit(hub.strip())
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("Hub URL only supports http or https")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Hub URL cannot contain credentials, query, or fragment")
    if not parsed.hostname or parsed.path not in {"", "/"}:
        raise ValueError("Hub URL must be an origin without an extra path")
    try:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise ValueError("Hub URL has an invalid port") from exc
    addresses = {
        item[4][0]
        for item in socket.getaddrinfo(parsed.hostname, port, type=socket.SOCK_STREAM)
    }
    if not addresses or any(not is_allowed_address(address) for address in addresses):
        raise ValueError("Hub must resolve only to loopback, private, or Tailscale addresses")
    return f"{parsed.scheme}://{parsed.netloc}".rstrip("/")


def request(method, url, token, payload=None):
    parsed = urllib.parse.urlsplit(url)
    hub = validate_hub(f"{parsed.scheme}://{parsed.netloc}")
    if not parsed.path.startswith(("/api/", "/agent/v1/")):
        raise ValueError("refusing an unexpected t聊 API path")
    url = urllib.parse.urlunsplit((urllib.parse.urlsplit(hub).scheme, parsed.netloc, parsed.path, parsed.query, ""))
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with HTTP_OPENER.open(req, timeout=20) as res:
        return json.loads(res.read().decode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description="Example remote agent for t聊 Local.")
    parser.add_argument("--hub", required=True, help="Example: http://MAC_LAN_IP:8765")
    parser.add_argument("--token", required=True)
    parser.add_argument("--agent-id", default="windows-agent-01")
    parser.add_argument("--role", default="frontend")
    parser.add_argument("--name", default="Windows Agent")
    args = parser.parse_args()

    hub = validate_hub(args.hub)
    print(f"Connecting {args.agent_id} to {hub}")
    request(
        "POST",
        f"{hub}/api/agents/register",
        args.token,
        {"id": args.agent_id, "name": args.name, "role": args.role, "endpoint": None},
    )

    while True:
        try:
            request("POST", f"{hub}/api/agents/{args.agent_id}/heartbeat", args.token, {})
            inbox = request("GET", f"{hub}/api/agents/{args.agent_id}/inbox?after_seq=0", args.token)
            for msg in inbox.get("messages", []):
                message_id = msg["message_id"]
                task_id = msg.get("task_id")
                conversation_id = msg.get("conversation_id") or f"{args.agent_id}-task-{task_id}"
                content = msg.get("content", "")
                print(f"Received {message_id} in {conversation_id}: {content[:80]}")

                reply = f"{args.name} 已收到：{content[:120]}"
                request(
                    "POST",
                    f"{hub}/api/messages",
                    args.token,
                    {
                        "task_id": task_id,
                        "from": args.agent_id,
                        "to": "user",
                        "type": "task.result",
                        "conversation_id": conversation_id,
                        "content": reply,
                        "reply_to": message_id,
                    },
                )
                request(
                    "POST",
                    f"{hub}/api/messages/{message_id}/ack",
                    args.token,
                    {"agent_id": args.agent_id},
                )
        except urllib.error.URLError as exc:
            print(f"Network error: {exc}")
        except Exception as exc:
            print(f"Agent error: {exc}")
        time.sleep(5)


if __name__ == "__main__":
    main()
