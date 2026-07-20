param(
  [string]$HubUrl = "",
  [string]$Token = "",
  [string]$RawBase = "https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main",
  [string]$InviteUrl = "",
  [ValidateSet("mcp", "client")]
  [string]$ConnectMode = "client",
  [string]$AgentId = "",
  [string]$AgentName = "",
  [string]$Role = "agent",
  [ValidateSet("openclaw", "hermes", "claude-code", "codex", "other")]
  [string]$AgentKind = "other",
  [string]$InstallDir = "",
  [string]$RuntimeInstance = "",
  [string]$ConnectorSha256 = "",
  [string]$SupportConnectorSha256 = "",
  [string]$McpServerSha256 = "",
  [switch]$Restart,
  [switch]$Autostart,
  [switch]$EnableMcp
)

$ErrorActionPreference = "Stop"
$RawBase = $RawBase.TrimEnd("/")

function Normalize-Url([string]$Value) {
  return $Value.Trim().TrimEnd("/")
}

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

function Assert-AgentHubPrivateUrl([string]$Value, [switch]$Invite) {
  try { $uri = [System.Uri]$Value } catch { throw "t聊 地址格式无效。" }
  $path = $uri.AbsolutePath.TrimEnd("/")
  $pathValid = if ($Invite) {
    $path -match '^/(api|agent/v1)/invites/[A-Za-z0-9_-]+$'
  } else {
    -not $path
  }
  if (
    -not $uri.IsAbsoluteUri -or
    $uri.Scheme -notin @("http", "https") -or
    $uri.UserInfo -or
    $uri.Query -or
    $uri.Fragment -or
    -not $pathValid
  ) {
    throw "t聊 地址格式不安全。"
  }
  $hostName = $uri.DnsSafeHost.Trim("[", "]")
  $parsedAddress = $null
  if ([System.Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress)) {
    $addresses = @($parsedAddress)
  } else {
    try { $addresses = @([System.Net.Dns]::GetHostAddresses($hostName)) }
    catch { throw "t聊 主机无法解析：$($_.Exception.Message)" }
  }
  if ($addresses.Count -eq 0 -or @($addresses | Where-Object { -not (Test-AgentHubPrivateAddress $_) }).Count -gt 0) {
    throw "t聊 必须位于本机、可信私网或 Tailscale 网络。"
  }
  return $uri
}

function Protect-AgentHubPath([string]$Path, [switch]$Directory) {
  try {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $grant = if ($Directory) { "*$($sid):(OI)(CI)F" } else { "*$($sid):F" }
    if ($Directory) {
      & icacls.exe $Path /inheritance:r /grant:r $grant /T /C | Out-Null
    } else {
      & icacls.exe $Path /inheritance:r /grant:r $grant | Out-Null
    }
  } catch {}
}

function Resolve-CommandPath([string[]]$Names, [string[]]$ExtraPaths = @()) {
  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
      $candidate = $command.Source
      if (-not $candidate) { $candidate = $command.Path }
      if (-not $candidate) { $candidate = $command.Definition }
      if ($candidate) { return [string]$candidate }
    }
  }
  foreach ($candidate in $ExtraPaths) {
    if ($candidate -and (Test-Path $candidate)) { return [string](Resolve-Path $candidate) }
  }
  return ""
}

function Download-File([string]$Url, [string]$OutFile) {
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Assert-FileHash([string]$Path, [string]$ExpectedHash) {
  if (-not $ExpectedHash) {
    Remove-Item -Force $Path -ErrorAction SilentlyContinue
    throw "缺少发布文件校验值，已停止安装。"
  }
  $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $ExpectedHash.ToLowerInvariant()) {
    Remove-Item -Force $Path -ErrorAction SilentlyContinue
    throw "发布文件校验失败，已停止安装：$(Split-Path -Leaf $Path)"
  }
}

