# Push a file to the V50's OpenWrt, in chunks.
#
#   .\push-file.ps1 -File <local> -To /opt/mu300/bin/mu300-led
#
# Why this exists instead of mu300.ps1 -Push: that one puts the whole base64 in a single command line, which is
# fine for a config file and dies on a script. mu300-led is 16.7 kB, so its base64 is 22.4 kB of argv, and
# dropbear's session dies with "client_loop: send disconnect: Connection reset" part way through - no error the
# caller can read, just a connection that went away mid-write. So: 2000 characters per ssh call, appended to a
# .b64 file on the device, and the decode only happens once the last chunk is in. That size was measured on this
# device; it is the point where a single argv stops being safe, not a round number from somewhere else.
#
# The device has no base64 in its system busybox (see mu300.ps1); /opt/mu300/bin/busybox has it.
param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$To,
    [string]$Host_ = '192.168.77.1',
    [string]$User = 'root',
    [string]$Key = "$env:USERPROFILE\.ssh\id_ed25519",
    [int]$Chunk = 2000
)
$ErrorActionPreference = 'Stop'

$local = (Resolve-Path $File).Path
$bytes = [IO.File]::ReadAllBytes($local)
$b64 = [Convert]::ToBase64String($bytes)
$want = (Get-FileHash $local -Algorithm SHA256).Hash.ToLower()
Write-Host ("pushing {0} ({1} bytes -> {2} base64, {3} chunks of {4})" -f `
    (Split-Path $local -Leaf), $bytes.Length, $b64.Length, [Math]::Ceiling($b64.Length / $Chunk), $Chunk)

$SSH_ARGS = @('-i', $Key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12',
              '-o', "UserKnownHostsFile=$env:TEMP\mu300_known_hosts", "$User@$Host_")
$BB = '/opt/mu300/bin/busybox'

function Remote([string]$Command) {
    $out = & ssh @SSH_ARGS $Command 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $out | ForEach-Object { Write-Host "  ssh: $_" }
        throw "ssh exited $code for: $Command"
    }
    return ($out | ForEach-Object { "$_" })
}

# Start from nothing: an interrupted earlier run must not leave a tail that gets decoded as if it were ours.
$stage = "/tmp/.push-$(Split-Path $To -Leaf)"
$b64path = "$stage.b64"
Remote ": > '$b64path'"

$n = 0
for ($i = 0; $i -lt $b64.Length; $i += $Chunk) {
    $n++
    $piece = $b64.Substring($i, [Math]::Min($Chunk, $b64.Length - $i))
    Remote "printf '%s' '$piece' >> '$b64path'"
    if ($n % 10 -eq 0) { Write-Host "  $n chunks" }
}
Write-Host "  $n chunks sent, decoding"

# Decode to a staging path first and compare the hash: a chunk that arrived mangled would otherwise be installed
# and only fail later, as a script that cannot run.
Remote "$BB base64 -d '$b64path' > '$stage' && chmod 755 '$stage'"
$got = (Remote "sha256sum '$stage'") -join ' '
if ($got -notmatch '^([0-9a-f]{64})') { throw "could not read the device's sha256sum: $got" }
if ($Matches[1] -ne $want) {
    throw "hash mismatch: device $($Matches[1]), local $want - not installing"
}
Write-Host "  sha256 ok on the device"

# Parse it on the device's own shell before it takes the place of a working script: ash is not bash, and the
# failure mode of a syntax error here is a script the kernel cannot run at all (no shebang read, silently skipped).
try { Remote "sh -n '$stage'" }
catch { throw "sh -n rejected '$stage' on the device's own ash - not installing: $($_.Exception.Message)" }
Write-Host "  sh -n ok on the device"

Remote "mv '$stage' '$To'"
Remote "ls -l '$To'"
Write-Host "installed: $To"
