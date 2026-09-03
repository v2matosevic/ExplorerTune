<#
.SYNOPSIS
  Registers (or removes) the scheduled task that runs Watch-Explorer.ps1.

.DESCRIPTION
  Runs in your own user context, every -EveryMinutes, hidden. It does not need
  SYSTEM: restarting the shell is a per-user action.

  The task only *checks*. Watch-Explorer.ps1 decides whether to act, and holds
  off whenever an Explorer window is open or you are at the keyboard, so a
  restart lands in a gap rather than under your hands.

.PARAMETER EveryMinutes
  Check interval. Default 30.

.PARAMETER Uninstall
  Remove the task.

.EXAMPLE
  .\Install-Watchdog.ps1
  .\Install-Watchdog.ps1 -Uninstall
#>
[CmdletBinding()]
param([int]$EveryMinutes = 30, [switch]$Uninstall)

$TaskName = 'ExplorerTune Watchdog'
$script = Join-Path $PSScriptRoot 'Watch-Explorer.ps1'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "  removed scheduled task '$TaskName'" -ForegroundColor Green
    }
    else { Write-Host "  no such task" -ForegroundColor Yellow }
    exit 0
}

if (-not (Test-Path $script)) { Write-Host "  cannot find $script" -ForegroundColor Red; exit 1 }

# pwsh if present, otherwise the in-box Windows PowerShell
$exe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $exe) { $exe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }

$action = New-ScheduledTaskAction -Execute $exe `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script)

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force `
        -Description 'ExplorerTune: restarts explorer.exe when it drifts past a handle/memory threshold, but only while idle with no Explorer windows open.' | Out-Null
    Write-Host "  registered '$TaskName' - checks every $EveryMinutes min" -ForegroundColor Green
    Write-Host "  log: $(Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\watchdog.csv')" -ForegroundColor Gray
    Write-Host "  test it now:  .\Watch-Explorer.ps1 -WhatIf" -ForegroundColor Gray
}
catch {
    Write-Host "  registration failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  try again from an elevated shell" -ForegroundColor Yellow
    exit 1
}
