# Platterly on the VPS (Windows Server, no Docker): its own PostgreSQL 16 cluster, PostgREST, the lead proxy,
# three Listmonk instances, and a fixed public HTTPS address through Tailscale Funnel (port 10000). Replaces the store laptop.
#   C:\platterly\app     this repo (server, supabase, web)
#   C:\platterly\bin     postgrest.exe, listmonk.exe
#   C:\platterly\pgdata  the database cluster (service PlatterlyPG, 127.0.0.1:56322)
#   C:\platterly\state   secrets (platterly.env, postgrest.conf, Administrators/SYSTEM only) and logs
# Safe to re-run: every step checks before it acts. Run as Administrator:
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\platterly\app\server\vps\setup-vps.ps1
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$Root = 'C:\platterly'; $App = "$Root\app"; $Bin = "$Root\bin"; $Data = "$Root\pgdata"; $State = "$Root\state"
$PgBin = 'C:\Program Files\PostgreSQL\16\bin'; $PgPort = 56322; $RestPort = 56331
New-Item -ItemType Directory -Force $Bin, $State | Out-Null
function Say($m) { "$(Get-Date -Format s) $m" }

# 1. Secrets, made once and kept in state\platterly.env
function Secret { $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { '{0:x2}' -f $_ }) }
$EnvFile = "$State\platterly.env"; $cfg = [ordered]@{}
if (Test-Path $EnvFile) { Get-Content $EnvFile | Where-Object { $_ -match '^([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2] } }
foreach ($k in 'PG_SUPER_PASSWORD', 'PG_AUTH_PASSWORD', 'JWT_SECRET', 'LISTMONK_DB_PASSWORD', 'LM_PLATTERLY_ADMIN_PASSWORD', 'LM_PANAGO_ADMIN_PASSWORD',
                 'LM_WETZELS_ADMIN_PASSWORD', 'LM_PLATTERLY_API_TOKEN', 'LM_PANAGO_API_TOKEN', 'LM_WETZELS_API_TOKEN') { if (-not $cfg[$k]) { $cfg[$k] = Secret } }

# 2. Programs
function Fetch($url, $dest) { if (-not (Test-Path $dest)) { Say "download $url"; Invoke-WebRequest $url -OutFile "$dest.part" -UseBasicParsing; Move-Item "$dest.part" $dest } }
if (-not (Test-Path "$Bin\postgrest.exe")) {
  Fetch 'https://github.com/PostgREST/postgrest/releases/download/v16.4/postgrest-v16.4-windows-x86-64.zip' "$Bin\postgrest.zip"
  Expand-Archive "$Bin\postgrest.zip" $Bin -Force; Remove-Item "$Bin\postgrest.zip"
}
if (-not (Test-Path "$Bin\listmonk.exe")) {
  Fetch 'https://github.com/knadh/listmonk/releases/download/v5.1.0/listmonk_5.1.0_windows_amd64.tar.gz' "$Bin\listmonk.tar.gz"
  tar -xzf "$Bin\listmonk.tar.gz" -C $Bin listmonk.exe; Remove-Item "$Bin\listmonk.tar.gz"
}

# 3. Database cluster, separate from any other Postgres on this machine
if (-not (Test-Path "$Data\PG_VERSION")) {
  Say 'initdb'
  $pw = "$State\pgpw.tmp"; [IO.File]::WriteAllText($pw, $cfg.PG_SUPER_PASSWORD)
  & "$PgBin\initdb.exe" -D $Data -U postgres -A scram-sha-256 --pwfile=$pw -E UTF8 --locale=C | Out-Null
  Remove-Item $pw
  if ($LASTEXITCODE) { throw 'initdb failed' }
  Add-Content "$Data\postgresql.conf" "`nport = $PgPort`nlisten_addresses = '127.0.0.1'`ntimezone = 'UTC'`nshared_buffers = 128MB`nmax_connections = 60`n"
}
icacls $Data /grant 'NT AUTHORITY\NETWORK SERVICE:(OI)(CI)M' /T /Q | Out-Null
if (-not (Get-Service PlatterlyPG -ErrorAction SilentlyContinue)) { & "$PgBin\pg_ctl.exe" register -N PlatterlyPG -D $Data -S auto -U 'NT AUTHORITY\NetworkService' | Out-Null }
Start-Service PlatterlyPG
$env:PGPASSWORD = $cfg.PG_SUPER_PASSWORD
function Psql { & "$PgBin\psql.exe" -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -q @args; if ($LASTEXITCODE) { throw "psql failed: $args" } }
for ($i = 0; $i -lt 30; $i++) { & "$PgBin\pg_isready.exe" -h 127.0.0.1 -p $PgPort | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 1 }

# 4. The roles and schemas a Supabase project has, so the migrations run unchanged
$boot = @"
do `$`$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator login noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'listmonk') then create role listmonk login; end if;
end `$`$;
alter role authenticator password '$($cfg.PG_AUTH_PASSWORD)';
alter role listmonk password '$($cfg.LISTMONK_DB_PASSWORD)';
grant anon, authenticated, service_role to authenticator;
create schema if not exists extensions;
create extension if not exists pgcrypto schema extensions;
grant usage on schema public, extensions to anon, authenticated, service_role;
alter database postgres set search_path = public, extensions;
create schema if not exists platterly_meta;
create table if not exists platterly_meta.migrations (version text primary key, applied_at timestamptz not null default now());
select format('create database %I owner listmonk', d) from unnest(array['listmonk_platterly', 'listmonk_panago', 'listmonk_wetzels']) d
 where not exists (select 1 from pg_database where datname = d)
\gexec
"@
$bootFile = "$State\boot.tmp.sql"; [IO.File]::WriteAllText($bootFile, $boot)
try { Psql -f $bootFile } finally { Remove-Item $bootFile }

# 5. Migrations, each once, each in one transaction
foreach ($f in Get-ChildItem "$App\supabase\migrations\*.sql" | Sort-Object Name) {
  $v = $f.BaseName.Split('_')[0]
  if (-not (& "$PgBin\psql.exe" -h 127.0.0.1 -p $PgPort -U postgres -d postgres -tAc "select 1 from platterly_meta.migrations where version = '$v'")) {
    Say "migration $($f.Name)"; Psql -1 -f $f.FullName; Psql -c "insert into platterly_meta.migrations (version) values ('$v')"
  }
}

# 6. API keys (JWTs signed with this server's own secret) and the PostgREST config
if (-not $cfg['PLATTERLY_ANON_KEY']) {
  $mint = "const c=require('crypto'),s=process.argv[1],b=o=>Buffer.from(JSON.stringify(o)).toString('base64url');" +
          "const t=r=>{const h=b({alg:'HS256',typ:'JWT'}),p=b({role:r,iss:'platterly',iat:Math.floor(Date.now()/1e3),exp:Math.floor(Date.now()/1e3)+10*365*86400});" +
          "return h+'.'+p+'.'+c.createHmac('sha256',s).update(h+'.'+p).digest('base64url')};console.log(t('anon')+' '+t('service_role'))"
  $k = (& node -e $mint $cfg.JWT_SECRET).Split(' ')
  $cfg['PLATTERLY_ANON_KEY'] = $k[0]; $cfg['PLATTERLY_SERVICE_KEY'] = $k[1]
}
$cfg.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content $EnvFile -Encoding ascii
@"
db-uri = "postgres://authenticator:$($cfg.PG_AUTH_PASSWORD)@127.0.0.1:$PgPort/postgres"
db-schemas = "public"
db-anon-role = "anon"
db-extra-search-path = "public, extensions"
jwt-secret = "$($cfg.JWT_SECRET)"
server-host = "127.0.0.1"
server-port = $RestPort
"@ | Set-Content "$State\postgrest.conf" -Encoding ascii
foreach ($f in $EnvFile, "$State\postgrest.conf") { icacls $f /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' | Out-Null }

# 7. Keep it running: at boot and every 5 minutes (start-vps.ps1 only starts what is down). Started through the task,
#    not from this shell, so the services outlive an SSH session.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$App\server\vps\start-vps.ps1`""
$triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)))
Register-ScheduledTask -TaskName 'Platterly' -Action $action -Trigger $triggers -User 'SYSTEM' -RunLevel Highest -Force `
  -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew) | Out-Null
Start-ScheduledTask -TaskName 'Platterly'
for ($i = 0; $i -lt 90 -and -not (Get-NetTCPConnection -State Listen -LocalPort 56380 -ErrorAction SilentlyContinue); $i++) { Start-Sleep 2 }
Get-Content "$State\start.log" -Tail 12 -ErrorAction SilentlyContinue
Say ('setup done; proxy ' + $(if (Get-NetTCPConnection -State Listen -LocalPort 56380 -ErrorAction SilentlyContinue) { 'listening on 56380' } else { 'NOT listening yet (see C:\platterly\state\proxy.err)' }))
