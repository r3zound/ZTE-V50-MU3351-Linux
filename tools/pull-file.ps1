# Pull a file off the V50's OpenWrt to this PC.
#
#   .\pull-file.ps1 -From /sys/firmware/fdt -To .\work\linux-fdt.dtb
#
# The mirror image of push-file.ps1, and for the same reason: this has to survive files that are far past the
# ~12 kB of argv that dropbear's session can take, so the transfer goes through base64 on stdout (stdout has no
# such limit - only argv does). The device's system busybox has no base64; /opt/mu300/bin/busybox does.
param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To,
    [string]$Host_ = '192.168.77.1',
    [string]$User = 'root',
    [string]$Key = "$env:USERPROFILE\.ssh\id_ed25519"
)
$ErrorActionPreference = 'Stop'

$SSH_ARGS = @('-i', $Key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12',
              '-o', "UserKnownHostsFile=$env:TEMP\mu300_known_hosts", "$User@$Host_")
$BB = '/opt/mu300/bin/busybox'

$outDir = Split-Path -Parent $To
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$tmp = "$To.b64"
if (Test-Path $tmp) { Remove-Item -Force $tmp }

Write-Host "pulling $From -> $To"
# Start-Process with a file redirect keeps PowerShell out of the byte path: a 300 kB blob piped through the
# object pipeline comes back as thousands of strings and gets mangled. -NoNewWindow + -Wait is non-interactive.
$p = Start-Process -FilePath 'ssh' -ArgumentList ($SSH_ARGS + @("$BB base64 $From")) `
    -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err"
if ($p.ExitCode -ne 0) {
    Get-Content "$tmp.err" | ForEach-Object { Write-Host "  ssh: $_" }
    throw "ssh exited $($p.ExitCode)"
}
$err = (Get-Content "$tmp.err" -Raw -ErrorAction SilentlyContinue)
if ($err -and $err.Trim()) { $err.Trim() -split "`n" | ForEach-Object { Write-Host "  ssh: $($_.Trim())" } }

$b64 = (Get-Content $tmp -Raw) -replace '\s', ''
[IO.File]::WriteAllBytes($To, [Convert]::FromBase64String($b64))
$want = (Get-FileHash $To -Algorithm SHA256).Hash.ToLower()
Write-Host ("  got {0} bytes, sha256 {1}" -f (Get-Item $To).Length, $want)
Remove-Item -Force $tmp, "$tmp.err" -ErrorAction SilentlyContinue