function Send-InviteProgress([string]$Stage, [string]$Status, [string]$ErrorCode = "", [string]$ErrorText = "", [hashtable]$Diagnostics = @{}) {
  if (-not $InviteUrl) { return }
  $body = @{
    stage = $Stage
    preflight_status = $Status
    last_error_code = $ErrorCode
    last_error = $ErrorText
    diagnostics = $Diagnostics
  } | ConvertTo-Json -Depth 8
  try {
    Invoke-RestMethod -Method Post -Uri "$InviteUrl/progress" -ContentType "application/json" -Body $body -TimeoutSec 20 | Out-Null
  } catch {}
}

function Send-ConnectionReport([string]$Stage, [hashtable]$Extra = @{}) {
  if (-not $Token -or -not $HubUrl -or -not $AgentId) { return }
  $body = @{
    stage = $Stage
    preflight_status = "ok"
    runtime_path = $script:RuntimePath
    runtime_version = $script:RuntimeVersion
    runtime_instance = $script:ResolvedInstance
    environment = "windows-native"
    connector_status = "installed"
    service_status = "starting"
    diagnostics = $script:Diagnostics
  }
  foreach ($key in $Extra.Keys) { $body[$key] = $Extra[$key] }
  try {
    Invoke-RestMethod -Method Post -Uri "$HubUrl/agent/v1/agents/$AgentId/connection-report" `
      -Headers @{Authorization = "Bearer $Token"} -ContentType "application/json" `
      -Body ($body | ConvertTo-Json -Depth 8) -TimeoutSec 20 | Out-Null
  } catch {}
}

function New-DeviceKeyPayload {
  $previousInstallDir = [Environment]::GetEnvironmentVariable("AGENT_HUB_INSTALL_DIR", "Process")
  try {
    $env:AGENT_HUB_INSTALL_DIR = $InstallDir
    $output = @(& $RunnerPath $connectorFile keygen 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw (($output | Out-String).Trim())
    }
    $key = (($output -join "`n").Trim() | ConvertFrom-Json)
    if (-not [string]$key.key_id -or -not [string]$key.public_key) {
      throw "连接器没有返回有效的设备公钥。"
    }
    return @{
      key_id = [string]$key.key_id
      public_key = [string]$key.public_key
    }
  } finally {
    if ($null -eq $previousInstallDir) {
      Remove-Item Env:AGENT_HUB_INSTALL_DIR -ErrorAction SilentlyContinue
    } else {
      $env:AGENT_HUB_INSTALL_DIR = $previousInstallDir
    }
  }
}

function Register-DeviceKey([hashtable]$Payload) {
  try {
    $response = Invoke-RestMethod -Method Post -Uri "$HubUrl/agent/v1/agents/$AgentId/device-key" `
      -Headers @{Authorization = "Bearer $Token"} -ContentType "application/json" `
      -Body ($Payload | ConvertTo-Json -Compress) -TimeoutSec 20
  } catch {
    throw "设备公钥绑定失败，连接器不会以未签名模式继续运行：$($_.Exception.Message)"
  }
  if (-not $response.ok -or -not $response.signature_required) {
    throw "t聊 未确认设备签名，已停止安装。"
  }
}

if ($InviteUrl) {
  $InviteUrl = (Assert-AgentHubPrivateUrl $InviteUrl -Invite).AbsoluteUri.TrimEnd("/")
  try {
    $inviteResponse = Invoke-RestMethod -Method Get -Uri $InviteUrl -TimeoutSec 30
  } catch {
    throw "无法读取邀请：$($_.Exception.Message)"
  }
  if (-not $inviteResponse.ok) { throw ([string]$inviteResponse.error) }
  $Invite = $inviteResponse.invite
  if ($Invite.expired) { throw "邀请已过期，请在 t聊 重新生成。" }
  if ([string]$Invite.status -notin @("open", "claimed", "approved")) { throw "邀请不可用：$($Invite.status)" }
  if (-not $AgentId) { $AgentId = [string]$Invite.suggested_agent_id }
  if (-not $AgentName -and [string]$Invite.name_hint -notin @("OpenClaw", "Hermes", "Claude Code", "Codex")) {
    $AgentName = [string]$Invite.name_hint
  }
  if ($AgentKind -eq "other") { $AgentKind = [string]$Invite.agent_kind }
  if (-not $RuntimeInstance) { $RuntimeInstance = [string]$Invite.runtime_instance_hint }
  if (-not $HubUrl) { $HubUrl = [string]$Invite.hub_url }
} elseif (-not $HubUrl -or -not $Token -or -not $AgentId) {
  throw "请提供 InviteUrl；旧版高级接入需要 HubUrl、Token 和 AgentId。"
}

