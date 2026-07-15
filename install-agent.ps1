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
  [ValidateSet("openclaw", "hermes", "other")]
  [string]$AgentKind = "other",
  [string]$InstallDir = "",
  [string]$RuntimeInstance = "",
  [switch]$Restart,
  [switch]$Autostart,
  [switch]$EnableMcp
)

$ErrorActionPreference = "Stop"
$RawBase = $RawBase.TrimEnd("/")

function Normalize-Url([string]$Value) {
  return $Value.Trim().TrimEnd("/")
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
    Invoke-RestMethod -Method Post -Uri "$HubUrl/api/agents/$AgentId/connection-report" `
      -Headers @{Authorization = "Bearer $Token"} -ContentType "application/json" `
      -Body ($body | ConvertTo-Json -Depth 8) -TimeoutSec 20 | Out-Null
  } catch {}
}

if ($InviteUrl) {
  try {
    $inviteResponse = Invoke-RestMethod -Method Get -Uri $InviteUrl -TimeoutSec 30
  } catch {
    throw "无法读取邀请：$($_.Exception.Message)"
  }
  if (-not $inviteResponse.ok) { throw ([string]$inviteResponse.error) }
  $Invite = $inviteResponse.invite
  if ($Invite.expired) { throw "邀请已过期，请在 Agent Hub 重新生成。" }
  if ([string]$Invite.status -notin @("open", "claimed", "approved")) { throw "邀请不可用：$($Invite.status)" }
  if (-not $AgentId) { $AgentId = [string]$Invite.suggested_agent_id }
  if (-not $AgentName -and [string]$Invite.name_hint -notin @("OpenClaw", "Hermes")) {
    $AgentName = [string]$Invite.name_hint
  }
  if ($AgentKind -eq "other") { $AgentKind = [string]$Invite.agent_kind }
  if (-not $RuntimeInstance) { $RuntimeInstance = [string]$Invite.runtime_instance_hint }
  if (-not $HubUrl) { $HubUrl = [string]$Invite.hub_url }
} elseif (-not $HubUrl -or -not $Token -or -not $AgentId) {
  throw "请提供 InviteUrl；旧版高级接入需要 HubUrl、Token 和 AgentId。"
}

if ($AgentKind -notin @("openclaw", "hermes")) {
  throw "自动连接目前支持 OpenClaw 或 Hermes。"
}
if (-not $AgentName) {
  $kindLabel = if ($AgentKind -eq "hermes") { "Hermes" } else { "OpenClaw" }
  $AgentName = "$env:COMPUTERNAME $kindLabel"
}
$HubUrl = Normalize-Url $HubUrl
if (-not $InstallDir) { $InstallDir = Join-Path (Join-Path $env:USERPROFILE ".agent-hub") $AgentId }
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$InstallDir = [string](Resolve-Path $InstallDir)
$backupNames = @(
  "agenthub.json",
  "agenthub-mcp-config.json",
  "start-agenthub.ps1",
  "stop-agenthub.ps1",
  "agenthub_openclaw_connector.mjs",
  "agenthub_hermes_connector.py"
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
} else {
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

if (-not $Token) { throw "Agent Hub 没有返回设备凭据。" }
$connectorName = if ($AgentKind -eq "openclaw") { "agenthub_openclaw_connector.mjs" } else { "agenthub_hermes_connector.py" }
$connectorFile = Join-Path $InstallDir $connectorName
$mcpServerFile = Join-Path $InstallDir "agenthub_mcp_server.py"
Download-File "$RawBase/$connectorName" $connectorFile
Download-File "$RawBase/agenthub_mcp_server.py" $mcpServerFile

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

$startScript = Join-Path $InstallDir "start-agenthub.ps1"
$stopScript = Join-Path $InstallDir "stop-agenthub.ps1"
$pidFile = Join-Path $InstallDir "connector.pid"
$stdoutLog = Join-Path $InstallDir "connector.log"
$stderrLog = Join-Path $InstallDir "connector-error.log"

@'
param([switch]$Foreground)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $here "agenthub.json") -Raw | ConvertFrom-Json
$pidFile = Join-Path $here "connector.pid"
if (Test-Path $pidFile) {
  $oldPid = [int](Get-Content $pidFile -Raw)
  if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { exit 0 }
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
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
if ($config.agent_kind -eq "openclaw") { $env:OPENCLAW_BIN = [string]$config.runtime_path }
else { $env:HERMES_BIN = [string]$config.runtime_path }
$arguments = @([string]$config.connector_file)
if ($Foreground) {
  & ([string]$config.runner_path) @arguments
  exit $LASTEXITCODE
}
$process = Start-Process -FilePath ([string]$config.runner_path) -ArgumentList $arguments -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $here "connector.log") -RedirectStandardError (Join-Path $here "connector-error.log")
Set-Content -Path $pidFile -Value $process.Id -Encoding ASCII
$process.WaitForExit()
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
exit $process.ExitCode
'@ | Set-Content -Path $startScript -Encoding UTF8

@'
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $here "connector.pid"
if (-not (Test-Path $pidFile)) { exit 0 }
$connectorPid = [int](Get-Content $pidFile -Raw)
Stop-Process -Id $connectorPid -Force -ErrorAction SilentlyContinue
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
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
}

$mcpStatus = if ($McpRunnerPath) { if ($EnableMcp) { "config_ready" } else { "optional" } } else { "runtime_unavailable" }
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
  if (Test-Path $pidFile) {
    Send-ConnectionReport "awaiting_approval" @{connector_status = "running"; service_status = "running"; approval_status = "pending"}
  } else {
    Send-ConnectionReport "failed" @{connector_status = "stopped"; service_status = "failed"; last_error_code = "CONNECTOR_START_FAILED"; last_error = "连接器未能保持运行，请查看 connector-error.log。"}
    throw "连接器启动失败，请查看 $stderrLog"
  }
}

Write-Host ""
Write-Host "Agent 已完成自动配置并提交连接请求。" -ForegroundColor Green
Write-Host "请回到 Agent Hub 点击「允许并开始聊天」。"
Write-Host "诊断目录：$InstallDir"
if ($EnableMcp -and $McpRunnerPath) { Write-Host "MCP 配置已生成：$mcpConfigFile" }
