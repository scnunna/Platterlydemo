# Keeps Platterly running on the VPS: PostgREST, three Listmonk instances, the lead proxy and the Funnel address.
# Starts only what is not listening, so it is safe every 5 minutes (scheduled task "Platterly", made by setup-vps.ps1).
$ErrorActionPreference = 'Continue'
$Root = 'C:\platterly'; $App = "$Root\app"; $Bin = "$Root\bin"; $State = "$Root\state"; $Log = "$State\start.log"
$Tailscale = 'C:\Program Files\Tailscale\tailscale.exe'; $Node = 'C:\Program Files\nodejs\node.exe'
function Say($m) { Add-Content -Path $Log -Value "$(Get-Date -Format s) $m" -Encoding utf8 }
# Never keep an API token in the log (Listmonk prints the one it generates at install).
if ((Test-Path $Log) -and (Select-String -Path $Log -Pattern 'TOKEN="' -Quiet)) { (Get-Content $Log) -replace 'TOKEN="[^"]*"', 'TOKEN="[redacted]"' | Set-Content $Log -Encoding utf8 }
function Up($port) { [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) }
$cfg = @{}; Get-Content "$State\platterly.env" | Where-Object { $_ -match '^([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2] }
function Run($name, $exe, $argList, $vars) {
  foreach ($k in $vars.Keys) { Set-Item "Env:$k" $vars[$k] }
  $p = Start-Process $exe -ArgumentList $argList -WindowStyle Hidden -PassThru -WorkingDirectory $State `
       -RedirectStandardOutput "$State\$name.log" -RedirectStandardError "$State\$name.err"
  foreach ($k in $vars.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
  Say "$name started (pid $($p.Id))"
}

if ((Get-Service PlatterlyPG).Status -ne 'Running') { Start-Service PlatterlyPG; Say 'database started' }
# PostgREST's Windows build needs libpq.dll and friends from PostgreSQL's bin folder.
# Under a small Node supervisor that restarts it: started directly from this task, it did not stay up.
if (-not (Up 56331) -and -not (Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object CommandLine -match 'postgrest-run')) {
  Run 'postgrest-supervisor' $Node "`"$App\server\vps\postgrest-run.mjs`" `"$Bin\postgrest.exe`" `"$State\postgrest.conf`" `"$State\postgrest.log`"" @{ PATH = "C:\Program Files\PostgreSQL\16\bin;$env:PATH" }
}

# Email: one Listmonk per sender (server/listmonk/docker-compose.yml is the laptop version of the same thing)
$mail = @{ platterly = 56390; panago = 56391; wetzels = 56392 }
$started = $false
$env:PGPASSWORD = $cfg.PG_SUPER_PASSWORD
$Psql = 'C:\Program Files\PostgreSQL\16\bin\psql.exe'
# Listmonk 5 makes its own random API token at install and stores API tokens as-is, read at start. Keep the one in
# platterly.env (what the proxy and setup.mjs use): set it, and restart that instance if it had to change.
function SyncToken($n) {
  $tk = $cfg["LM_$($n.ToUpper())_API_TOKEN"]
  $r = & $Psql -h 127.0.0.1 -p 56322 -U postgres -d "listmonk_$n" -tAc "update users set password = '$tk' where username = 'platterly-api' and type = 'api' and password is distinct from '$tk' returning id" 2>$null
  return [bool]$r
}
foreach ($n in $mail.Keys) {
  if ((Up $mail[$n]) -and (SyncToken $n)) {
    Get-NetTCPConnection -State Listen -LocalPort $mail[$n] | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
    Say "listmonk-$($n): API token reset, restarting"; Start-Sleep 2
  }
  if (Up $mail[$n]) { continue }
  $u = $n.ToUpper()
  $vars = @{ LISTMONK_app__address = "127.0.0.1:$($mail[$n])"; LISTMONK_db__host = '127.0.0.1'; LISTMONK_db__port = '56322'; LISTMONK_db__user = 'listmonk'
             LISTMONK_db__password = $cfg.LISTMONK_DB_PASSWORD; LISTMONK_db__database = "listmonk_$n"; LISTMONK_db__ssl_mode = 'disable'
             LISTMONK_ADMIN_USER = "$n-admin"; LISTMONK_ADMIN_PASSWORD = $cfg["LM_$($u)_ADMIN_PASSWORD"]
             LISTMONK_ADMIN_API_USER = 'platterly-api'; LISTMONK_ADMIN_API_TOKEN = $cfg["LM_$($u)_API_TOKEN"] }
  foreach ($k in $vars.Keys) { Set-Item "Env:$k" $vars[$k] }
  # (--config= means no config file: everything comes from the LISTMONK_ variables; PowerShell 5.1 drops '' arguments)
  & "$Bin\listmonk.exe" --install --idempotent --yes --config= 2>&1 | Where-Object { "$_" -notmatch 'TOKEN=' } | ForEach-Object { Say "listmonk-$($n) install: $_" }
  & "$Bin\listmonk.exe" --upgrade --yes --config= 2>&1 | Out-Null
  foreach ($k in $vars.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
  SyncToken $n | Out-Null
  Run "listmonk-$n" "$Bin\listmonk.exe" '--config=' $vars
  $started = $true
}
$lmVars = @{ LM_PLATTERLY_API_TOKEN = $cfg.LM_PLATTERLY_API_TOKEN; LM_PANAGO_API_TOKEN = $cfg.LM_PANAGO_API_TOKEN; LM_WETZELS_API_TOKEN = $cfg.LM_WETZELS_API_TOKEN }
if ($started) {
  Start-Sleep 3
  foreach ($k in $lmVars.Keys) { Set-Item "Env:$k" $lmVars[$k] }
  & $Node "$App\server\listmonk\setup.mjs" 2>&1 | ForEach-Object { Say "listmonk: $_" }
  foreach ($k in $lmVars.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

# The lead proxy: the only public part. It also serves web/ itself.
if (-not (Up 56380)) {
  Run 'proxy' $Node "`"$App\server\lead-proxy.mjs`"" ($lmVars + @{ PLATTERLY_ANON_KEY = $cfg.PLATTERLY_ANON_KEY; PLATTERLY_SERVICE_KEY = $cfg.PLATTERLY_SERVICE_KEY
    PLATTERLY_REST = 'http://127.0.0.1:56331'; PORT = '56380' })
}

# Fixed public address: https://<this machine>.<tailnet>.ts.net:10000 -> the proxy. --bg keeps it across reboots.
# (Funnel allows ports 443, 8443 and 10000; 443 and 8443 already serve other things on this machine, tailnet only.)
if (-not ((& $Tailscale funnel status 2>&1) -match ':10000')) { & $Tailscale funnel --bg --https=10000 http://127.0.0.1:56380 2>&1 | ForEach-Object { Say "funnel: $_" } }
