# Platterly lead stack on the store laptop: Supabase (Docker) + lead proxy + public tunnel.
# Safe to run any time: if everything is already healthy it does nothing.
# To run it automatically, register it as a scheduled task (see README: Platterly-Leads, at logon + every 30 min).
# 'Continue': native tools (supabase CLI, git) write normal progress to stderr, which PowerShell 5.1 would
# otherwise turn into fatal errors. Each step checks its own result instead.
$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent $PSScriptRoot
$State = Join-Path $env:LOCALAPPDATA 'platterly'
New-Item -ItemType Directory -Force $State | Out-Null
$Log = Join-Path $State 'start.log'
function Say($m) { $line = "$(Get-Date -Format s) $m"; Add-Content -Path $Log -Value $line -Encoding utf8; $line }
$Cloudflared = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$ApiJson = Join-Path $Repo 'web\panago\api.json'
$ProxyPort = 56380

function Alive($pidFile) {
  if (-not (Test-Path $pidFile)) { return $false }
  $p = Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue
  return [bool]$p
}
function PublicHealthy($url) {
  if (-not $url) { return $false }
  try { (Invoke-RestMethod -Uri "$url/v1/health" -TimeoutSec 10).ok -eq $true } catch { $false }
}

$current = $null
try { $current = (Get-Content $ApiJson -Raw | ConvertFrom-Json).leadApi } catch {}
$restartProxy = $args -contains '-RestartProxy'
if (-not $restartProxy -and (Alive "$State\proxy.pid") -and (Alive "$State\tunnel.pid") -and (PublicHealthy $current)) { Say "healthy: $current"; exit 0 }

# 1. Docker + database
docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Say 'starting Docker Desktop'
  Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
  for ($i = 0; $i -lt 60; $i++) { Start-Sleep 5; docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { break } }
}
Push-Location $Repo
try {
  npx -y supabase@2.121.0 start 2>&1 | Out-Null
  $envLines = npx -y supabase@2.121.0 status -o env 2>$null
} finally { Pop-Location }
$anon = ($envLines | Where-Object { $_ -match '^ANON_KEY=' }) -replace '^ANON_KEY="?([^"]*)"?$', '$1'
$service = ($envLines | Where-Object { $_ -match '^SERVICE_ROLE_KEY=' }) -replace '^SERVICE_ROLE_KEY="?([^"]*)"?$', '$1'
if (-not $anon -or -not $service) { Say 'ERROR: database did not start (no keys from supabase status)'; exit 1 }

# 1b. Email: the Listmonk instances (one per sender) on the same database server, then their settings.
if (Test-Path "$State\listmonk.env") {
  docker compose -p platterly-mail --env-file "$State\listmonk.env" -f "$Repo\server\listmonk\docker-compose.yml" up -d 2>&1 | Out-Null
  node "$Repo\server\listmonk\setup.mjs" 2>&1 | ForEach-Object { Say "listmonk: $_" }
} else { Say 'WARN: no listmonk.env: email (reminders, invoices, reports) is off. See README: Email.' }

# 2. Lead proxy (localhost only)
if ($restartProxy -and (Alive "$State\proxy.pid")) { Stop-Process -Id ([int](Get-Content "$State\proxy.pid")) -Force; Start-Sleep 1 }
if (-not (Alive "$State\proxy.pid")) {
  # Secrets kept outside the repo, one KEY=VALUE per line: listmonk.env (Listmonk API tokens, made on first setup) and
  # optional mail.env (TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM for text reminders).
  foreach ($f in @("$State\listmonk.env", "$State\mail.env")) { if (Test-Path $f) { Get-Content $f | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$' } | ForEach-Object { Set-Item "Env:$($Matches[1])" $Matches[2] } } }
  $env:PLATTERLY_ANON_KEY = $anon; $env:PLATTERLY_SERVICE_KEY = $service; $env:PORT = "$ProxyPort"
  $p = Start-Process node -ArgumentList "`"$Repo\server\lead-proxy.mjs`"" -WindowStyle Hidden -PassThru `
       -RedirectStandardOutput "$State\proxy.log" -RedirectStandardError "$State\proxy.err"
  $p.Id | Set-Content "$State\proxy.pid"
  Remove-Item Env:PLATTERLY_ANON_KEY, Env:PLATTERLY_SERVICE_KEY
  Start-Sleep 2; Say "proxy started (pid $($p.Id))"
}

# 3. Public tunnel to the proxy only. Kept when it still answers, so the published address does not change.
$url = $null
if ((Alive "$State\tunnel.pid") -and (PublicHealthy $current)) { $url = $current }
else {
  if (Alive "$State\tunnel.pid") { Stop-Process -Id ([int](Get-Content "$State\tunnel.pid")) -Force -ErrorAction SilentlyContinue }
  Remove-Item "$State\tunnel.log" -ErrorAction SilentlyContinue
  $t = Start-Process $Cloudflared -ArgumentList "tunnel --no-autoupdate --url http://127.0.0.1:$ProxyPort" -WindowStyle Hidden -PassThru `
       -RedirectStandardOutput "$State\tunnel.out" -RedirectStandardError "$State\tunnel.log"
  $t.Id | Set-Content "$State\tunnel.pid"
  for ($i = 0; $i -lt 45 -and -not $url; $i++) { Start-Sleep 1; $m = Select-String -Path "$State\tunnel.log" -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($m) { $url = $m.Matches[0].Value } }
}
if (-not $url) { Say 'ERROR: tunnel gave no address (see tunnel.log)'; exit 1 }
Say "tunnel: $url"

# 4. Publish the address for the QR page (GitHub Pages redeploys in about a minute)
if ($url -ne $current) {
  $json = @{ leadApi = $url; updated = (Get-Date).ToUniversalTime().ToString('s') + 'Z' } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($ApiJson, $json + "`n")
  Push-Location $Repo
  try {
    git pull --rebase --autostash -q 2>&1 | Out-Null
    git add web/panago/api.json
    git commit -q -m "Lead API address: $url" 2>&1 | Out-Null
    git push -q 2>&1 | Out-Null
    Say "published api.json"
  } catch { Say "WARN: could not push api.json: $_" } finally { Pop-Location }
}
