# Platterly lead stack on the store laptop: Supabase (Docker) + lead proxy + public tunnel.
# Safe to run any time: if everything is already healthy it does nothing.
# Installed as the "Platterly-Leads" scheduled task by server/install-autostart.ps1 (at logon + every 30 min).
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$State = Join-Path $env:LOCALAPPDATA 'platterly'
New-Item -ItemType Directory -Force $State | Out-Null
$Log = Join-Path $State 'start.log'
function Say($m) { "$(Get-Date -Format s) $m" | Tee-Object -FilePath $Log -Append }
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
if ((Alive "$State\proxy.pid") -and (Alive "$State\tunnel.pid") -and (PublicHealthy $current)) { Say "healthy: $current"; exit 0 }

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
if (-not $anon) { Say 'ERROR: database did not start (no ANON_KEY from supabase status)'; exit 1 }

# 2. Lead proxy (localhost only)
if (-not (Alive "$State\proxy.pid")) {
  $env:PLATTERLY_ANON_KEY = $anon; $env:PORT = "$ProxyPort"
  $p = Start-Process node -ArgumentList "`"$Repo\server\lead-proxy.mjs`"" -WindowStyle Hidden -PassThru `
       -RedirectStandardOutput "$State\proxy.log" -RedirectStandardError "$State\proxy.err"
  $p.Id | Set-Content "$State\proxy.pid"
  Remove-Item Env:PLATTERLY_ANON_KEY
  Start-Sleep 2; Say "proxy started (pid $($p.Id))"
}

# 3. Public tunnel to the proxy only
if (Alive "$State\tunnel.pid") { Stop-Process -Id ([int](Get-Content "$State\tunnel.pid")) -Force -ErrorAction SilentlyContinue }
Remove-Item "$State\tunnel.log" -ErrorAction SilentlyContinue
$t = Start-Process $Cloudflared -ArgumentList "tunnel --no-autoupdate --url http://127.0.0.1:$ProxyPort" -WindowStyle Hidden -PassThru `
     -RedirectStandardOutput "$State\tunnel.out" -RedirectStandardError "$State\tunnel.log"
$t.Id | Set-Content "$State\tunnel.pid"
$url = $null
for ($i = 0; $i -lt 45 -and -not $url; $i++) { Start-Sleep 1; $m = Select-String -Path "$State\tunnel.log" -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($m) { $url = $m.Matches[0].Value } }
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
