# Talk to the V50's OpenWrt over LuCI's ubus JSON-RPC (rpcd) instead of SSH.
#
# Useful when ssh is not an option (a locked-down system, or a script that must not open a shell) and
# for anything the dashboard's own API does better than UCI: mu300dash (signal, SMS, AT, power, TTL),
# hostapd (kick a client), luci (password, LEDs, processes, realtime stats).
#
#   .\mu300-api.ps1 -Call system board
#   .\mu300-api.ps1 -Call uci get '{"config":"wireless","section":"radio0","option":"disabled"}'
#   .\mu300-api.ps1 -Call mu300dash signal
#   .\mu300-api.ps1 -Login                       just print a session id
#   .\mu300-api.ps1 -Raw '{"jsonrpc":"2.0","id":1,"method":"list","params":[]}'
#
# The request body is written to a file and sent with --data-binary @file. Do not inline the JSON on
# the command line: PowerShell's quoting turns it into a different string and rpcd answers with
# "Parse error" (-32700), which reads like a protocol problem instead of a quoting problem.
#
# The same trap applies one level up: passing -Params '{"a":"b"}' through a NESTED
# `powershell.exe -File mu300-api.ps1 ...` loses the quotes the second time. Either call this script
# directly from a PowerShell session, or hand the arguments over in a file with -Params '@file.json'
# (the same @ convention curl uses).
param(
  [string]$Host_ = '192.168.77.1',
  [string]$User = 'root',
  [string]$Password = $env:MU300_PASSWORD,   # 或 -Password 显式传入：不要把它写死在脚本里
  [string]$Endpoint = '/ubus',
  [string]$Sid,
  [string]$Call,          # "object method", with -Params for the arguments
  [string]$Params = '{}',
  [string]$Raw,
  [switch]$Login,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$curl = "$env:SystemRoot\System32\curl.exe"
$url  = "http://$Host_$Endpoint"
$tmp  = Join-Path $env:TEMP 'mu300-ubus-req.json'

# -Params '@file.json' reads the arguments from a file: the only form that survives a nested
# powershell.exe, a .cmd wrapper or a bash call without the caller having to reason about quotes
if ($Params.StartsWith('@')) {
  $pf = $Params.Substring(1)
  if (-not (Test-Path $pf)) { throw "no such params file: $pf" }
  $Params = [IO.File]::ReadAllText($pf).Trim()
}

function Send([string]$Json) {
  [IO.File]::WriteAllText($tmp, $Json, (New-Object Text.UTF8Encoding($false)))
  $r = & $curl -s --max-time 25 -X POST -H 'Content-Type: application/json' --data-binary "@$tmp" $url 2>&1
  return ($r | Out-String).Trim()
}

function Get-Sid {
  $body = '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","login",{"username":"' +
          $User + '","password":"' + $Password + '"}]}'
  $r = Send $body
  $m = [regex]::Match($r, '"ubus_rpc_session":"([0-9a-f]+)"')
  if (-not $m.Success) { throw "login failed: $r" }
  return $m.Groups[1].Value
}

if ($Raw) { Send $Raw; exit 0 }

if ($Login) { $s = Get-Sid; Write-Host $s; exit 0 }

if (-not $Call) { Get-Help $PSCommandPath -Detailed; exit 0 }

$parts = $Call.Trim() -split '\s+', 2
if ($parts.Count -lt 2) { throw '-Call needs "<object> <method>", e.g. -Call system board' }
$obj, $meth = $parts[0], $parts[1]

$useSid = $Sid
if (-not $useSid) { $useSid = Get-Sid }
if (-not $Quiet) { Write-Host "# session $useSid" -ForegroundColor DarkGray }

$res = Send ('{"jsonrpc":"2.0","id":2,"method":"call","params":["' + $useSid + '","' + $obj + '","' + $meth + '",' + $Params + ']}')
$res
