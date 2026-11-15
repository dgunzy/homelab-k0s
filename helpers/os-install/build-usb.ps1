#Requires -Version 5.1
<#
.SYNOPSIS
  Builds an Ubuntu Server autoinstall USB stick for a host in this repo.

.DESCRIPTION
  1. Verifies the ISO against Ubuntu's SHA256SUMS.
  2. Checks that the target drive letter is a USB disk (refuses anything else).
  3. Prompts for the Wi-Fi password and Linux login password (never stored in git).
  4. Pulls ALL your SSH public keys from https://github.com/<user>.keys
     (add every device's key to GitHub before building the stick).
  5. Wipes the USB volume, extracts the ISO onto it, and writes /autoinstall.yaml.

  The drive letter names one FAT32 volume, not the whole disk: on a stick with
  a second data partition, only the first (FAT32) partition is rewritten, and
  the installer files live there.

  Run it yourself in a normal PowerShell window (it needs to prompt you):
    cd ~\homelab-k0s
    .\bootstrap\install\build-usb.ps1 -GitHubUser <you>

  Safe to re-run: every run wipes the stick and rebuilds it from scratch.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $GitHubUser,
  [string] $UsbDriveLetter = 'F',
  [string] $IsoPath = "$HOME\Downloads\ubuntu-iso\ubuntu-24.04.5-live-server-amd64.iso",
  [string] $HostName = 'k0s-gpu-01',
  [string] $WifiSsid = 'archum',
  # Optional non-interactive mode. Omit these to be prompted instead.
  [Security.SecureString] $WifiPassword,
  [Security.SecureString] $LinuxPassword,
  [switch] $Yes
)
$ErrorActionPreference = 'Stop'
$template = Join-Path $PSScriptRoot "hosts\$HostName\autoinstall.yaml"
$openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'

