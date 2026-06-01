param(
  [Parameter(Mandatory=$true)]
  [string]$HubUrl,

  [Parameter(Mandatory=$true)]
  [string]$Token,

  [string]$RawBase = "https://raw.githubusercontent.com/2161825991-dot/agent-hub-bootstrap/main",
  [string]$AgentId = "openclaw-windows",
  [string]$AgentName = "OpenClaw Windows",
  [string]$Role = "backend",
  [string]$InstallDir = "$env:USERPROFILE\.agent-hub",
  [string]$HubUrls = "",
  [string]$UseCli = "auto",
  [string]$OpenClawBin = "openclaw"
)

$ErrorActionPreference = "Stop"

function Normalize-Url([string]$Value) {
  return $Value.Trim().TrimEnd("/")
}

function Download-File([string]$Url, [string]$OutFile) {
  Write-Host "Downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

$HubUrl = Normalize-Url $HubUrl
$RawBase = Normalize-Url $RawBase
if (-not $HubUrls) {
  $HubUrls = $HubUrl
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
$envFile = Join-Path $InstallDir "agenthub.env"

@"
AGENT_HUB_URL=$HubUrl
AGENT_HUB_URLS=$HubUrls
AGENT_HUB_TOKEN=$Token
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
`$env:AGENT_HUB_ID="$AgentId"
`$env:AGENT_HUB_NAME="$AgentName"
`$env:AGENT_HUB_ROLE="$Role"
`$env:AGENT_HUB_TIMEOUT="10"
`$env:AGENT_HUB_RECONNECT_INTERVAL="5"
`$env:OPENCLAW_USE_CLI="$UseCli"
`$env:OPENCLAW_BIN="$OpenClawBin"
python openclaw_agent.py
"@ | Set-Content -Path $startScript -Encoding UTF8

Write-Host ""
Write-Host "Agent Hub client installed to: $InstallDir"
Write-Host "Config file: $envFile"
Write-Host "Start command:"
Write-Host "powershell -ExecutionPolicy Bypass -File `"$startScript`""
