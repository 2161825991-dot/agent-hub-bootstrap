param(
  [string]$HubUrl = "",
  [string]$Token = "",
  [string]$RawBase = "https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main",
  [string]$InviteUrl = "",
  [string]$InviteCode = "",
  [ValidateSet("mcp", "client")]
  [string]$ConnectMode = "mcp",
  [string]$AgentId = "openclaw-windows",
  [string]$AgentName = "OpenClaw Windows",
  [string]$Role = "backend",
  [string]$InstallDir = "$env:USERPROFILE\.agent-hub",
  [string]$HubUrls = "",
  [string]$UseCli = "auto",
  [string]$OpenClawBin = "openclaw",
  [switch]$Restart
)

$ErrorActionPreference = "Stop"

function Normalize-Url([string]$Value) {
  return $Value.Trim().TrimEnd("/")
}

function Download-File([string]$Url, [string]$OutFile) {
  Write-Host "Downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

$RawBase = Normalize-Url $RawBase
if ($InviteUrl) {
  $InviteUri = [Uri]$InviteUrl
  if ($InviteUri.Scheme -notin @("http", "https")) {
    throw "InviteUrl must use http or https."
  }
  if (-not $HubUrl) {
    $HubUrl = $InviteUri.GetLeftPart([System.UriPartial]::Authority)
  }
  if (-not $InviteCode) {
    $InviteCode = $InviteUri.Segments[-1].Trim("/")
  }
}
if (-not $HubUrl) {
  throw "Provide -InviteUrl, or provide both -HubUrl and -Token for advanced legacy setup."
}
$HubUrl = Normalize-Url $HubUrl
if (-not $HubUrls) {
  $HubUrls = $HubUrl
}
if (-not $Token -and -not $InviteCode) {
  throw "Missing Token or InviteCode."
}
if ($InviteUrl -and $ConnectMode -eq "client" -and -not $Token) {
  $claimBody = @{
    agent_id = $AgentId
    name = $AgentName
    role = $Role
    platform = "windows"
    mode = "client"
    device_label = $env:COMPUTERNAME
  } | ConvertTo-Json
  Write-Host "Claiming one-time Agent Hub invite for background client mode..."
  $claim = Invoke-RestMethod -Method Post -Uri "$InviteUrl/claim" -ContentType "application/json" -Body $claimBody
  $Token = [string]$claim.token
  if ($claim.hub_url) { $HubUrl = Normalize-Url ([string]$claim.hub_url) }
  if ($claim.hub_urls) { $HubUrls = [string]$claim.hub_urls }
  if (-not $Token) { throw "Invite claim succeeded without a Token." }
}
if ($UseCli -eq "auto") {
  if (Get-Command $OpenClawBin -ErrorAction SilentlyContinue) {
    $UseCli = "1"
  } else {
    $UseCli = "0"
    Write-Host "OpenClaw CLI not found: $OpenClawBin"
    Write-Host "The client will connect to Agent Hub only. Re-run with -UseCli 1 -OpenClawBin path\\to\\openclaw.exe after installing OpenClaw CLI."
  }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$clientFiles = @(
  "openclaw_agent.py",
  "remote_agent_example.py",
  "agenthub_mcp_server.py"
)

foreach ($file in $clientFiles) {
  Download-File "$RawBase/$file" (Join-Path $InstallDir $file)
}

$startScript = Join-Path $InstallDir "start-openclaw-agent.ps1"
$stopScript = Join-Path $InstallDir "stop-openclaw-agent.ps1"
$envFile = Join-Path $InstallDir "agenthub.env"
$mcpConfigFile = Join-Path $InstallDir "agenthub-mcp-config.json"

@"
AGENT_HUB_URL=$HubUrl
AGENT_HUB_URLS=$HubUrls
AGENT_HUB_TOKEN=$Token
AGENT_HUB_INVITE_URL=$InviteUrl
AGENT_HUB_INVITE_CODE=$InviteCode
AGENT_HUB_CONNECT_MODE=$ConnectMode
AGENT_HUB_ID=$AgentId
AGENT_HUB_NAME=$AgentName
AGENT_HUB_ROLE=$Role
AGENT_HUB_TIMEOUT=10
AGENT_HUB_RECONNECT_INTERVAL=5
OPENCLAW_USE_CLI=$UseCli
OPENCLAW_BIN=$OpenClawBin
"@ | Set-Content -Path $envFile -Encoding UTF8

@"
`$ErrorActionPreference = "Stop"
Set-Location "$InstallDir"
`$env:AGENT_HUB_URL="$HubUrl"
`$env:AGENT_HUB_URLS="$HubUrls"
`$env:AGENT_HUB_TOKEN="$Token"
`$env:AGENT_HUB_INVITE_URL="$InviteUrl"
`$env:AGENT_HUB_INVITE_CODE="$InviteCode"
`$env:AGENT_HUB_CONNECT_MODE="$ConnectMode"
`$env:AGENT_HUB_ID="$AgentId"
`$env:AGENT_HUB_NAME="$AgentName"
`$env:AGENT_HUB_ROLE="$Role"
`$env:AGENT_HUB_TIMEOUT="10"
`$env:AGENT_HUB_RECONNECT_INTERVAL="5"
`$env:OPENCLAW_USE_CLI="$UseCli"
`$env:OPENCLAW_BIN="$OpenClawBin"
if (-not `$env:AGENT_HUB_TOKEN) {
  throw "Invite has not been claimed yet. Configure MCP and call agenthub_register_from_invite first."
}
python openclaw_agent.py
"@ | Set-Content -Path $startScript -Encoding UTF8

@"
`$ErrorActionPreference = "Continue"
`$matches = Get-CimInstance Win32_Process |
  Where-Object { `$_.CommandLine -and `$_.CommandLine -like "*openclaw_agent.py*" }

if (-not `$matches) {
  Write-Host "No running Agent Hub OpenClaw client found."
  exit 0
}

foreach (`$proc in `$matches) {
  Write-Host "Stopping Agent Hub OpenClaw client PID `$(`$proc.ProcessId)"
  Stop-Process -Id `$proc.ProcessId -Force
}
"@ | Set-Content -Path $stopScript -Encoding UTF8

$mcpEnv = [ordered]@{
  AGENT_HUB_URL = $HubUrl
  AGENT_HUB_URLS = $HubUrls
  AGENT_HUB_ID = $AgentId
  AGENT_HUB_NAME = $AgentName
  AGENT_HUB_ROLE = $Role
  AGENT_HUB_CONNECT_MODE = $ConnectMode
}
if ($Token) { $mcpEnv.AGENT_HUB_TOKEN = $Token }
if ($InviteUrl) { $mcpEnv.AGENT_HUB_INVITE_URL = $InviteUrl }
if ($InviteCode) { $mcpEnv.AGENT_HUB_INVITE_CODE = $InviteCode }

$mcpConfig = [ordered]@{
  mcpServers = [ordered]@{
    agenthub = [ordered]@{
      command = "python"
      args = @((Join-Path $InstallDir "agenthub_mcp_server.py"))
      env = $mcpEnv
    }
  }
}
$mcpConfig | ConvertTo-Json -Depth 8 | Set-Content -Path $mcpConfigFile -Encoding UTF8

Write-Host ""
Write-Host "Agent Hub client installed to: $InstallDir"
Write-Host "Config file: $envFile"
Write-Host "MCP config file: $mcpConfigFile"
Write-Host "Stop command:"
Write-Host "powershell -ExecutionPolicy Bypass -File `"$stopScript`""
Write-Host "Start command:"
Write-Host "powershell -ExecutionPolicy Bypass -File `"$startScript`""
Write-Host "MCP server command:"
Write-Host "python `"$InstallDir\agenthub_mcp_server.py`""

if ($Restart) {
  if (-not $Token) {
    Write-Host ""
    Write-Host "Restart skipped: this MCP invite must be claimed before the background client can start."
    exit 0
  }
  Write-Host ""
  Write-Host "Restart requested. Stopping existing client, then starting the new client..."
  powershell -ExecutionPolicy Bypass -File "$stopScript"
  Start-Process -FilePath "powershell" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $startScript
  ) -WindowStyle Hidden
  Write-Host "Background client started."
}