if ($AgentKind -notin @("openclaw", "hermes", "claude-code", "codex")) {
  throw "自动连接目前支持 OpenClaw、Hermes、Claude Code 或 Codex。"
}
if (-not $AgentName) {
  $kindLabel = if ($AgentKind -eq "hermes") { "Hermes" } elseif ($AgentKind -eq "claude-code") { "Claude Code" } elseif ($AgentKind -eq "codex") { "Codex" } else { "OpenClaw" }
  $AgentName = "$env:COMPUTERNAME $kindLabel"
}
$HubUrl = Normalize-Url $HubUrl
$HubUrl = (Assert-AgentHubPrivateUrl $HubUrl).AbsoluteUri.TrimEnd("/")
if (-not $InstallDir) { $InstallDir = Join-Path (Join-Path $env:USERPROFILE ".agent-hub") $AgentId }
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$InstallDir = [string](Resolve-Path $InstallDir)
Protect-AgentHubPath $InstallDir -Directory
$backupNames = @(
  "agenthub.json",
  "agenthub-mcp-config.json",
  "start-agenthub.ps1",
  "stop-agenthub.ps1",
  "agenthub_openclaw_connector.mjs",
  "agenthub_hermes_connector.py",
  "agenthub_claude_code_connector.mjs"
  "agenthub_codex_connector.mjs"
)
$existingFiles = @($backupNames | ForEach-Object { Join-Path $InstallDir $_ } | Where-Object { Test-Path $_ })
if ($existingFiles.Count -gt 0) {
  $backupDir = Join-Path (Join-Path $InstallDir "backups") (Get-Date -Format "yyyyMMdd-HHmmss")
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  foreach ($existingFile in $existingFiles) { Copy-Item -Path $existingFile -Destination $backupDir -Force }
}
$installationIdFile = Join-Path $InstallDir "installation-id"
if (Test-Path $installationIdFile) {
  $InstallationId = (Get-Content $installationIdFile -Raw).Trim()
} elseif ($AgentKind -eq "hermes") {
  $InstallationId = [guid]::NewGuid().ToString("N")
  Set-Content -Path $installationIdFile -Value $InstallationId -Encoding ASCII
}

Send-InviteProgress "preflight" "running"
$RuntimePath = ""
$RuntimeVersion = ""
$ResolvedInstance = if ($RuntimeInstance) { $RuntimeInstance } else { "default" }
$RunnerPath = ""
$Diagnostics = @{agent_kind = $AgentKind; install_dir = $InstallDir}
$selectionRequired = $false

