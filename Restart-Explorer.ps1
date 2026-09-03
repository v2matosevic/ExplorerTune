<#
.SYNOPSIS
  Restarts the Explorer shell. Closes open Explorer windows; loses nothing else.

.DESCRIPTION
  Windows normally relaunches the shell itself (AutoRestartShell=1). This
  verifies that it did, and starts it manually if it did not, so you are never
  left staring at an empty desktop.

  With SeparateProcess=1 there can be several explorer.exe. All of them go; the
  shell one comes back and folder windows do not.
#>
[CmdletBinding()]
param([switch]$Quiet)

$script:BeQuiet = [bool]$Quiet
function Note($m) { if (-not $script:BeQuiet) { Write-Host $m -ForegroundColor Gray } }

$autoRestart = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoRestartShell -ErrorAction SilentlyContinue).AutoRestartShell

$before = Get-Process explorer -ErrorAction SilentlyContinue
Note "  stopping $($before.Count) explorer.exe process(es)..."
$before | Stop-Process -Force -ErrorAction SilentlyContinue

$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Get-Process explorer -ErrorAction SilentlyContinue) { break }
}

if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
    # Never launch the shell from an elevated process. It would inherit the
    # elevated token: drag and drop from unelevated apps stops working, and
    # every child process it spawns runs as administrator.
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated) {
        Write-Host "  Shell did not auto-restart, and this session is ELEVATED." -ForegroundColor Red
        Write-Host "  Refusing to start explorer.exe from here - it would run as administrator." -ForegroundColor Red
        Write-Host "  Run .\Restart-Explorer.ps1 from a normal (non-admin) PowerShell instead." -ForegroundColor Yellow
        exit 2
    }
    Note "  shell did not come back on its own (AutoRestartShell=$autoRestart); starting it"
    Start-Process explorer.exe
    Start-Sleep -Seconds 3
}

$now = Get-Process explorer -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
if ($now) {
    Note "  explorer.exe back as pid $($now.Id)"
}
else {
    Write-Host "  explorer.exe did NOT restart. Press Ctrl+Shift+Esc -> Run new task -> explorer.exe" -ForegroundColor Red
    exit 1
}
