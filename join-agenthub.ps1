param(
  [Parameter(Mandatory = $true)]
  [string]$InviteUrl,
  [string]$RawBase = "https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main"
)

$ErrorActionPreference = "Stop"
$RawBase = $RawBase.TrimEnd("/")
$ReleasePublicKey = "BEuW3xmEu_5b3anZMMow5TIojPTSU5qghf776UPu2i4"
$PythonVerifierSha256 = "7eb83127b9752265c2e2bab016a735eecee860f93463d993038d141453e099e3"
$NodeVerifierSha256 = "36da562c93c8739bf8d8b7286dca1c1f496215f3eac9ec28398909c73315ef1c"

function Test-AgentHubPrivateAddress([System.Net.IPAddress]$Address) {
  if ([System.Net.IPAddress]::IsLoopback($Address)) { return $true }
  if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
  $bytes = $Address.GetAddressBytes()
  if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
    return (
      $bytes[0] -eq 10 -or
      ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
      ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
      ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127)
    )
  }
  if ($Address.IsIPv6LinkLocal) { return $false }
  return (($bytes[0] -band 0xFE) -eq 0xFC)
}

function Assert-AgentHubInviteUrl([string]$Value) {
  try { $uri = [System.Uri]$Value } catch { throw "邀请地址格式无效。" }
  if (
    -not $uri.IsAbsoluteUri -or
    $uri.Scheme -notin @("http", "https") -or
    $uri.UserInfo -or
    $uri.Query -or
    $uri.Fragment -or
    $uri.AbsolutePath.TrimEnd("/") -notmatch '^/(api|agent/v1)/invites/[A-Za-z0-9_-]+$'
  ) {
    throw "邀请地址格式不安全或不是标准 t聊 邀请。"
  }
  $hostName = $uri.DnsSafeHost.Trim("[", "]")
  $parsedAddress = $null
  if ([System.Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress)) {
    $addresses = @($parsedAddress)
  } else {
    try { $addresses = @([System.Net.Dns]::GetHostAddresses($hostName)) }
    catch { throw "邀请主机无法解析：$($_.Exception.Message)" }
  }
  if ($addresses.Count -eq 0 -or @($addresses | Where-Object { -not (Test-AgentHubPrivateAddress $_) }).Count -gt 0) {
    throw "邀请地址必须位于本机、可信私网或 Tailscale 网络。"
  }
  return $uri
}

$InviteUri = Assert-AgentHubInviteUrl $InviteUrl
$InviteUrl = $InviteUri.AbsoluteUri.TrimEnd("/")

try {
  $response = Invoke-RestMethod -Method Get -Uri $InviteUrl -TimeoutSec 30
} catch {
  throw "无法读取邀请，请确认两台电脑在同一局域网，并允许访问 t聊：$($_.Exception.Message)"
}
if (-not $response.ok) { throw ([string]$response.error) }
$invite = $response.invite
if ($invite.expired -or [string]$invite.status -notin @("open", "claimed", "approved")) {
  throw "邀请不可用或已经使用：$($invite.status)"
}
if ([string]$invite.agent_kind -notin @("openclaw", "hermes", "claude-code", "codex")) {
  throw "这个一键入口仅支持 OpenClaw、Hermes、Claude Code 和 Codex，请在 t聊 重新选择 Agent 类型。"
}

$releaseTemp = Join-Path $env:TEMP "agenthub-release-$PID"
New-Item -ItemType Directory -Path $releaseTemp -Force | Out-Null
try {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls.exe $releaseTemp /inheritance:r /grant:r "*$($sid):(OI)(CI)F" | Out-Null
} catch {}
$manifestPath = Join-Path $releaseTemp "RELEASE_MANIFEST.json"
$signaturePath = Join-Path $releaseTemp "RELEASE_MANIFEST.sig"
Invoke-WebRequest -Uri "$RawBase/RELEASE_MANIFEST.json" -OutFile $manifestPath -UseBasicParsing
Invoke-WebRequest -Uri "$RawBase/RELEASE_MANIFEST.sig" -OutFile $signaturePath -UseBasicParsing