if ($AgentKind -eq "openclaw") {
  $RuntimePath = Resolve-CommandPath @("openclaw", "openclaw.cmd", "openclaw.ps1") @(
    (Join-Path $env:APPDATA "npm\openclaw.cmd"),
    "C:\nodejs\openclaw.cmd",
    (Join-Path $env:LOCALAPPDATA "Programs\OpenClaw\openclaw.exe")
  )
  if (-not $RuntimePath) {
    $message = "没有找到 OpenClaw。请先安装并确认 openclaw --version 可以运行。"
    Send-InviteProgress "failed" "failed" "RUNTIME_NOT_FOUND" $message @{official_install_url = [string]$Invite.official_install_url}
    throw $message
  }
  try { $RuntimeVersion = ((& $RuntimePath --version 2>&1) | Out-String).Trim() } catch { $RuntimeVersion = "unknown" }
  $agentCandidates = @()
  try {
    $agentsRaw = ((& $RuntimePath agents list --json 2>$null) | Out-String).Trim()
    if ($agentsRaw) {
      $agentsJson = $agentsRaw | ConvertFrom-Json
      $items = if ($agentsJson.agents) { @($agentsJson.agents) } else { @($agentsJson) }
      $agentCandidates = @($items | ForEach-Object { if ($_.id) { [string]$_.id } elseif ($_.name) { [string]$_.name } } | Where-Object { $_ })
      if (-not $RuntimeInstance) {
        $preferred = $items | Where-Object { $_.default -eq $true -or $_.isDefault -eq $true } | Select-Object -First 1
        if (-not $preferred) { $preferred = $items | Where-Object { $_.id -eq "main" } | Select-Object -First 1 }
        if ($preferred) {
          if ($preferred.id) { $ResolvedInstance = [string]$preferred.id }
          else { $ResolvedInstance = [string]$preferred.name }
        }
        elseif ($agentCandidates.Count -eq 1) { $ResolvedInstance = $agentCandidates[0] }
        elseif ($agentCandidates.Count -gt 1) {
          $ResolvedInstance = $agentCandidates[0]
          $selectionRequired = $true
        }
      }
    }
  } catch {}
  if (-not $ResolvedInstance -or $ResolvedInstance -eq "default") { $ResolvedInstance = "main" }
  $nodeExtra = @(
    (Join-Path (Split-Path $RuntimePath -Parent) "node.exe"),
    "C:\nodejs\node.exe",
    (Join-Path $env:ProgramFiles "nodejs\node.exe")
  )
  $RunnerPath = Resolve-CommandPath @("node", "node.exe") $nodeExtra
  if (-not $RunnerPath) {
    $message = "已找到 OpenClaw，但没有找到它使用的 Node 运行环境。"
    Send-InviteProgress "failed" "failed" "RUNTIME_HOST_NOT_FOUND" $message @{runtime_path = $RuntimePath}
    throw $message
  }
  $Diagnostics.runtime_candidates = $agentCandidates
  $Diagnostics.runtime_selection_required = $selectionRequired
  $Diagnostics.node_path = $RunnerPath
} else {
  $RuntimePath = Resolve-CommandPath @("hermes", "hermes.exe", "hermes.cmd") @(
    (Join-Path $env:LOCALAPPDATA "hermes\hermes.exe"),
    (Join-Path $env:USERPROFILE ".local\bin\hermes.exe")
  )
  if (-not $RuntimePath) {
    $message = "没有找到 Hermes。请先安装并确认 hermes --version 可以运行。"
    Send-InviteProgress "failed" "failed" "RUNTIME_NOT_FOUND" $message @{official_install_url = [string]$Invite.official_install_url}
    throw $message
  }
  try { $RuntimeVersion = ((& $RuntimePath --version 2>&1) | Out-String).Trim() } catch { $RuntimeVersion = "unknown" }
  $profileCandidates = @()
  if (-not $RuntimeInstance) {
    $profilesRaw = ""
    try { $profilesRaw = ((& $RuntimePath profile list --json 2>$null) | Out-String).Trim() } catch {}
    if (-not $profilesRaw) {
      try { $profilesRaw = ((& $RuntimePath profiles list --json 2>$null) | Out-String).Trim() } catch {}
    }
    if ($profilesRaw) {
      try {
        $profilesJson = $profilesRaw | ConvertFrom-Json
        $profiles = if ($profilesJson.profiles) { @($profilesJson.profiles) } else { @($profilesJson) }
        $profileCandidates = @($profiles | ForEach-Object { if ($_.id) { [string]$_.id } elseif ($_.name) { [string]$_.name } } | Where-Object { $_ })
        $preferred = $profiles | Where-Object { $_.active -eq $true -or $_.default -eq $true -or $_.isDefault -eq $true } | Select-Object -First 1
        if (-not $preferred) { $preferred = $profiles | Where-Object { $_.id -eq "default" -or $_.name -eq "default" } | Select-Object -First 1 }
        if ($preferred) {
          if ($preferred.id) { $ResolvedInstance = [string]$preferred.id }
          else { $ResolvedInstance = [string]$preferred.name }
        }
        elseif ($profileCandidates.Count -eq 1) { $ResolvedInstance = $profileCandidates[0] }
        elseif ($profileCandidates.Count -gt 1) {
          $ResolvedInstance = $profileCandidates[0]
          $selectionRequired = $true
        }
      } catch {}
    }
  }
  if (-not $ResolvedInstance) { $ResolvedInstance = "default" }
  $runtimeDirectory = Split-Path $RuntimePath -Parent
  $pythonCandidates = @(
    (Join-Path $runtimeDirectory "python.exe"),
    (Join-Path $runtimeDirectory "python3.exe"),
    (Join-Path $runtimeDirectory "..\python.exe"),
    (Join-Path $env:LOCALAPPDATA "hermes\venv\Scripts\python.exe"),
    (Join-Path $env:LOCALAPPDATA "hermes\.venv\Scripts\python.exe"),
    (Join-Path $env:USERPROFILE ".hermes\venv\Scripts\python.exe"),
    (Join-Path $env:USERPROFILE ".hermes\hermes-agent\venv\Scripts\python.exe")
  )
  $RunnerPath = Resolve-CommandPath @() $pythonCandidates
  if (-not $RunnerPath) {
    $message = "已找到 Hermes，但无法定位 Hermes 自带的 Python 环境。请运行 hermes doctor 后重试。"
    Send-InviteProgress "failed" "failed" "RUNTIME_HOST_NOT_FOUND" $message @{runtime_path = $RuntimePath}
    throw $message
  }
  $Diagnostics.hermes_python = $RunnerPath
  $Diagnostics.profile_candidates = $profileCandidates
  $Diagnostics.runtime_candidates = $profileCandidates
  $Diagnostics.runtime_selection_required = $selectionRequired
} elseif ($AgentKind -eq "claude-code") {
  $RuntimePath = Resolve-CommandPath @("claude", "claude.exe", "claude.cmd", "claude.ps1") @(
    (Join-Path $env:APPDATA "npm\claude.cmd"),
    (Join-Path $env:USERPROFILE ".local\bin\claude.exe"),
    (Join-Path $env:USERPROFILE ".claude\local\claude.exe")
  )
  if (-not $RuntimePath) {
    $message = "没有找到 Claude Code。请先安装并确认 claude --version 可以运行。"
    Send-InviteProgress "failed" "failed" "RUNTIME_NOT_FOUND" $message @{official_install_url = [string]$Invite.official_install_url}
    throw $message
  }
  try { $RuntimeVersion = ((& $RuntimePath --version 2>&1) | Out-String).Trim() } catch { $RuntimeVersion = "unknown" }
  $nodeExtra = @(
    (Join-Path (Split-Path $RuntimePath -Parent) "node.exe"),
    (Join-Path $env:ProgramFiles "nodejs\node.exe"),
    "C:\nodejs\node.exe"
  )
  $RunnerPath = Resolve-CommandPath @("node", "node.exe") $nodeExtra
  if (-not $RunnerPath) {
    $message = "已找到 Claude Code，但没有找到用于运行 t聊连接器的 Node。"
    Send-InviteProgress "failed" "failed" "RUNTIME_HOST_NOT_FOUND" $message @{runtime_path = $RuntimePath}
    throw $message
  }
  $ResolvedInstance = if ($RuntimeInstance) { $RuntimeInstance } else { "default" }
  $Diagnostics.runtime_candidates = @("default")
  $Diagnostics.runtime_selection_required = $false
  $Diagnostics.node_path = $RunnerPath
} else {
  $RuntimePath = Resolve-CommandPath @("codex", "codex.exe", "codex.cmd", "codex.ps1") @(
    (Join-Path $env:APPDATA "npm\codex.cmd"),
    (Join-Path $env:USERPROFILE ".local\bin\codex.exe")
  )
  if (-not $RuntimePath) {
    $message = "没有找到 Codex。请先安装并确认 codex --version 可以运行。"
    Send-InviteProgress "failed" "failed" "RUNTIME_NOT_FOUND" $message @{official_install_url = [string]$Invite.official_install_url}
    throw $message
  }
  try { $RuntimeVersion = ((& $RuntimePath --version 2>&1) | Out-String).Trim() } catch { $RuntimeVersion = "unknown" }
  $nodeExtra = @(
    (Join-Path (Split-Path $RuntimePath -Parent) "node.exe"),
    (Join-Path $env:ProgramFiles "nodejs\node.exe"),
    "C:\nodejs\node.exe"
  )
  $RunnerPath = Resolve-CommandPath @("node", "node.exe") $nodeExtra
  if (-not $RunnerPath) {
    $message = "已找到 Codex，但没有找到用于运行 t聊连接器的 Node。"
    Send-InviteProgress "failed" "failed" "RUNTIME_HOST_NOT_FOUND" $message @{runtime_path = $RuntimePath}
    throw $message
  }
  $ResolvedInstance = if ($RuntimeInstance) { $RuntimeInstance } else { "default" }
  $Diagnostics.runtime_candidates = @("default")
  $Diagnostics.runtime_selection_required = $false
  $Diagnostics.node_path = $RunnerPath
}

