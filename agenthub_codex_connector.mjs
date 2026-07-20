#!/usr/bin/env node
process.env.AGENT_HUB_KIND = "codex";
await import("./agenthub_claude_code_connector.mjs");
