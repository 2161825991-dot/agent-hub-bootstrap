param(
  [Parameter(Mandatory = $true)]
  [string]$InviteUrl,
  [string]$RawBase = "https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
)

$ErrorActionPreference = "Stop"
$RawBase = $RawBase.TrimEnd("/")

try {
  $response = Invoke-RestMethod -Method Get -Uri $InviteUrl -TimeoutSec 30
} catch {
  throw "无法读取邀请，请确认两台电脑在同一局域网，并允许访问 Agent Hub：$($_.Exception.Message)"
}
if (-not $response.ok) { throw ([string]$response.error) }
$invite = $response.invite
if ($invite.expired -or [string]$invite.status -notin @("open", "claimed", "approved")) {
  throw "邀请不可用或已经使用：$($invite.status)"
}
if ([string]$invite.agent_kind -notin @("openclaw", "hermes")) {
  throw "这个一键入口仅支持 OpenClaw 和 Hermes，请在 Agent Hub 重新选择 Agent 类型。"
}

$installer = Join-Path $env:TEMP "agenthub-install-agent.ps1"
Invoke-WebRequest -Uri "$RawBase/install-agent.ps1" -OutFile $installer -UseBasicParsing
$expectedHash = [string]$invite.bootstrap.checksums.install_agent_ps1
if ($expectedHash) {
  $actualHash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    throw "安装脚本校验失败，已停止接入。"
  }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
  -RawBase $RawBase `
  -InviteUrl $InviteUrl `
  -ConnectMode client `
  -AgentId ([string]$invite.suggested_agent_id) `
  -Role ([string]$invite.role) `
  -AgentKind ([string]$invite.agent_kind) `
  -Restart `
  -Autostart

Write-Host ""
Write-Host "连接请求已发送。请回到 Agent Hub，点击「允许并开始聊天」。" -ForegroundColor Green