$Diagnostics.runtime_path = $RuntimePath
$Diagnostics.runtime_version = $RuntimeVersion
$Diagnostics.runtime_instance = $ResolvedInstance
Send-InviteProgress "claiming" "ok" "" "" $Diagnostics

if (-not $Token) {
  $claimBody = @{
    agent_id = $AgentId
    name = $AgentName
    role = $Role
    platform = "windows"
    mode = "client"
    agent_kind = $AgentKind
    device_label = $env:COMPUTERNAME
    installation_id = $InstallationId
    runtime_path = $RuntimePath
    runtime_version = $RuntimeVersion
    runtime_instance = $ResolvedInstance
    environment = "windows-native"
    connector_status = "installing"
    service_status = "starting"
    capabilities = @("chat", "tasks", "mentions", "persistent_sessions")
    diagnostics = $Diagnostics
  } | ConvertTo-Json -Depth 8
  try {
    $claim = Invoke-RestMethod -Method Post -Uri "$InviteUrl/claim" -ContentType "application/json" -Body $claimBody -TimeoutSec 30
  } catch {
    Send-InviteProgress "failed" "failed" "CLAIM_FAILED" $_.Exception.Message $Diagnostics
    throw "连接请求提交失败：$($_.Exception.Message)"
  }
  $AgentId = [string]$claim.agent_id
  $Token = [string]$claim.token
  $HubUrl = Normalize-Url ([string]$claim.hub_url)
  $HubUrls = [string]$claim.hub_urls
} else {
  $HubUrls = $HubUrl
}

