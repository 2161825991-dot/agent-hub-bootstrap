# t聊 Bootstrap Security

## Supported Use

t聊 is designed for a local macOS App with remote Agents connected through Tailscale or another trusted private network. Do not expose the Mac port directly to the public Internet.

The administration plane is loopback-only. The Agent plane accepts only a local private interface selected by the Hub. Wildcard, public, link-local and non-local bind addresses are rejected.

The bootstrap repository contains only generic installers, connectors, MCP code and documentation. It must never contain:

- Hub administration tokens or device credentials
- One-time invitation URLs or codes
- User databases, messages, logs or backups
- Private network addresses or machine-specific paths
- OpenClaw workspaces or Hermes profiles

## Release Verification

The one-line invitation command verifies the downloaded `join-agenthub` entry by SHA256. The trusted entry then verifies:

1. The Ed25519 signature on `RELEASE_MANIFEST.json`.
2. The manifest checksum for the platform installer.
3. The manifest checksum for the selected connector and MCP server.

The release public key is embedded in the trusted entry script and published as `release-public-key.txt`. The private signing key is not stored in this repository or in the App bundle.

If any signature or checksum differs, installation stops before the downloaded program is executed.

Before its first request, each bootstrap validates that the invitation uses the expected t聊 path and resolves only to loopback, RFC1918 private space or Tailscale `100.64.0.0/10`. URLs with credentials, query strings, fragments, public addresses or link-local addresses are rejected.

## Device Security

- Each installation receives a random, scoped, revocable device token.
- New installations generate an Ed25519 device key.
- Authenticated requests include a timestamp, nonce, body hash and signature.
- The Hub rejects signatures outside the allowed clock window and rejects nonce replay.
- Device keys and configuration files use user-only permissions.
- Existing OpenClaw, Hermes, Claude Code, and Codex configuration is backed up before optional MCP changes.
- Windows install directories use user-only ACLs; Unix install files use `umask 077` and explicit `600/700` permissions.

## Reporting

Use the repository's private security advisory function for suspected vulnerabilities. Do not include live tokens, invitation URLs, messages, databases or unredacted logs in a public issue.

Include:

- Affected version and operating system
- Minimal reproduction steps using test credentials
- Expected and observed behavior
- Whether authentication, authorization, message integrity or installation integrity is affected

## Release Gate

A release is blocked when signature verification, checksum verification, syntax checks, secret scanning or Windows PowerShell parsing fails. Public deployment additionally requires an independent penetration test, managed TLS termination and upstream WAF/DDoS protection.
