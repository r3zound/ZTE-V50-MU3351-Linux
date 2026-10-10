# Read whatever the MU300 Linux ACM console is sending, and try to push a line in.
# Must run in the main PowerShell (not Start-Job): System.IO.Ports lives in this process.
param(
  [string]$Port = 'COM12',
  [int]$Baud = 115200,
  [int]$ReadSeconds = 15,
  [string[]]$Commands = @()
)
$p = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$p.ReadTimeout = 250
$p.WriteTimeout = 3000
$p.Handshake = 'None'
$p.DtrEnable = $false
$p.RtsEnable = $false
$p.Open()
$sb = New-Object System.Text.StringBuilder
$errs = @()
try {
    foreach ($c in $Commands) {
        try { $p.Write("$c`r`n") } catch { $errs += "write('$c'): $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 500
    }
    $deadline = (Get-Date).AddSeconds($ReadSeconds)
    while ((Get-Date) -lt $deadline) {
        try { [void]$sb.Append($p.ReadExisting()) } catch { }
        Start-Sleep -Milliseconds 250
    }
} finally { $p.Close() }

"READ_BYTES=$($sb.Length)"
if ($errs.Count) { "WRITE_ERRORS: " + ($errs -join ' | ') }
$txt = $sb.ToString() -replace "`r",''
if ($txt.Trim()) { "----- CONSOLE -----"; $txt } else { "(console produced no output)" }