if (-not $Token) { throw "t聊 没有返回设备凭据。" }
$HubUrl = (Assert-AgentHubPrivateUrl $HubUrl).AbsoluteUri.TrimEnd("/")
foreach ($endpoint in ([string]$HubUrls -split ",")) {
  if ($endpoint.Trim()) { [void](Assert-AgentHubPrivateUrl (Normalize-Url $endpoint)) }
}
$connectorName = if ($AgentKind -eq "openclaw") { "agenthub_openclaw_connector.mjs" } elseif ($AgentKind -eq "hermes") { "agenthub_hermes_connector.py" } elseif ($AgentKind -eq "claude-code") { "agenthub_claude_code_connector.mjs" } else { "agenthub_codex_connector.mjs" }
$connectorFile = Join-Path $InstallDir $connectorName
$mcpServerFile = Join-Path $InstallDir "agenthub_mcp_server.py"
if ($InviteUrl) {
  if (-not $ConnectorSha256) {
    $ConnectorSha256 = if ($AgentKind -eq "openclaw") {
      [string]$Invite.bootstrap.checksums.openclaw_connector
    } elseif ($AgentKind -eq "hermes") {
      [string]$Invite.bootstrap.checksums.hermes_connector
    } elseif ($AgentKind -eq "claude-code") {
      [string]$Invite.bootstrap.checksums.claude_code_connector
    } else {
      [string]$Invite.bootstrap.checksums.codex_connector
    }
  }
  if ($AgentKind -eq "codex" -and -not $SupportConnectorSha256) {
    $SupportConnectorSha256 = [string]$Invite.bootstrap.checksums.claude_code_connector
  }
  if (-not $McpServerSha256) {
    $McpServerSha256 = [string]$Invite.bootstrap.checksums.mcp_server
  }
}
Download-File "$RawBase/$connectorName" $connectorFile
Assert-FileHash $connectorFile $ConnectorSha256
if ($AgentKind -eq "codex") {
  $supportConnectorFile = Join-Path $InstallDir "agenthub_claude_code_connector.mjs"
  Download-File "$RawBase/agenthub_claude_code_connector.mjs" $supportConnectorFile
  Assert-FileHash $supportConnectorFile $SupportConnectorSha256
}
Download-File "$RawBase/agenthub_mcp_server.py" $mcpServerFile
Assert-FileHash $mcpServerFile $McpServerSha256

