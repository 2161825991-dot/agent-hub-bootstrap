#!/usr/bin/env python3
import argparse
import json
import time
import urllib.error
import urllib.request


def request(method, url, token, payload=None):
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=20) as res:
        return json.loads(res.read().decode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description="Example remote agent for Agent Hub Local.")
    parser.add_argument("--hub", required=True, help="Example: http://192.168.1.20:8765")
    parser.add_argument("--token", required=True)
    parser.add_argument("--agent-id", default="windows-agent-01")
    parser.add_argument("--role", default="frontend")
    parser.add_argument("--name", default="Windows Agent")
    args = parser.parse_args()

    hub = args.hub.rstrip("/")
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
