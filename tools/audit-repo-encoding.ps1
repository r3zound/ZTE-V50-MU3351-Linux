# Audit every text file that ends up on the device (or is executed by the installer) for encodings
# and line endings that silently break it on Linux.
#   UTF-16  -> the kernel cannot parse the shebang; busybox init fails the script with no message
#   BOM     -> same, the shebang starts with EF BB BF
#   CRLF    -> /bin/sh trips over the CR on the first line that matters ("\r: not found")
param([string]$Repo = "D:\OneDrive\User\Network\CPE\V50\tools\mu300-linux")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem 2>$null | Out-Null

$roots = @('openwrt\overlay', 'openwrt\vendor-extra', 'rootfs\overlay', 'boot', 'tools', 'openwrt')
$skipExt = '^\.(ko|img|bin|png|jpg|jpeg|gz|xz|bz2|zip|tar|so|elf|o|pyc|woff2?|ttf|pdf|deb)$'

$seen = @{}
$bad = @()
foreach ($r in $roots) {
    $p = Join-Path $Repo $r
    if (-not (Test-Path $p)) { continue }
    Get-ChildItem -Recurse -File -Path $p -ErrorAction SilentlyContinue | ForEach-Object {
        if ($seen.ContainsKey($_.FullName)) { return }
        $seen[$_.FullName] = $true
        if ($_.Extension -match $skipExt) { return }
        if ($_.Length -gt 2MB) { return }
        $b = [IO.File]::ReadAllBytes($_.FullName)
        if ($b.Length -lt 4) { return }
        $why = @()
        if ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $why += 'UTF16LE' }
        elseif ($b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $why += 'UTF16BE' }
        elseif ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $why += 'UTF8-BOM' }
        if ($why.Count -eq 0) {
            # NUL byte in the first 512 -> some other wide/UTF-16-ish encoding
            $probe = [Math]::Min(512, $b.Length)
            for ($i = 0; $i -lt $probe; $i++) { if ($b[$i] -eq 0) { $why += 'NUL-near-start'; break } }
        }
        if ($why.Count -eq 0 -and $b.Length -ge 4096) {
            $head = [Text.Encoding]::ASCII.GetString($b, 0, [Math]::Min(4096, $b.Length))
            if ($head -match "`r`n") { $why += 'CRLF' }
        }
        if ($why.Count) { $bad += [pscustomobject]@{ File = $_.FullName.Substring($Repo.Length + 1); Why = ($why -join ',') } }
    }
}

Write-Host ("scanned {0} files, {1} suspect" -f $seen.Count, $bad.Count)
$bad | Sort-Object Why, File | Format-Table -AutoSize
if ($bad.Count -gt 0) { exit 1 }
