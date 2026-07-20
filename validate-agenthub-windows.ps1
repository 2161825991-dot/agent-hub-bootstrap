param(
  [string]$AgentId = ""
)

$ErrorActionPreference = "Stop"
$root = Join-Path $env:USERPROFILE ".agent-hub"
if (-not (Test-Path $root)) { throw "未找到 $root；此设备尚未完成 t聊 接入。" }

if (-not $AgentId) {
  $candidates = @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object {
    Test-Path (Join-Path $_.FullName "agenthub.json")
  })
  if ($candidates.Count -ne 1) {
    $names = ($candidates | ForEach-Object { $_.Name }) -join ", "
    throw "请使用 -AgentId 指定实例。可选：$names"
  }
  $AgentId = $candidates[0].Name
}

$installDir = Join-Path $root $AgentId
$configPath = Join-Path $installDir "agenthub.json"
if (-not (Test-Path $configPath)) { throw "未找到配置：$configPath" }
$config = Get-Content $configPath -Raw | ConvertFrom-Json

function Test-PidFile([string]$Path) {
  if (-not (Test-Path $Path)) { return $false }
  try {
    $processId = [int](Get-Content $Path -Raw)
    return $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)
  } catch { return $false }
}

function Redact([string]$Value) {
  if (-not $Value) { return "" }
  $clean = $Value -replace '(?i)Bearer\s+[A-Za-z0-9._~-]+', 'Bearer [REDACTED]'
  $clean = $clean -replace '(?i)(token\s*[=:]\s*)\S+', '$1[REDACTED]'
  if ($clean.Length -gt 800) { return $clean.Substring($clean.Length - 800) }
  return $clean
}

$urls = @()
if ($config.hub_url) { $urls += [string]$config.hub_url }
if ($config.hub_urls -is [System.Array]) { $urls += @($config.hub_urls | ForEach-Object { [string]$_ }) }
elseif ($config.hub_urls) { $urls += @(([string]$config.hub_urls) -split ',') }
$urls = @($urls | ForEach-Object { $_.Trim().TrimEnd('/') } | Where-Object { $_ } | Select-Object -Unique)

$reachableUrl = ""
foreach ($url in $urls) {
  try {
    $status = Invoke-RestMethod -Method Get -Uri "$url/status" -TimeoutSec 5
    if ($status.ok -and $status.hub -eq "agent-hub-local") { $reachableUrl = $url; break }
  } catch {}
}

$credentialValid = $false
$grantedScopes = @()
if ($reachableUrl -and $config.token) {
  try {
    $capabilities = Invoke-RestMethod -Method Get -Uri "$reachableUrl/api/auth/capabilities" `
      -Headers @{ Authorization = "Bearer $([string]$config.token)" } -TimeoutSec 8
    $credentialValid = [bool]$capabilities.ok
    if ($capabilities.scopes) { $grantedScopes = @($capabilities.scopes) }
  } catch {}
}

$runtimePath = [string]$config.runtime_path
$runtimeFound = $false
if ($runtimePath) {
  $runtimeFound = Test-Path $runtimePath
  if (-not $runtimeFound) {
    $runtimeFound = $null -ne (Get-Command $runtimePath -ErrorAction SilentlyContinue)
  }
}

$safeId = $AgentId -replace '[^a-zA-Z0-9_-]', '-'
$taskName = "AgentHub-$safeId"
& schtasks.exe /Query /TN $taskName /FO LIST 2>$null | Out-Null
$autostartRegistered = $LASTEXITCODE -eq 0
$connectorRunning = Test-PidFile (Join-Path $installDir "connector.pid")
$supervisorRunning = Test-PidFile (Join-Path $installDir "supervisor.pid")

$lastError = ""
$errorLog = Join-Path $installDir "connector-error.log"
if (Test-Path $errorLog) {
  $lastError = Redact ((Get-Content $errorLog -Tail 8 -ErrorAction SilentlyContinue) -join "`n")
}

$report = [ordered]@{
  ok = ($reachableUrl -and $credentialValid -and $runtimeFound -and $connectorRunning -and $supervisorRunning -and $autostartRegistered)
  agent_id = $AgentId
  agent_kind = [string]$config.agent_kind
  runtime_instance = [string]$config.runtime_instance
  hub_reachable = [bool]$reachableUrl
  hub_url_used = $reachableUrl
  credential_present = [bool]$config.token
  credential_valid = $credentialValid
  granted_scopes = $grantedScopes
  runtime_found = $runtimeFound
  connector_running = $connectorRunning
  supervisor_running = $supervisorRunning
  autostart_registered = $autostartRegistered
  autostart_name = $taskName
  last_error = $lastError
  checked_at = (Get-Date).ToString("o")
}

$report | ConvertTo-Json -Depth 6
if (-not $report.ok) { exit 1 }
