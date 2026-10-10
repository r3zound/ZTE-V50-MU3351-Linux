# Watch for the device coming up as Linux: USB enumerates as CDC NCM / RNDIS instead of adb, and the
# hotspot shows up in the PC's scan. Reports every poll so a silent boot is obvious.
#
# Pass your own hotspot name: -Ssid "MyHotspot". It is imported from Android at install time, so it
# differs per device - do not hard-code one, and do not hard-code a fragment of one either: the tail
# of a ZTE hotspot name is derived from the device's WiFi MAC, so shipping it leaks a device identifier.
param(
  [int]$Seconds = 300,
  [string]$Ssid = '',
  [string]$SsidAlso = ''
)
$ErrorActionPreference = 'Continue'
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$end = (Get-Date).AddSeconds($Seconds)
$seenUsb = @{}
$seenSsid = $false

while ((Get-Date) -lt $end) {
    $t = Get-Date -Format 'HH:mm:ss'

    # USB: what does the device enumerate as now?
    $usb = (Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'VID_19D2|VID_1782|Composite|CDC|RNDIS|Android' } |
            ForEach-Object { $_.Name }) | Sort-Object -Unique
    foreach ($u in $usb) {
        if (-not $seenUsb.ContainsKey($u)) { $seenUsb[$u] = 1; "[$t] USB  + $u" }
    }

    $d = (& $adb devices 2>$null | Out-String)
    if ($d -match '<设备序列号>\s+device') { "[$t] ABD  Android adb is up" }

    # WiFi: scan
    if ($Ssid) {
        $nets = (netsh wlan show networks mode=bssid 2>$null | Out-String)
        $hit = $nets -match [regex]::Escape($Ssid) -or ($SsidAlso -and $nets -match [regex]::Escape($SsidAlso))
        if ($hit -and -not $seenSsid) { $seenSsid = $true; "[$t] WIFI '$Ssid' IS BROADCASTING" }
    }

    Start-Sleep -Seconds 10
}
"[$(Get-Date -Format 'HH:mm:ss')] done. hotspot seen = $seenSsid"