$configFile = Join-Path $InstallDir "agenthub.json"
$config = [ordered]@{
  hub_url = $HubUrl
  hub_urls = $HubUrls
  token = $Token
  agent_id = $AgentId
  agent_name = $AgentName
  role = $Role
  agent_kind = $AgentKind
  runtime_path = $RuntimePath
  runtime_version = $RuntimeVersion
  runtime_instance = $ResolvedInstance
  runner_path = $RunnerPath
  connector_file = $connectorFile
  install_dir = $InstallDir
}
$config | ConvertTo-Json -Depth 6 | Set-Content -Path $configFile -Encoding UTF8
Protect-AgentHubPath $configFile

$startScript = Join-Path $InstallDir "start-agenthub.ps1"
$stopScript = Join-Path $InstallDir "stop-agenthub.ps1"
$pidFile = Join-Path $InstallDir "connector.pid"
$supervisorFile = Join-Path $InstallDir "supervisor.pid"
$stdoutLog = Join-Path $InstallDir "connector.log"
$stderrLog = Join-Path $InstallDir "connector-error.log"

@'
param([switch]$Foreground)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $here "agenthub.json") -Raw | ConvertFrom-Json
$pidFile = Join-Path $here "connector.pid"
$supervisorFile = Join-Path $here "supervisor.pid"
$stopMarker = Join-Path $here "stop.requested"
if (-not $Foreground -and (Test-Path $supervisorFile)) {
  $oldPid = [int](Get-Content $supervisorFile -Raw)
  if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { exit 0 }
  Remove-Item $supervisorFile -Force -ErrorAction SilentlyContinue
}
Remove-Item $stopMarker -Force -ErrorAction SilentlyContinue
$env:AGENT_HUB_URL = [string]$config.hub_url
$env:AGENT_HUB_URLS = [string]$config.hub_urls
$env:AGENT_HUB_TOKEN = [string]$config.token
$env:AGENT_HUB_ID = [string]$config.agent_id
$env:AGENT_HUB_NAME = [string]$config.agent_name
$env:AGENT_HUB_ROLE = [string]$config.role
$env:AGENT_HUB_KIND = [string]$config.agent_kind
$env:AGENT_HUB_RUNTIME_INSTANCE = [string]$config.runtime_instance
$env:AGENT_HUB_RUNTIME_VERSION = [string]$config.runtime_version
$env:AGENT_HUB_INSTALL_DIR = $here
$env:AGENT_HUB_SERVICE_MODE = if ($Foreground) { "foreground" } else { "windows-task-supervisor" }
if ($config.agent_kind -eq "openclaw") { $env:OPENCLAW_BIN = [string]$config.runtime_path }
elseif ($config.agent_kind -eq "hermes") { $env:HERMES_BIN = [string]$config.runtime_path }
elseif ($config.agent_kind -eq "claude-code") { $env:CLAUDE_BIN = [string]$config.runtime_path }
else { $env:CODEX_BIN = [string]$config.runtime_path }
$arguments = @([string]$config.connector_file)
if ($Foreground) {
  & ([string]$config.runner_path) @arguments
  exit $LASTEXITCODE
}
Set-Content -Path $supervisorFile -Value $PID -Encoding ASCII
$delay = 2
try {
  while (-not (Test-Path $stopMarker)) {
    $process = Start-Process -FilePath ([string]$config.runner_path) -ArgumentList $arguments -PassThru -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $here "connector.log") -RedirectStandardError (Join-Path $here "connector-error.log")
    Set-Content -Path $pidFile -Value $process.Id -Encoding ASCII
    $started = Get-Date
    $process.WaitForExit()
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $stopMarker) { break }
    if (((Get-Date) - $started).TotalSeconds -ge 120) { $delay = 2 } else { $delay = [Math]::Min($delay * 2, 60) }
    Start-Sleep -Seconds $delay
  }
} finally {
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  Remove-Item $supervisorFile -Force -ErrorAction SilentlyContinue
}
exit 0
'@ | Set-Content -Path $startScript -Encoding UTF8

