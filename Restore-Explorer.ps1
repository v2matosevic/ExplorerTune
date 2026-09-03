<#
.SYNOPSIS
  Puts back whatever a previous Optimize-Explorer.ps1 or Set-SearchScope.ps1 run changed.

.DESCRIPTION
  Every run writes .reg exports into backups\<timestamp>-<tag>\ before it
  touches anything. This imports them. Registry import is additive for values
  and keys, which is exactly what we need: deleted keys come back, and the
  Blocked list entries we added are removed explicitly since an import cannot
  delete a value that the backup simply lacked.

.PARAMETER From
  Backup directory. Omit to use the newest one.

.PARAMETER List
  Show available backups and exit.

.EXAMPLE
  .\Restore-Explorer.ps1 -List
  .\Restore-Explorer.ps1                       # newest backup
  .\Restore-Explorer.ps1 -From .\backups\20260903-151200-shell
#>
[CmdletBinding()]
param([string]$From, [switch]$List)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$root = Join-Path $PSScriptRoot 'backups'
if (-not (Test-Path $root)) { Write-Host "  no backups directory - nothing to restore" -ForegroundColor Yellow; exit 0 }

$all = Get-ChildItem $root -Directory | Sort-Object Name -Descending
if ($List -or -not $all) {
    if (-not $all) { Write-Host "  no backups found" -ForegroundColor Yellow; exit 0 }
    $all | ForEach-Object {
        $files = @(Get-ChildItem $_.FullName -Filter *.reg)
        "  {0,-34} {1} key export(s)" -f $_.Name, $files.Count
    }
    exit 0
}

if (-not $From) { $From = $all[0].FullName; Write-Host "  using newest backup: $($all[0].Name)" -ForegroundColor Cyan }
if (-not (Test-Path $From)) { Write-Host "  no such backup: $From" -ForegroundColor Red; exit 1 }

Assert-Elevated

$regs = @(Get-ChildItem $From -Filter *.reg)
if (-not $regs) { Write-Host "  that backup has no .reg files" -ForegroundColor Red; exit 1 }

# 1. Remove every Blocked-list value ExplorerTune added. An import cannot do
#    this, because the backup was taken before the values existed.
$removed = 0
foreach ($p in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked')) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    (Get-ItemProperty -LiteralPath $p).PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' -and $_.Value -like 'ExplorerTune:*' } |
        ForEach-Object {
            Remove-ItemProperty -LiteralPath $p -Name $_.Name -Force -ErrorAction SilentlyContinue
            $removed++
            Say "  unblocked $($_.Name)" ok
        }
}

# 2. Import every exported key.
$ok = 0; $bad = 0
foreach ($r in $regs) {
    $out = & reg.exe import $r.FullName 2>&1
    if ($LASTEXITCODE -eq 0) { $ok++; Say "  imported $($r.Name)" ok }
    else { $bad++; Say "  FAILED   $($r.Name): $out" err }
}

# 3. If the search scope was part of this backup, the indexer must be bounced.
if ($regs.Name -contains 'windows-search.reg') {
    Say "  search scope was restored; restarting WSearch" plan
    Restart-Service WSearch -Force -ErrorAction SilentlyContinue
}

Say ""
Say "restored $ok key export(s), removed $removed block entry, $bad failure(s)." $(if ($bad) { 'warn' } else { 'ok' })
Say "restarting explorer.exe" plan
& (Join-Path $PSScriptRoot 'Restart-Explorer.ps1')