# Pinned installer image. From https://releases.ubuntu.com/24.04.5/SHA256SUMS
$PinnedIsoSha256 = @{
  'ubuntu-24.04.5-live-server-amd64.iso' = '97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8'
}

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function YamlDq([string]$s) { $s.Replace('\', '\\').Replace('"', '\"') }
function Plain([Security.SecureString]$s) {
  $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}
# SHA-512 crypt hash via `openssl passwd -6 -stdin`, fed exactly "<pw>\n" as
# UTF-8. Do NOT pipe a string into openssl: Windows PowerShell 5.1 appends
# CRLF (and re-encodes as ASCII), openssl strips only the LF, and the hash is
# then of "<pw>`r". That is why the first install's console login failed.
# Not on argv either, where other processes could read it.
function Get-Sha512Crypt([string]$Password, [string]$Salt) {
  $argList = if ($Salt) { "passwd -6 -salt $Salt -stdin" } else { 'passwd -6 -stdin' }
  $psi = New-Object Diagnostics.ProcessStartInfo($openssl, $argList)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $p = [Diagnostics.Process]::Start($psi)
  $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Password + "`n")
  $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
  $p.StandardInput.Close()
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { Fail "openssl passwd exited with $($p.ExitCode)" }
  $out.Trim()
}

# --- Preconditions ------------------------------------------------------------
if (-not (Test-Path $template)) { Fail "Template not found: $template" }
if (-not (Test-Path $IsoPath))  { Fail "ISO not found: $IsoPath" }
if (-not (Test-Path $openssl))  { Fail "openssl not found at $openssl (comes with Git for Windows)" }

Step 'Verifying ISO against pinned checksum'
$isoName = Split-Path $IsoPath -Leaf
$expected = $PinnedIsoSha256[$isoName]
if (-not $expected) { Fail "$isoName is not a pinned ISO. Add its SHA256 to `$PinnedIsoSha256." }
$actual = (Get-FileHash $IsoPath -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { Fail "Checksum mismatch. expected $expected got $actual" }
Write-Host "    OK $actual"

Step "Checking that ${UsbDriveLetter}: is a USB disk"
$part = Get-Partition -DriveLetter $UsbDriveLetter -ErrorAction SilentlyContinue
if (-not $part) { Fail "No partition with drive letter ${UsbDriveLetter}:" }
$disk = Get-Disk -Number $part.DiskNumber
if ($disk.BusType -ne 'USB') { Fail "Disk $($disk.Number) ($($disk.FriendlyName)) is $($disk.BusType), not USB. Refusing." }
if ($disk.IsBoot -or $disk.IsSystem) { Fail "Disk $($disk.Number) is a boot/system disk. Refusing." }
$vol = Get-Volume -DriveLetter $UsbDriveLetter
if ($vol.FileSystem -ne 'FAT32') { Fail "${UsbDriveLetter}: is $($vol.FileSystem); UEFI boot needs FAT32. Reformat it as FAT32 first." }
Write-Host ("    Disk {0}: {1}, {2:N1} GB, volume '{3}' ({4})" -f $disk.Number, $disk.FriendlyName, ($disk.Size/1GB), $vol.FileSystemLabel, $vol.FileSystem)

Step "Fetching SSH public keys for github.com/$GitHubUser"
$keys = (Invoke-RestMethod "https://github.com/$GitHubUser.keys") -split "`n" | Where-Object { $_.Trim() }
if (-not $keys) { Fail "No public SSH keys on github.com/$GitHubUser. Add one at https://github.com/settings/keys first." }
$keys | ForEach-Object { Write-Host "    $($_.Substring(0, [Math]::Min(60, $_.Length)))..." }
$keyYaml = ($keys | ForEach-Object { '      - "' + (YamlDq $_.Trim()) + '"' }) -join "`n"

Step 'Secrets (typed here, written only to the USB stick)'
if (-not $WifiPassword) { $WifiPassword = Read-Host "    Wi-Fi password for '$WifiSsid'" -AsSecureString }
$wifiPw = Plain $WifiPassword
if ($wifiPw.Length -lt 8 -or $wifiPw.Length -gt 63) { Fail 'WPA passwords are 8-63 characters.' }
if ($LinuxPassword) {
  $pw1 = $pw2 = Plain $LinuxPassword
} else {
  $pw1 = Plain (Read-Host "    Linux password for user 'ops' (console/sudo fallback)" -AsSecureString)
  $pw2 = Plain (Read-Host '    Repeat it' -AsSecureString)
}
if ($pw1 -ne $pw2) { Fail 'Passwords do not match.' }
if ($pw1.Length -lt 8) { Fail 'Use at least 8 characters.' }
if ($pw1 -match '[\x00-\x1f\x7f]') { Fail 'Password contains a control character (newline/tab?). Retype it.' }
$hash = Get-Sha512Crypt $pw1
if ($hash -notmatch '^\$6\$([^$]+)\$') { Fail 'Failed to generate password hash.' }
# Self-check: re-hash with the same salt and compare.
if ((Get-Sha512Crypt $pw1 $Matches[1]) -ne $hash) { Fail 'Password hash did not verify. Not writing the stick.' }
Write-Host "    Password hash OK (salt $($Matches[1])). To double-check on Linux:"
Write-Host "      openssl passwd -6 -salt '$($Matches[1])'   # type the password; output must equal the hash on the stick"
$pw1 = $pw2 = $null

$yaml = (Get-Content $template -Raw) -replace "`r`n", "`n"
$yaml = $yaml.Replace('__PASSWORD_HASH__', (YamlDq $hash)).
              Replace('__WIFI_SSID__', (YamlDq $WifiSsid)).
              Replace('__WIFI_PASSWORD__', (YamlDq $wifiPw)).
              Replace('__SSH_AUTHORIZED_KEYS__', $keyYaml)
$wifiPw = $null
$unfilled = ($yaml -split "`n") | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '__[A-Z_]+__' }
if ($unfilled) { Fail "Unfilled placeholder in: $($unfilled[0].Trim())" }

Write-Host ''
Write-Host "About to ERASE everything on ${UsbDriveLetter}: ($($disk.FriendlyName)) and write the Ubuntu installer." -ForegroundColor Yellow
if (-not $Yes -and (Read-Host "Type ERASE to continue") -ne 'ERASE') { Fail 'Aborted.' }

Step "Erasing ${UsbDriveLetter}:\"
# Remove-Item -Recurse races on FAT32 ("directory is not empty"); rd /s /q is
# reliable. Retry a few times in case Windows is still releasing handles.
for ($i = 1; $i -le 3; $i++) {
  Get-ChildItem "${UsbDriveLetter}:\" -Force | Where-Object { $_.Name -ne 'System Volume Information' } | ForEach-Object {
    if ($_.PSIsContainer) { cmd /c "rd /s /q `"$($_.FullName)`"" 2>$null } else { cmd /c "del /f /q /a `"$($_.FullName)`"" 2>$null }
  }
  $left = Get-ChildItem "${UsbDriveLetter}:\" -Force | Where-Object { $_.Name -ne 'System Volume Information' }
  if (-not $left) { break }
  Start-Sleep -Seconds 2
}
if ($left) { Fail "Could not erase: $($left.Name -join ', ')" }

Step 'Extracting ISO to USB (a few minutes)'
# FAT32 can't hold symlinks. The ISO's only symlinks are apt-repo aliases
# (ubuntu -> ., dists/stable|unstable -> noble) that booting doesn't need.
# -m: don't restore mtimes (Windows refuses to set the time on a drive root).
tar -xmf $IsoPath -C "${UsbDriveLetter}:\" --exclude 'ubuntu' --exclude 'dists/stable' --exclude 'dists/unstable'
if ($LASTEXITCODE -ne 0) { Fail "tar exited with $LASTEXITCODE" }
# bsdtar keeps ISO read-only bits; clear them so the stick can be re-imaged later.
Get-ChildItem "${UsbDriveLetter}:\" -Recurse -Force | ForEach-Object { if ($_.Attributes -band 1) { $_.Attributes = $_.Attributes -bxor 1 } }

Step 'Writing /autoinstall.yaml'
[IO.File]::WriteAllText("${UsbDriveLetter}:\autoinstall.yaml", $yaml, (New-Object Text.UTF8Encoding($false)))

Step 'Verifying USB contents'
foreach ($f in 'EFI\boot\bootx64.efi', 'EFI\boot\grubx64.efi', 'boot\grub\grub.cfg', 'casper', '.disk\info', 'autoinstall.yaml') {
  if (-not (Test-Path "${UsbDriveLetter}:\$f")) { Fail "Missing on USB: $f" }
}
try { Set-Volume -DriveLetter $UsbDriveLetter -NewFileSystemLabel 'UBUNTU2404' -ErrorAction Stop } catch { }

Write-Host ''
Write-Host "Done. ${UsbDriveLetter}: is ready. Next: README.md -> 'Install'." -ForegroundColor Green
Write-Host "Use a REAR motherboard USB port: the desk hub failed to enumerate the stick."
Write-Host "Note: the stick now holds your Wi-Fi password in plain text. Wipe it after installing."