@'
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $here "connector.pid"
$supervisorFile = Join-Path $here "supervisor.pid"
$stopMarker = Join-Path $here "stop.requested"
Set-Content -Path $stopMarker -Value (Get-Date -Format o) -Encoding ASCII
if (Test-Path $pidFile) {
  $connectorPid = [int](Get-Content $pidFile -Raw)
  Stop-Process -Id $connectorPid -Force -ErrorAction SilentlyContinue
}
if (Test-Path $supervisorFile) {
  $supervisorPid = [int](Get-Content $supervisorFile -Raw)
  Stop-Process -Id $supervisorPid -Force -ErrorAction SilentlyContinue
}
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Remove-Item $supervisorFile -Force -ErrorAction SilentlyContinue
'@ | Set-Content -Path $stopScript -Encoding UTF8

$mcpConfigFile = Join-Path $InstallDir "agenthub-mcp-config.json"
$McpRunnerPath = if ($AgentKind -eq "hermes") { $RunnerPath } else { Resolve-CommandPath @("python", "python3", "python.exe") }
if ($McpRunnerPath) {
  $mcpConfig = [ordered]@{
    mcpServers = [ordered]@{
      "agenthub-$AgentId" = [ordered]@{
        command = $McpRunnerPath
        args = @($mcpServerFile)
        env = [ordered]@{
          AGENT_HUB_URL = $HubUrl
          AGENT_HUB_URLS = $HubUrls
          AGENT_HUB_TOKEN = $Token
          AGENT_HUB_ID = $AgentId
          AGENT_HUB_NAME = $AgentName
          AGENT_HUB_ROLE = $Role
        }
      }
    }
  }
  $mcpConfig | ConvertTo-Json -Depth 8 | Set-Content -Path $mcpConfigFile -Encoding UTF8
  Protect-AgentHubPath $mcpConfigFile
}

$mcpStatus = if ($McpRunnerPath) { if ($EnableMcp) { "config_ready" } else { "optional" } } else { "runtime_unavailable" }
$deviceKeyPayload = New-DeviceKeyPayload
Send-ConnectionReport "starting" @{connector_status = "installed"; service_status = "starting"; mcp_status = $mcpStatus}

if ($Autostart) {
  $taskName = "AgentHub-$($AgentId -replace '[^a-zA-Z0-9_-]', '-')"
  $taskCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
  try {
    & schtasks.exe /Create /SC ONLOGON /TN $taskName /TR $taskCommand /F /RL LIMITED 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks exit $LASTEXITCODE" }
  } catch {
    Send-ConnectionReport "starting" @{service_status = "manual"; last_error_code = "AUTOSTART_FAILED"; last_error = $_.Exception.Message}
  }
}

if ($Restart) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript
  Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $startScript
  ) -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 2
  if ((Test-Path $supervisorFile) -and (Test-Path $pidFile)) {
    Send-ConnectionReport "awaiting_approval" @{connector_status = "running"; service_status = "running"; approval_status = "pending"}
  } else {
    Send-ConnectionReport "failed" @{connector_status = "stopped"; service_status = "failed"; last_error_code = "CONNECTOR_START_FAILED"; last_error = "连接器未能保持运行，请查看 connector-error.log。"}
    throw "连接器启动失败，请查看 $stderrLog"
  }
}
Register-DeviceKey $deviceKeyPayload

Write-Host ""
Write-Host "Agent 已完成自动配置并提交连接请求。" -ForegroundColor Green
Write-Host "请回到 t聊 点击「允许并开始聊天」。"
Write-Host "诊断目录：$InstallDir"
if ($EnableMcp -and $McpRunnerPath) { Write-Host "MCP 配置已生成：$mcpConfigFile" }
