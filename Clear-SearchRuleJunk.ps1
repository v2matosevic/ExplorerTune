<#
.SYNOPSIS
  Deletes accumulated junk from the Windows Search crawl rule registry: rules
  for drives that no longer exist, and the derived rule cache. Dry-run unless
  -Apply. Needs administrator.

.DESCRIPTION
  This is a cleanup, not a scope change. Use Set-SearchScope.ps1 to decide what
  gets indexed; that goes through the COM API and does not need admin.

  What accumulates here, and why it is worth clearing:

  WorkingSetRules is a derived cache. The indexer regenerates it from
  DefaultRules plus the user scope on startup, so it is safe to wipe, and
  wiping it discards years of stale entries. One machine had 794 rules in it,
  nearly all individual dependency subdirectories from projects that had been
  deleted long before. Every crawl decision walks that list.

  DefaultRules accumulates one whole-drive rule per volume ever attached.
  Rules for drives that are no longer present are pure dead weight; one machine
  carried 34 of them, 25 for removable G: volumes. The service restores rules
  for volumes that ARE present, so those are left alone deliberately - deleting
  them achieves nothing but a minute of confusion.

  WHAT THIS CANNOT DO
  It cannot add or change scope. Administrators have only ReadKey on
  DefaultRules and cannot create subkeys under UserScopeRules at all; the
  WSearch service owns both. See docs/search-scope.md.

.PARAMETER Apply
  Actually delete. Without it you get the plan and nothing else.

.PARAMETER Rebuild
  Also force a full reindex afterwards. Hours of background CPU, and searches
  are incomplete until it finishes. Off by default.
#>
[CmdletBinding()]
param([switch]$Apply, [switch]$Rebuild)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$CSM = 'HKLM:\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex'
$WSR = "$CSM\WorkingSetRules"
$DFR = "$CSM\DefaultRules"
$USR = "$CSM\UserScopeRules"

if (-not (Test-Path $CSM)) {
    Write-Host "  Windows Search is not set up on this machine." -ForegroundColor Red
    exit 1
}

$wsrCount = @(Get-ChildItem -LiteralPath $WSR -ErrorAction SilentlyContinue).Count
$live = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter })

# Whole-drive rules look like  file:///X:\[guid]\
$wholeDrive = @()
Get-ChildItem -LiteralPath $DFR -ErrorAction SilentlyContinue | ForEach-Object {
    $v = Get-ItemProperty -LiteralPath $_.PSPath
    if ($v.URL -match '^file:///([A-Z]):\\\[[0-9a-fA-F-]+\]\\$') {
        $wholeDrive += [pscustomobject]@{
            PSPath = $_.PSPath; Drive = $matches[1]; Live = ($live -contains $matches[1])
        }
    }
}
$ghosts = @($wholeDrive | Where-Object { -not $_.Live })

Write-Host ""
Write-Host "  CURRENT" -ForegroundColor White
Write-Host "    DefaultRules      : $(@(Get-ChildItem -LiteralPath $DFR -ErrorAction SilentlyContinue).Count)"
Write-Host "    WorkingSetRules   : $wsrCount   (derived cache)"
Write-Host "    UserScopeRules    : $(@(Get-ChildItem -LiteralPath $USR -ErrorAction SilentlyContinue).Count)"
Write-Host "    live drive letters: $($live -join ', ')"
Write-Host ""
if ($wholeDrive) {
    Write-Host "    whole-drive rules by drive:"
    $wholeDrive | Group-Object Drive | Sort-Object Name | ForEach-Object {
        $tag = if ($live -contains $_.Name) { 'live, left alone' } else { 'DRIVE NOT PRESENT, will delete' }
        Write-Host ("      {0}:  {1,2} rule(s)   {2}" -f $_.Name, $_.Count, $tag)
    }
    Write-Host ""
}

Write-Host "  PLAN" -ForegroundColor Cyan
Write-Host "    delete $wsrCount WorkingSetRules (derived; the indexer rebuilds it)"
Write-Host "    delete $($ghosts.Count) whole-drive rule(s) for absent drives"
Write-Host "    keep   whole-drive rules for present drives (the service restores them anyway)"
if ($Rebuild) { Write-Host "    force  full reindex (hours of background CPU)" }
Write-Host ""
if ($wsrCount -eq 0 -and $ghosts.Count -eq 0) {
    Say "nothing to clean." ok
    exit 0
}

if (-not $Apply) {
    Say "dry run. nothing was written. re-run with -Apply." warn
    exit 0
}

Assert-Elevated

$bk = New-BackupDir 'search-junk'
$exp = Backup-RegKey 'HKLM\SOFTWARE\Microsoft\Windows Search' $bk 'windows-search'
if (-not $exp) { Say "backup failed; refusing to continue" err; exit 1 }
Say "backup -> $bk  ($([math]::Round((Get-Item $exp).Length / 1KB, 0)) KB)" ok

Say "stopping WSearch..." plan
Stop-Service WSearch -Force -ErrorAction SilentlyContinue
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Service WSearch).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
if ((Get-Service WSearch).Status -ne 'Stopped') {
    Say "WSearch would not stop within 90s; aborting with nothing changed." err
    exit 1
}
Say "  stopped" ok

$n = 0; $nFail = 0
Get-ChildItem -LiteralPath $WSR -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop; $n++ } catch { $nFail++ }
}
Say "  deleted $n WorkingSetRules$(if ($nFail) { ", $nFail refused" })" $(if ($nFail) { 'warn' } else { 'ok' })

$g = 0; $gFail = 0
foreach ($w in $ghosts) {
    try { Remove-Item -LiteralPath $w.PSPath -Recurse -Force -ErrorAction Stop; $g++ } catch { $gFail++ }
}
Say "  deleted $g absent-drive rule(s)$(if ($gFail) { ", $gFail refused" })" $(if ($gFail) { 'warn' } else { 'ok' })

if ($Rebuild) {
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Search' `
        -Name 'SetupCompletedSuccessfully' -Value 0 -Type DWord -Force
    Say "  full reindex requested" ok
    Say "  (the service sets that flag back to 1 itself, so do not read it back" warn
    Say "   as confirmation - check progress with .\Set-SearchScope.ps1 -Status)" warn
}

Say "starting WSearch..." plan
Start-Service WSearch
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "  RESULT" -ForegroundColor White
Write-Host "    WSearch           : $((Get-Service WSearch).Status)"
Write-Host "    WorkingSetRules   : $(@(Get-ChildItem -LiteralPath $WSR -ErrorAction SilentlyContinue).Count)  (was $wsrCount)"
Write-Host ""
Write-Host "  Now decide what actually gets indexed:" -ForegroundColor Yellow
Write-Host "      .\Set-SearchScope.ps1              # plan" -ForegroundColor Yellow
Write-Host "      .\Set-SearchScope.ps1 -Apply" -ForegroundColor Yellow
Write-Host ""
Save-Log $bk
