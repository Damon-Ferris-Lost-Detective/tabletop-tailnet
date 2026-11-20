# Windows/PowerShell version of validate.sh.
# Run from anywhere, signed in to Tailscale as the admin:
#   powershell -ExecutionPolicy Bypass -File scripts\validate.ps1
# Output is saved to docs\evidence\validation-<timestamp>.txt
# Needs: tailscale, terraform, aws CLI, ssh (built into Windows).

param(
  [string]$Domain = "tail96c8bb.ts.net",
  [string]$Region = "us-east-2"
)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$evidence = Join-Path $repo "docs\evidence"
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$log = Join-Path $evidence ("validation-" + (Get-Date -Format "yyyyMMddTHHmmss") + ".txt")
Start-Transcript -Path $log | Out-Null

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Ok($m)   { Write-Host "  PASS  $m" -ForegroundColor Green;  $script:pass++ }
function Bad($m)  { Write-Host "  FAIL  $m" -ForegroundColor Red;    $script:fail++ }
function Skp($m)  { Write-Host "  SKIP  $m" -ForegroundColor Yellow; $script:skip++ }
function Hdr($m)  { Write-Host ""; Write-Host "## $m" }

function Test-Port($ip, $port) {
  $c = New-Object System.Net.Sockets.TcpClient
  try { $t = $c.ConnectAsync($ip, $port); return ($t.Wait(3000) -and $c.Connected) }
  catch { return $false }
  finally { $c.Close() }
}

function Tf($name) {
  Push-Location $repo
  try { return ((terraform -chdir=terraform output -raw $name 2>$null) | Out-String).Trim() }
  finally { Pop-Location }
}

$pubip = Tf "public_ip"
$sg    = Tf "security_group_id"
Write-Host ("validation run: " + (Get-Date -Format "u") + "   tailnet: $Domain   region: $Region   host public ip: $pubip")

# ---------------------------------------------------------------------------
Hdr "1. Nodes are on the tailnet"
$status = tailscale status --json | ConvertFrom-Json
$peers = @($status.Peer.PSObject.Properties | ForEach-Object { $_.Value })
foreach ($n in "tt-host","tt-dnd","tt-daggerheart","tt-pf2e","tt-sf2e") {
  $p = $peers | Where-Object { $_.HostName -eq $n } | Select-Object -First 1
  if ($p -and $p.Online) { Ok ("$n online  ip=" + $p.TailscaleIPs[0] + "  tags=" + (($p.Tags) -join ",")) }
  elseif ($p)            { Bad "$n is on the tailnet but offline" }
  else                   { Bad "$n not found on the tailnet" }
}

# ---------------------------------------------------------------------------
Hdr "2. Traffic path to the host (direct vs relayed)"
$ping = (tailscale ping --c 3 --timeout 5s tt-host 2>&1 | Out-String)
$ping.TrimEnd() -split "`n" | ForEach-Object { Write-Host ("        " + $_.TrimEnd()) }
if ($LASTEXITCODE -eq 0) { Ok "tailscale ping tt-host answered" } else { Bad "tailscale ping tt-host failed" }

# ---------------------------------------------------------------------------
Hdr "3. Tables answer over tailnet HTTPS with a valid certificate"
foreach ($t in "dnd","daggerheart","pf2e","sf2e") {
  $url = "https://tt-$t.$Domain/api/status"
  try {
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
    $j = $r.Content | ConvertFrom-Json
    Ok "$t  HTTP $($r.StatusCode)  active=$($j.active)  version=$($j.version)  world=$($j.world)"
  } catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -in 502,503,504) { Skp "$t  node reachable but Foundry is closed (HTTP $code). Open it: sudo tabletop switch $t" }
    else { Bad "$t  $url  ->  $($_.Exception.Message)" }
  }
}

# ---------------------------------------------------------------------------
Hdr "4. Nothing is listening on the public internet"
if ($pubip) {
  foreach ($port in 22,80,443,30000) {
    if (Test-Port $pubip $port) { Bad "public ${pubip}:$port is OPEN" } else { Ok "public ${pubip}:$port is closed/filtered" }
  }
} else { Skp "no public_ip from terraform output" }
if ($sg) {
  $n = (aws ec2 describe-security-groups --region $Region --group-ids $sg --query "length(SecurityGroups[0].IpPermissions)" --output text 2>$null | Out-String).Trim()
  if ($n -eq "0") { Ok "security group $sg has 0 inbound rules" } else { Bad "security group $sg has '$n' inbound rules (expected 0)" }
} else { Skp "no security_group_id from terraform output" }

# ---------------------------------------------------------------------------
Hdr "5. Admin path: Tailscale SSH (no key, no open port 22)"
$out = (ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new ubuntu@tt-host "hostname; sudo tabletop status" 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { Ok "ssh ubuntu@tt-host worked"; $out.TrimEnd() -split "`n" | ForEach-Object { Write-Host ("        " + $_.TrimEnd()) } }
else { Bad "ssh failed: $out" }

# ---------------------------------------------------------------------------
Hdr "6. Blast radius: a compromised table cannot reach another table"
$dstIp = ((tailscale ip -4 tt-pf2e 2>$null) | Out-String).Trim()
if ($dstIp) {
  $remote = "sudo docker exec ts-dnd tailscale status >/dev/null 2>&1 || exit 3; sudo docker exec ts-dnd tailscale ping --c 2 --timeout 5s $dstIp"
  $o = (ssh -o ConnectTimeout=10 ubuntu@tt-host $remote 2>&1 | Out-String)
  $rc = $LASTEXITCODE
  if ($rc -eq 3)     { Skp "ts-dnd container is not running, cannot run the isolation test" }
  elseif ($rc -eq 0) { Bad "tt-dnd reached tt-pf2e ($dstIp); the policy is too open"; Write-Host $o }
  else               { Ok "tt-dnd cannot reach tt-pf2e ($dstIp)"; $o.TrimEnd() -split "`n" | Select-Object -First 3 | ForEach-Object { Write-Host ("        " + $_.TrimEnd()) } }
} else { Skp "could not resolve tt-pf2e" }

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("== {0} passed, {1} failed, {2} skipped ==  (saved to {3})" -f $script:pass, $script:fail, $script:skip, $log)
Stop-Transcript | Out-Null
