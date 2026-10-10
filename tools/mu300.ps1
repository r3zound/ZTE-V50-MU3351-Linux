# Operate the V50's OpenWrt over SSH from Windows.
#
# The device runs dropbear, which has no sftp-server, so `scp` does not work: files go through
# base64 + the release's own busybox (the system busybox has no base64 applet). That is what -Push
# and -Pull do here.
#
#   .\mu300.ps1 -C "uci show wireless"                 run a command, print its output
#   .\mu300.ps1 -Shell                                 interactive shell
#   .\mu300.ps1 -Push .\local.conf /etc/foo.conf       copy a file to the device
#   .\mu300.ps1 -Pull /etc/config/network .\network    copy a file back
#   .\mu300.ps1 -Sudo -C "..."                         same, but also verify root (ssh is already root)
#
# Needs the SSH key on the device once (see docs/06-OpenWrt操作手册.md):
#   ssh-keygen + install the public key at /etc/dropbear/authorized_keys (mode 0600)
param(
  [string]$Host_ = '192.168.77.1',
  [string]$User = 'root',
  [string]$Key = "$env:USERPROFILE\.ssh\id_ed25519",
  [string]$C,
  [switch]$Shell,
  [string]$Push,
  [string]$To,
  [string]$Pull,
  [string]$Out,
  [int]$Timeout = 60
)
$ErrorActionPreference = 'Stop'
$target = "$User@$Host_"
$SSH_ARGS = @('-i', $Key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12',
              '-o', "UserKnownHostsFile=$env:TEMP\mu300_known_hosts", $target)

function Invoke-Remote([string]$Command) {
  $out = & ssh @SSH_ARGS $Command 2>&1
  $code = $LASTEXITCODE
  $out | ForEach-Object { $_ }
  if ($code -ne 0) { Write-Warning "ssh exited $code" }
}
# the device busybox that has base64: the system one does not
$BB = '/opt/mu300/bin/busybox'

if ($C) { Invoke-Remote $C; exit 0 }

if ($Shell) { & ssh @('-i', $Key, '-o', "UserKnownHostsFile=$env:TEMP\mu300_known_hosts", $target); exit 0 }

if ($Push) {
  if (-not $To) { throw '-Push needs -To <remote path>' }
  $bytes = [IO.File]::ReadAllBytes((Resolve-Path $Push))
  $b64 = [Convert]::ToBase64String($bytes)
  # one line at a time: an argument this long is fine, but keep the shell out of it
  $cmd = "printf '%s\n' '$b64' | $BB base64 -d > /tmp/.mu300-push.$$ && chmod 644 /tmp/.mu300-push.$$ && mv /tmp/.mu300-push.$$ '$To' && ls -l '$To' && sha256sum '$To'"
  Invoke-Remote $cmd
  # the same bytes through the same ssh: compare locally
  $local = (Get-FileHash (Resolve-Path $Push) -Algorithm SHA256).Hash.ToLower()
  Write-Host "local  sha256: $local"
  exit 0
}

if ($Pull) {
  if (-not $Out) { throw '-Pull needs -Out <local path>' }
  # base64 out of the device, decoded here: binary-safe, unlike a plain `ssh cat`
  $b64 = (& ssh @SSH_ARGS "$BB base64 '$Pull'" 2>&1) -join ''
  if (-not $b64) { throw "empty read from $Pull" }
  $bytes = [Convert]::FromBase64String(($b64 -replace '\s', ''))
  [IO.File]::WriteAllBytes($Out, $bytes)
  Write-Host "wrote $Out ($($bytes.Length) bytes)"
  exit 0
}

Get-Help $PSCommandPath -Detailed