$node = Get-Command node, node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$python = Get-Command python3, python, python.exe, py, py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($node) {
  $verifier = Join-Path $releaseTemp "verify-release.mjs"
  Invoke-WebRequest -Uri "$RawBase/verify-release.mjs" -OutFile $verifier -UseBasicParsing
  $actualVerifierHash = (Get-FileHash -Path $verifier -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualVerifierHash -ne $NodeVerifierSha256) { throw "发布校验器校验失败，已停止接入。" }
  & ([string]$node.Source) $verifier --public-key $ReleasePublicKey --manifest $manifestPath --signature $signaturePath | Out-Null
} elseif ($python) {
  $verifier = Join-Path $releaseTemp "verify-release.py"
  Invoke-WebRequest -Uri "$RawBase/verify-release.py" -OutFile $verifier -UseBasicParsing
  $actualVerifierHash = (Get-FileHash -Path $verifier -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualVerifierHash -ne $PythonVerifierSha256) { throw "发布校验器校验失败，已停止接入。" }
  $pythonArgs = @($verifier, "--public-key", $ReleasePublicKey, "--manifest", $manifestPath, "--signature", $signaturePath)
  if ([string]$python.Name -like "py*") { $pythonArgs = @("-3") + $pythonArgs }
  & ([string]$python.Source) @pythonArgs | Out-Null
} else {
  throw "需要 Agent 运行环境提供的 Node 或 Python 才能验证签名发布。"
}
if ($LASTEXITCODE -ne 0) { throw "发布清单签名无效，已停止接入。" }

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$signedInstallerHash = [string]$manifest.sha256.'install-agent.ps1'
$signedConnectorHash = if ([string]$invite.agent_kind -eq "openclaw") {
  [string]$manifest.sha256.'agenthub_openclaw_connector.mjs'
} elseif ([string]$invite.agent_kind -eq "hermes") {
  [string]$manifest.sha256.'agenthub_hermes_connector.py'
} elseif ([string]$invite.agent_kind -eq "claude-code") {
  [string]$manifest.sha256.'agenthub_claude_code_connector.mjs'
} else {
  [string]$manifest.sha256.'agenthub_codex_connector.mjs'
}
$signedMcpHash = [string]$manifest.sha256.'agenthub_mcp_server.py'
$signedSupportConnectorHash = if ([string]$invite.agent_kind -eq "codex") { [string]$manifest.sha256.'agenthub_claude_code_connector.mjs' } else { "" }
$inviteInstallerHash = [string]$invite.bootstrap.checksums.install_agent_ps1
$inviteConnectorHash = if ([string]$invite.agent_kind -eq "openclaw") {
  [string]$invite.bootstrap.checksums.openclaw_connector
} elseif ([string]$invite.agent_kind -eq "hermes") {
  [string]$invite.bootstrap.checksums.hermes_connector
} elseif ([string]$invite.agent_kind -eq "claude-code") {
  [string]$invite.bootstrap.checksums.claude_code_connector
} else {
  [string]$invite.bootstrap.checksums.codex_connector
}
$inviteMcpHash = [string]$invite.bootstrap.checksums.mcp_server
$inviteSupportConnectorHash = if ([string]$invite.agent_kind -eq "codex") { [string]$invite.bootstrap.checksums.claude_code_connector } else { "" }
if (
  -not $signedInstallerHash -or -not $signedConnectorHash -or -not $signedMcpHash -or
  $inviteInstallerHash -ne $signedInstallerHash -or
  $inviteConnectorHash -ne $signedConnectorHash -or
  $inviteSupportConnectorHash -ne $signedSupportConnectorHash -or
  $inviteMcpHash -ne $signedMcpHash
) {
  throw "邀请与签名发布清单不一致，已停止接入。"
}

$installer = Join-Path $releaseTemp "install-agent.ps1"
Invoke-WebRequest -Uri "$RawBase/install-agent.ps1" -OutFile $installer -UseBasicParsing
$expectedHash = $signedInstallerHash
if ($expectedHash) {
  $actualHash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    throw "安装脚本校验失败，已停止接入。"
  }
}
$connectorHash = $signedConnectorHash
$mcpServerHash = $signedMcpHash
$supportConnectorHash = $signedSupportConnectorHash
if (-not $connectorHash -or -not $mcpServerHash) {
  throw "邀请缺少连接器校验值，已停止接入。"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
  -RawBase $RawBase `
  -InviteUrl $InviteUrl `
  -ConnectMode client `
  -AgentId ([string]$invite.suggested_agent_id) `
  -Role ([string]$invite.role) `
  -AgentKind ([string]$invite.agent_kind) `
  -ConnectorSha256 $connectorHash `
  -SupportConnectorSha256 $supportConnectorHash `
  -McpServerSha256 $mcpServerHash `
  -Restart `
  -Autostart

Write-Host ""
Write-Host "连接请求已发送。请回到 t聊，点击「允许并开始聊天」。" -ForegroundColor Green
Remove-Item -Path $releaseTemp -Recurse -Force -ErrorAction SilentlyContinue
