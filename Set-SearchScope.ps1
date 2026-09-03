<#
.SYNOPSIS
  Sets the Windows Search crawl scope so Explorer's search box returns your
  files instead of build output. Dry-run unless -Apply.

.DESCRIPTION
  Reads Search.Include, Search.Exclude, Search.NoiseDirs and Search.NoiseDepths
  from explorertune.config.psd1 and applies them through
  ISearchCrawlScopeManager.

  This does NOT need administrator rights. It also cannot be done from the
  registry: those keys deny writes even to an elevated Administrator, and the
  WSearch service rewrites them on every start. See docs/search-scope.md.

  WHY THE EXCLUSIONS LOOK REPETITIVE
  Windows Search has no recursive name rule. A '*' in a crawl rule matches
  exactly one path segment, which the shipped defaults themselves demonstrate
  ('file:///*\$RECYCLE.BIN\'). There is no '**\node_modules'. So each name in
  NoiseDirs needs one rule per nesting depth, and NoiseDepths says how deep to
  go. That is a limit of the component, not a workaround.

.PARAMETER Apply
  Actually change the scope. Without it you get the plan and nothing else.

.PARAMETER Test
  Ask the indexer whether these paths are in scope, then exit. This is the only
  trustworthy way to check: the registry reports rules that are not in effect.

.PARAMETER Status
  Print catalog status and item count, then exit.

.EXAMPLE
  .\Set-SearchScope.ps1
  .\Set-SearchScope.ps1 -Apply
  .\Set-SearchScope.ps1 -Test 'C:\Projects','C:\Projects\app\node_modules'
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$Test,
    [switch]$Status,
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Config.ps1')
. (Join-Path $PSScriptRoot 'lib\SearchApi.ps1')

$cfg = Get-ETConfig -Path $ConfigPath

function ConvertTo-ScopeUrl([string]$p) { 'file:///' + ($p.TrimEnd('\')) + '\' }

# ------------------------------------------------------------- connect ----

Say "connecting to the Windows Search catalog..." plan
$conn = Connect-SearchApi
foreach ($line in ($conn.Report -split "`r?`n")) { if ($line.Trim()) { Say "  $line" } }

if (-not $conn.Validated) {
    Say ""
    Say "The COM interface layout on this Windows build could not be verified," err
    Say "so no mutating call will be made. Read-only checks may still work." err
    Say "Please open an issue with the report above and this build number:" err
    Say "  $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild)" err
    if (-not $Test -and -not $Status) { exit 1 }
}

# --------------------------------------------------------------- modes ----

if ($Test) {
    Write-Host ""
    Write-Host "  SCOPE TEST (asking the indexer, not the registry)" -ForegroundColor White
    foreach ($t in $Test) {
        $u = if ($t -like 'file:///*') { $t } else { ConvertTo-ScopeUrl (Expand-ETPath $t) }
        $r = try { [ET.Search.Api]::IsInScope($u) } catch { "error: $($_.Exception.Message)" }
        Write-Host ("    {0,-62} {1}" -f $u, $r)
    }
    Write-Host ""
    exit 0
}

$st = [ET.Search.Api]::Status()
$items = [ET.Search.Api]::ItemCount()
Write-Host ""
Write-Host "  CATALOG" -ForegroundColor White
Write-Host "    status        : $(Get-SearchCatalogStatusName $st)"
Write-Host "    indexed items : $(if ($items -ge 0) { '{0:N0}' -f $items } else { 'unavailable' })"
Write-Host "    config        : $($cfg.Source)"
Write-Host ""

if ($Status) { exit 0 }

# ---------------------------------------------------------------- plan ----

$includes = @()
$excludes = @()

foreach ($p in $cfg.Search.Include) {
    if (-not (Test-Path -LiteralPath $p)) { Say "  skipping Include '$p' - path does not exist" warn; continue }
    $includes += ConvertTo-ScopeUrl $p
    foreach ($d in 1..([int]$cfg.Search.NoiseDepths)) {
        $stars = ('*\' * $d)
        foreach ($n in $cfg.Search.NoiseDirs) {
            $excludes += 'file:///' + $p.TrimEnd('\') + '\' + $stars + $n + '\'
        }
    }
}
foreach ($p in $cfg.Search.Exclude) { $excludes += ConvertTo-ScopeUrl $p }

if (-not $includes -and -not $excludes) {
    Say "nothing to do: Search.Include and Search.Exclude are both empty." warn
    Say "copy explorertune.config.example.psd1 to explorertune.config.psd1 and edit it." warn
    exit 0
}

Write-Host "  PLAN" -ForegroundColor Cyan
foreach ($u in $includes) { Write-Host "    include  $u" }
Write-Host "    exclude  $($excludes.Count) rule(s):"
Write-Host "               $($cfg.Search.NoiseDirs.Count) noise dir name(s) x $($cfg.Search.NoiseDepths) depth(s) under $($includes.Count) include path(s)"
foreach ($p in $cfg.Search.Exclude) { Write-Host "               plus whole subtree $p" }
Write-Host ""
Write-Host "    Include rules are added with overrideChildren=true so they win" -ForegroundColor Gray
Write-Host "    over any broader exclusion already in place." -ForegroundColor Gray
Write-Host ""

if (-not $Apply) {
    Say "dry run. nothing was changed. re-run with -Apply." warn
    exit 0
}

# --------------------------------------------------------------- apply ----

$bk = New-BackupDir 'search'
Backup-RegKey 'HKLM\SOFTWARE\Microsoft\Windows Search' $bk 'windows-search' | Out-Null
Say "backup -> $bk" ok
Say "  (that export is a record, not a full undo: the live scope lives in the"
Say "   service, not the registry. Undo through Indexing Options, or re-run"
Say "   this with an edited config.)"

$nInc = 0; $nExc = 0; $failed = @()
foreach ($u in $includes) {
    try { [ET.Search.Api]::AddRule($u, $true, $true); $nInc++ }
    catch { $failed += "include $u : $($_.Exception.Message)" }
}
foreach ($u in $excludes) {
    try { [ET.Search.Api]::AddRule($u, $false, $false); $nExc++ }
    catch { $failed += "exclude $u : $($_.Exception.Message)" }
}
Say "  accepted $nInc include and $nExc exclude rule(s)" $(if ($failed) { 'warn' } else { 'ok' })
foreach ($f in ($failed | Select-Object -First 10)) { Say "  FAILED $f" err }
if ($failed.Count -gt 10) { Say "  ...and $($failed.Count - 10) more" err }

try { [ET.Search.Api]::SaveAll(); Say "  SaveAll committed" ok }
catch { Say "  SaveAll FAILED: $($_.Exception.Message)" err; exit 1 }

# -------------------------------------------------------------- verify ----
# Ask the indexer, not the registry, and build the checks from the config so
# this verifies what was actually requested rather than a hardcoded example.

Start-Sleep -Seconds 3
$checks = @()
foreach ($p in $cfg.Search.Include) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $checks += @{ Url = ConvertTo-ScopeUrl $p; Want = $true; What = "include: $p" }
    $child = Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue |
        Where-Object { $cfg.Search.NoiseDirs -notcontains $_.Name } | Select-Object -First 1
    if ($child) { $checks += @{ Url = ConvertTo-ScopeUrl $child.FullName; Want = $true; What = "a folder inside it: $($child.Name)" } }
    foreach ($n in $cfg.Search.NoiseDirs) {
        $hit = Get-ChildItem -LiteralPath $p -Directory -Filter $n -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $checks += @{ Url = ConvertTo-ScopeUrl $hit.FullName; Want = $false; What = "noise dir: ...\$n" }; break }
    }
}
foreach ($p in $cfg.Search.Exclude) {
    if (Test-Path -LiteralPath $p) { $checks += @{ Url = ConvertTo-ScopeUrl $p; Want = $false; What = "exclude: $p" } }
}

Write-Host ""
Write-Host "  VERIFY (asking the crawl scope manager directly)" -ForegroundColor White
$bad = 0
foreach ($c in $checks) {
    $r = try { [ET.Search.Api]::IsInScope($c.Url) } catch { $null }
    $ok = ($r -eq $c.Want)
    if (-not $ok) { $bad++ }
    Write-Host ("    {0,-44} in scope = {1,-5} want {2,-5} {3}" -f $c.What, $r, $c.Want, $(if ($ok) { 'ok' } else { 'MISMATCH' })) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
Write-Host ""
if ($bad) { Say "$bad check(s) did not come out as intended - see above" warn }
else { Say "scope is what the config asked for." ok }

Write-Host "  Reindex progress: -Status here, or Control Panel -> Indexing Options." -ForegroundColor Gray
Write-Host "  Undo: Indexing Options -> Modify." -ForegroundColor Yellow
Save-Log $bk
