#Requires -RunAsAdministrator
<#
  PostalAnnex Gig Harbor — remote access for the master PC (pa-master-19004)
  Rebel Viking, 2026-10-19 (v3: safe to run again). In PowerShell opened as Administrator:

    powershell -ExecutionPolicy Bypass -File setup-remote-access.ps1 -AuthKey tskey-auth-...

  What it does, in order:
    1. Takes the one-time key (on the command line; if it is missing, asks for it).
    2. Installs Tailscale and joins the Rebel Viking network as this one device.
    3. Installs the Windows OpenSSH Server.
    4. Allows exactly ONE key to log in (the Rebel Viking jump server's). Passwords off.
    5. Opens port 22 to the Tailscale network only (100.64.0.0/10). Nothing else changes.

  What it does NOT do: it advertises no routes and no exit node, so this PC cannot reach
  anything at Rebel Viking — Rebel Viking can reach this PC on port 22, and nothing else.
  The key is single-use and is not written anywhere. PostalMate, printers and the shop
  network are untouched.
#>
param(
  [string]$AuthKey = ""
)
$ErrorActionPreference = "Stop"
$Hostname = "pa-master-19004"
$JumpKey  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICPnk8he2kOWmCXTvF53ZjNwWr7AbjfHbUZVT9TIXUZQ rv-jump-pa -> pa-master-19004"

function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

# ---- 1. the key -----------------------------------------------------------------
Step "The key"
if (-not $AuthKey) { $AuthKey = Read-Host "Paste the key (it starts with tskey-auth-), then press Enter" }
# Tidy what a copy from an email tends to bring along: spaces, quotes, a trailing period.
$AuthKey = ($AuthKey -replace '[\s"'']', '').TrimEnd('.')
if (-not $AuthKey.StartsWith("tskey-auth-") -or $AuthKey.Length -lt 30) {
  throw "That does not look like the key (it starts with tskey-auth- and is about 60 characters). Copy the whole key and run the line again."
}
Write-Host "Key received ($($AuthKey.Length) characters)."

# ---- 2. Tailscale ---------------------------------------------------------------
Step "Tailscale"
$ts = "C:\Program Files\Tailscale\tailscale.exe"
if (-not (Test-Path $ts)) {
  $msi = Join-Path $env:TEMP "tailscale-setup.msi"
  Write-Host "Downloading Tailscale..."
  Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi" -OutFile $msi -UseBasicParsing
  Write-Host "Installing Tailscale..."
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
  Start-Sleep -Seconds 8
}
if (-not (Test-Path $ts)) { throw "Tailscale did not install. Install it from tailscale.com/download, then run the line again." }
# Already joined (this line was run twice)? Leave Tailscale alone — a used key would log it out.
$already = $false
try { $already = ((& $ts status --json | ConvertFrom-Json).BackendState -eq "Running") } catch { $already = $false }
if ($already) {
  Write-Host "Tailscale is already connected on this PC. Leaving it as it is."
} else {
  & $ts up --auth-key=$AuthKey --hostname=$Hostname --unattended --accept-routes=false --accept-dns=false --advertise-exit-node=false --reset
  if ($LASTEXITCODE -ne 0) { throw "Tailscale did not accept the key (a key works once; ask Craig for a fresh one). tailscale up exit $LASTEXITCODE." }
}
$AuthKey = $null
Start-Sleep -Seconds 3
$ip = (& $ts ip -4 | Select-Object -First 1).Trim()
Write-Host "Tailscale is on. This PC is $Hostname at $ip"

# ---- 3. OpenSSH Server ----------------------------------------------------------
Step "OpenSSH Server"
$cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Server*" } | Select-Object -First 1
if (-not $cap) { throw "This Windows has no OpenSSH Server feature. Tell Craig the Windows version (Settings > System > About)." }
if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd          # first start writes C:\ProgramData\ssh\sshd_config
Stop-Service sshd
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null

# ---- 4. keys only, one key -------------------------------------------------------
Step "Keys only"
$conf = Join-Path $env:ProgramData "ssh\sshd_config"
$text = Get-Content $conf -Raw
foreach ($pair in @(@("PasswordAuthentication","no"), @("PubkeyAuthentication","yes"), @("KbdInteractiveAuthentication","no"), @("PermitEmptyPasswords","no"))) {
  $k = $pair[0]; $v = $pair[1]
  if ($text -match "(?m)^\s*#?\s*$k\s+\S+") { $text = $text -replace "(?m)^\s*#?\s*$k\s+\S+.*$", "$k $v" }
  else { $text = $text.TrimEnd() + "`r`n$k $v`r`n" }
}
Set-Content -Path $conf -Value $text -Encoding ascii
# Administrators log in through this file (Windows' rule); everyone else through their own.
$adminKeys = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
Set-Content -Path $adminKeys -Value $JumpKey -Encoding ascii
icacls $adminKeys /inheritance:r /grant "SYSTEM:F" /grant "BUILTIN\Administrators:F" | Out-Null
$userDir  = Join-Path $HOME ".ssh"
New-Item -ItemType Directory -Force -Path $userDir | Out-Null
Set-Content -Path (Join-Path $userDir "authorized_keys") -Value $JumpKey -Encoding ascii

# ---- 5. firewall: port 22 from the Tailscale network only -------------------------
Step "Firewall"
Get-NetFirewallRule -DisplayName "OpenSSH*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "OpenSSH (Tailscale only)" -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10 -Action Allow -Profile Any | Out-Null
Start-Service sshd

# ---- 6. done --------------------------------------------------------------------
Step "Done"
Write-Host ""
Write-Host "Computer: $env:COMPUTERNAME   Windows user: $env:USERNAME   Tailscale IP: $ip" -ForegroundColor Green
Write-Host "Read the Windows user name and the Tailscale IP to Craig. That is all."
