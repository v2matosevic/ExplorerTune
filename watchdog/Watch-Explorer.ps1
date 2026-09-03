<#
.SYNOPSIS
  Restarts explorer.exe when it has drifted past a threshold, and only when
  doing so is invisible to you.

.DESCRIPTION
  The Win11 XAML shell accumulates handles and threads with uptime. Measured on
  this machine: 8,032 handles / 304 threads / 633 MB private after 136 hours.
  No registry setting fixes that; only a restart does.

  A restart closes open Explorer windows, so this refuses to act unless:
    - a threshold is actually exceeded, AND
    - no Explorer windows are open, AND
    - you have been idle for at least -IdleMinutes, AND
    - the last restart was more than -CooldownHours ago.

  Every check appends one row to logs\watchdog.csv, so the drift rate is
  visible over time rather than guessed at.

.PARAMETER MaxHandles
  Restart above this handle count. Default 5000.

.PARAMETER MaxPrivateMB
  Restart above this private-bytes figure. Default 450.

.PARAMETER IdleMinutes
  Require this much keyboard/mouse idle before restarting. Default 5.

.PARAMETER CooldownHours
  Never restart more often than this. Default 6.

.PARAMETER Force
  Ignore the idle, window and cooldown guards. Still respects thresholds.

.PARAMETER WhatIf
  Report the decision without acting.
#>
[CmdletBinding()]
param(
    [int]$MaxHandles,
    [int]$MaxPrivateMB,
    [int]$IdleMinutes = -1,
    [int]$CooldownHours = -1,
    [switch]$Force,
    [switch]$WhatIf
)

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Config.ps1')

# Explicit parameters win; anything not passed comes from Watchdog.* in config.
$cfg = Get-ETConfig
if (-not $MaxHandles)        { $MaxHandles = [int]$cfg.Watchdog.MaxHandles }
if (-not $MaxPrivateMB)      { $MaxPrivateMB = [int]$cfg.Watchdog.MaxPrivateMB }
if ($IdleMinutes -lt 0)      { $IdleMinutes = [int]$cfg.Watchdog.IdleMinutes }
if ($CooldownHours -lt 0)    { $CooldownHours = [int]$cfg.Watchdog.CooldownHours }

$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$csv = Join-Path $logDir 'watchdog.csv'
$stamp = Join-Path $logDir 'last-restart.txt'

# --- idle time, via GetLastInputInfo ---
if (-not ('ET.Idle' -as [type])) {
    Add-Type -Namespace ET -Name Idle -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
[DllImport("kernel32.dll")] public static extern uint GetTickCount();
public static double IdleSeconds() {
    LASTINPUTINFO lii = new LASTINPUTINFO();
    lii.cbSize = (uint)Marshal.SizeOf(lii);
    if (!GetLastInputInfo(ref lii)) return -1;
    return (GetTickCount() - lii.dwTime) / 1000.0;
}
'@
    # No -UsingNamespace here: Add-Type -MemberDefinition already emits
    # 'using System.Runtime.InteropServices;' and a second one is CS0105.
}
$idleMin = [math]::Round([ET.Idle]::IdleSeconds() / 60, 1)

# --- open Explorer windows ---
$openWindows = -1
try {
    $sh = New-Object -ComObject Shell.Application
    $openWindows = @($sh.Windows() | Where-Object { $_.FullName -and (Split-Path $_.FullName -Leaf) -eq 'explorer.exe' }).Count
}
catch { Write-Verbose "could not count Explorer windows: $($_.Exception.Message)" }

# --- cooldown ---
$sinceLast = [double]::PositiveInfinity
if (Test-Path $stamp) {
    $last = Get-Content $stamp -Raw
    if ($last -as [datetime]) { $sinceLast = [math]::Round(((Get-Date) - [datetime]$last).TotalHours, 2) }
}

$v = Get-ExplorerVitals
if (-not $v) {
    "$(Get-Date -f s),,,,,,no-explorer" | Add-Content $csv
    Write-Host "  explorer.exe is not running"
    exit 0
}

$overHandles = $v.Handles -gt $MaxHandles
$overMemory  = $v.PrivMB -gt $MaxPrivateMB
$over        = $overHandles -or $overMemory

$reasons = @()
if (-not $over) { $reasons += "under thresholds" }
if (-not $Force) {
    if ($openWindows -gt 0) { $reasons += "$openWindows Explorer window(s) open" }
    if ($idleMin -ge 0 -and $idleMin -lt $IdleMinutes) { $reasons += "idle only $idleMin min" }
    if ($sinceLast -lt $CooldownHours) { $reasons += "restarted $sinceLast h ago" }
}
$act = ($over -and ($Force -or $reasons.Count -eq 0))

$why = if ($act) { "restart" } elseif ($reasons) { "hold: " + ($reasons -join '; ') } else { "hold" }

if (-not (Test-Path $csv)) {
    "when,pid,handles,privMB,threads,uptimeH,idleMin,openWindows,action" | Set-Content $csv -Encoding UTF8
}
"{0},{1},{2},{3},{4},{5},{6},{7},{8}" -f (Get-Date -f s), $v.Id, $v.Handles, $v.PrivMB, $v.Threads, $v.UptimeH, $idleMin, $openWindows, $why |
    Add-Content $csv -Encoding UTF8

Write-Host ("  explorer.exe pid {0}: {1} handles, {2} MB private, {3} threads, up {4} h" -f $v.Id, $v.Handles, $v.PrivMB, $v.Threads, $v.UptimeH)
Write-Host ("  thresholds: handles>{0} {1}   private>{2}MB {3}" -f $MaxHandles, $(if ($overHandles) { 'HIT' } else { 'ok' }), $MaxPrivateMB, $(if ($overMemory) { 'HIT' } else { 'ok' }))
Write-Host ("  decision: {0}" -f $why) -ForegroundColor $(if ($act) { 'Yellow' } else { 'Gray' })

if (-not $act) { exit 0 }
if ($WhatIf) { Write-Host "  -WhatIf, not restarting"; exit 0 }

& (Join-Path $root 'Restart-Explorer.ps1') -Quiet
(Get-Date).ToString('o') | Set-Content $stamp -Encoding UTF8
Start-Sleep -Seconds 10
$n = Get-ExplorerVitals
Write-Host ("  restarted: {0} -> {1} handles, {2} -> {3} MB" -f $v.Handles, $n.Handles, $v.PrivMB, $n.PrivMB) -ForegroundColor Green
"{0},{1},{2},{3},{4},{5},,,after-restart" -f (Get-Date -f s), $n.Id, $n.Handles, $n.PrivMB, $n.Threads, $n.UptimeH | Add-Content $csv -Encoding UTF8
