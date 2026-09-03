<#
.SYNOPSIS
  Cuts the shell-extension tax on Windows File Explorer. Dry-run unless -Apply.

.DESCRIPTION
  Explorer loads third-party DLLs into its own process and runs them on every
  right-click, every property read and every thumbnail. This does three things
  about that:

    1. DEAD REGISTRATIONS ARE DELETED. Any hook whose CLSID resolves to no COM
       server is a leftover from uninstalled software. Explorer still tries to
       instantiate it on every right-click and every icon paint, and eats the
       failure. Detected automatically, on by default, and it is the one change
       here that is universally safe.

    2. HANDLERS YOU NAME ARE BLOCKED, not deleted. Their CLSID is added to
       HKLM\...\Shell Extensions\Blocked in both registry views, and Explorer
       refuses to load the DLL. The vendor's install is untouched, so an update
       will not fight it, and undo is deleting one value.
       Nothing is blocked unless you list it - see handlers/catalog.psd1 for
       what each entry costs, then set Handlers.Block in your config, or pass
       -Block <ids>.

    3. TWO EXPLORER SETTINGS, both from config: folder windows in their own
       process, and the Office/Graph "Recommended" fetch on Home turned off.

  Blocking a shell extension removes a menu or a badge. Read the Note field in
  the catalog before blocking something you rely on.

.PARAMETER Apply
  Actually write. Without it you get the plan and nothing else.

.PARAMETER Block
  Catalog ids to block on this run, in addition to Handlers.Block in config.

.PARAMETER Only
  Restrict this run to these catalog ids.

.PARAMETER Skip
  Exclude these catalog ids from this run.

.PARAMETER List
  Print the catalog, marking which entries are actually present on this machine,
  then exit.

.PARAMETER NoDeadRemoval
  Leave dead registrations alone.

.PARAMETER ResetShellbags
  Delete the BagMRU/Bags tree. This loses per-folder view preferences (column
  widths, sort order, view mode) for every folder you have ever opened. Off by
  default.

.PARAMETER NoRestart
  Do not restart Explorer at the end. Changes take effect on the next restart.

.EXAMPLE
  .\Optimize-Explorer.ps1 -List
  .\Optimize-Explorer.ps1                                  # plan only
  .\Optimize-Explorer.ps1 -Apply                           # dead removal + config
  .\Optimize-Explorer.ps1 -Apply -Block filezilla,recuva
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$Block,
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$List,
    [switch]$NoDeadRemoval,
    [switch]$ResetShellbags,
    [switch]$NoRestart,
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Config.ps1')

$cfg = Get-ETConfig -Path $ConfigPath
$catalog = Get-ETHandlerCatalog

# ------------------------------------------------------------ registry ----

$HookPaths = @(
    'HKCR:\*\shellex\ContextMenuHandlers'
    'HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers'
    'HKCR:\Directory\shellex\ContextMenuHandlers'
    'HKCR:\Directory\Background\shellex\ContextMenuHandlers'
    'HKCR:\Directory\shellex\DragDropHandlers'
    'HKCR:\Directory\shellex\CopyHookHandlers'
    'HKCR:\Directory\shellex\PropertySheetHandlers'
    'HKCR:\Folder\shellex\ContextMenuHandlers'
    'HKCR:\Folder\shellex\DragDropHandlers'
    'HKCR:\Drive\shellex\ContextMenuHandlers'
    'HKCR:\*\shellex\PropertySheetHandlers'
)
$OverlayPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
)
$BlockedPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
)

New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script -ErrorAction SilentlyContinue | Out-Null

if ($List) {
    Say "handler catalog ($($catalog.Count) entries), matched against this machine..." plan
    $present = Get-ETClsidByDll -DllNames @($catalog | ForEach-Object { $_.Dll } | Where-Object { $_ })
    Write-Host ""
    Write-Host ("  {0,-16} {1,-10} {2,-34} {3}" -f 'id', 'present', 'label', 'runs on') -ForegroundColor White
    foreach ($h in ($catalog | Sort-Object Id)) {
        $found = @($h.Dll | Where-Object { $present.ContainsKey($_.ToLower()) })
        Write-Host ("  {0,-16} {1,-10} {2,-34} {3}" -f $h.Id, $(if ($found) { 'yes' } else { '-' }), $h.Label, $h.Cost) `
            -ForegroundColor $(if ($found) { 'Yellow' } else { 'DarkGray' })
    }
    Write-Host ""
    Write-Host "  Block one with:  .\Optimize-Explorer.ps1 -Apply -Block <id>" -ForegroundColor Gray
    Write-Host "  or set Handlers.Block in explorertune.config.psd1" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# ----------------------------------------------------------- discovery ----

Say "scanning shell extension registrations..." plan

$hooks = @()
foreach ($p in ($HookPaths + $OverlayPaths)) {
    Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue | ForEach-Object {
        $cl = (Get-ItemProperty -LiteralPath $_.PSPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        if (-not $cl -or $cl -notmatch '^\{') { $cl = $_.PSChildName }
        if ($cl -notmatch '^\{') { $cl = $null }
        $srv = if ($cl) { Get-ETClsidServer $cl } else { $null }
        $hooks += [pscustomobject]@{
            KeyPath = $_.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
            PSPath  = $_.PSPath
            KeyName = $_.PSChildName
            # Vendors pad overlay key names to win the 15-slot alphabetical
            # race: some use leading spaces, at least one uses U+0001. Trim()
            # does not touch control characters, so strip both classes.
            Name    = ($_.PSChildName -replace '^[\s\p{C}]+', '')
            Clsid   = $cl
            Dll     = $(if ($srv) { Split-Path $srv -Leaf } else { $null })
            Dead    = [bool]($cl -and -not $srv)
            Overlay = ($p -like '*ShellIconOverlayIdentifiers*')
        }
    }
}

$dead = @($hooks | Where-Object Dead)

# Which catalog ids are we acting on?
$wanted = @()
$wanted += @($cfg.Handlers.Block)
$wanted += @($Block)
$wanted = @($wanted | Where-Object { $_ } | Sort-Object -Unique)
if ($Only) { $wanted = @($wanted | Where-Object { $Only -contains $_ }) }
if ($Skip) { $wanted = @($wanted | Where-Object { $Skip -notcontains $_ }) }
$wanted = @($wanted | Where-Object { $cfg.Handlers.Keep -notcontains $_ })

$unknown = @($wanted | Where-Object { $id = $_; -not ($catalog | Where-Object { $_.Id -eq $id }) })
foreach ($u in $unknown) { Say "  '$u' is not a catalog id - run -List" warn }
$wanted = @($wanted | Where-Object { $unknown -notcontains $_ })

$planBlock = @()
if ($wanted) {
    $wantDlls = @($catalog | Where-Object { $wanted -contains $_.Id } | ForEach-Object { $_.Dll } | Where-Object { $_ })
    if ($wantDlls) {
        Say "  resolving $($wantDlls.Count) DLL name(s) to CLSIDs..."
        $map = Get-ETClsidByDll -DllNames $wantDlls
        foreach ($h in ($catalog | Where-Object { $wanted -contains $_.Id })) {
            $ids = @()
            foreach ($d in $h.Dll) { if ($map.ContainsKey($d.ToLower())) { $ids += $map[$d.ToLower()] } }
            foreach ($c in ($ids | Sort-Object -Unique)) {
                $planBlock += [pscustomobject]@{ Id = $h.Id; Label = $h.Label; Clsid = $c }
            }
        }
    }
}

# ---------------------------------------------------------------- plan ----

$before = Get-ExplorerVitals
$beforeEnum = Measure-ShellEnum $cfg.Benchmark.Paths

Write-Host ""
Write-Host "  BEFORE  explorer.exe pid $($before.Id): $($before.PrivMB) MB private, $($before.Handles) handles, $($before.Threads) threads, $($before.Modules) modules, up $($before.UptimeH) h" -ForegroundColor White
foreach ($b in $beforeEnum) {
    Write-Host ("          {0,-28} {1,5} items  shell {2,5} ms  fs {3,3} ms  ratio {4}x" -f (Split-Path $b.Path -Leaf), $b.Items, $b.ShellMs, $b.FsMs, $b.Ratio)
}
Write-Host ("          third-party DLLs in the process: {0}" -f (Get-ETLoadedThirdPartyModules).Count)
Write-Host ""

Write-Host "  PLAN" -ForegroundColor Cyan
Write-Host "    config: $($cfg.Source)"
if (-not $NoDeadRemoval -and $cfg.Handlers.RemoveDeadRegistrations) {
    if ($dead.Count) {
        Write-Host "    delete $($dead.Count) DEAD registration(s) - CLSID resolves to no COM server:"
        foreach ($g in ($dead | Group-Object Name | Sort-Object Name)) {
            Write-Host ("      {0,-32} x{1}" -f $g.Name, $g.Count)
        }
    }
    else { Write-Host "    no dead registrations found" }
}
else { Write-Host "    dead-registration removal disabled" }

if ($planBlock.Count) {
    Write-Host "    block $($planBlock.Count) CLSID(s):"
    foreach ($g in ($planBlock | Group-Object Id)) {
        $h = $catalog | Where-Object { $_.Id -eq $g.Name } | Select-Object -First 1
        Write-Host ("      {0,-16} {1,2} clsid(s)  {2}" -f $g.Name, $g.Count, $h.Label)
        if ($h.Note) { Write-Host "                       ^ $($h.Note)" -ForegroundColor DarkGray }
    }
}
elseif ($wanted) { Write-Host "    nothing to block: none of the requested handlers are installed" }
else { Write-Host "    nothing to block (Handlers.Block is empty)" }

if ($cfg.Explorer.SeparateProcess) { Write-Host "    set SeparateProcess=1 (folder windows in their own process)" }
if ($cfg.Explorer.DisableGraphRecentItems) { Write-Host "    set DisableGraphRecentItems=1 (no Office/Graph fetch on Home)" }
if ($ResetShellbags) { Write-Host "    DELETE shellbags - loses every per-folder view preference" -ForegroundColor Yellow }
Write-Host ""

$willWrite = ($planBlock.Count -gt 0) -or
             ($dead.Count -gt 0 -and -not $NoDeadRemoval -and $cfg.Handlers.RemoveDeadRegistrations) -or
             $cfg.Explorer.SeparateProcess -or $cfg.Explorer.DisableGraphRecentItems -or $ResetShellbags

if (-not $Apply) {
    if ($willWrite) { Say "dry run. nothing was written. re-run with -Apply." warn }
    else { Say "nothing to do." ok }
    exit 0
}
if (-not $willWrite) { Say "nothing to do." ok; exit 0 }

Assert-Elevated

# --------------------------------------------------------------- apply ----

$bk = New-BackupDir 'shell'
Say "backup -> $bk" ok
foreach ($k in @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions'
        'HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions'
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        'HKEY_CLASSES_ROOT\Directory\shellex'
        'HKEY_CLASSES_ROOT\Drive\shellex'
        'HKEY_CLASSES_ROOT\Folder\shellex'
        'HKEY_CLASSES_ROOT\AllFilesystemObjects\shellex'
    )) {
    Backup-RegKey $k $bk (($k -replace '[\\:*?"<>|]', '_')) | Out-Null
}

# 1. dead registrations
$nDel = 0
if (-not $NoDeadRemoval -and $cfg.Handlers.RemoveDeadRegistrations) {
    foreach ($h in $dead) {
        try { Remove-Item -LiteralPath $h.PSPath -Recurse -Force -ErrorAction Stop; $nDel++ }
        catch {
            $null = & reg.exe delete $h.KeyPath /f 2>&1
            if ($LASTEXITCODE -eq 0) { $nDel++ } else { Say "  could not delete $($h.KeyPath)" warn }
        }
    }
    Say "  deleted $nDel dead registration(s)" $(if ($nDel -eq $dead.Count) { 'ok' } else { 'warn' })
}

# 2. blocks
$nBlk = 0
foreach ($p in $BlockedPaths) { if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null } }
foreach ($b in ($planBlock | Sort-Object Clsid -Unique)) {
    $wrote = $false
    foreach ($p in $BlockedPaths) {
        try {
            New-ItemProperty -LiteralPath $p -Name $b.Clsid -Value "ExplorerTune: $($b.Label)" `
                -PropertyType String -Force -ErrorAction Stop | Out-Null
            $wrote = $true
        }
        catch { Write-Verbose "could not write $($b.Clsid) to $p : $($_.Exception.Message)" }
    }
    if ($wrote) { $nBlk++ } else { Say "  could not block $($b.Clsid)" warn }
}
if ($planBlock.Count) { Say "  blocked $nBlk CLSID(s)" $(if ($nBlk -eq @($planBlock | Sort-Object Clsid -Unique).Count) { 'ok' } else { 'warn' }) }

# 3. settings
if ($cfg.Explorer.SeparateProcess) {
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
        -Name 'SeparateProcess' -Value 1 -Type DWord -Force
    Say "  SeparateProcess=1" ok
}
if ($cfg.Explorer.DisableGraphRecentItems) {
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
    if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
    Set-ItemProperty -LiteralPath $pol -Name 'DisableGraphRecentItems' -Value 1 -Type DWord -Force
    Say "  DisableGraphRecentItems=1" ok
}
if ($ResetShellbags) {
    $sb = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell'
    Backup-RegKey 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell' $bk 'shellbags' | Out-Null
    foreach ($n in 'BagMRU', 'Bags') { Remove-Item -LiteralPath (Join-Path $sb $n) -Recurse -Force -ErrorAction SilentlyContinue }
    Say "  shellbags reset" ok
}

# ------------------------------------------------------------- measure ----

if (-not $NoRestart) {
    Say "restarting explorer.exe..." plan
    & (Join-Path $PSScriptRoot 'Restart-Explorer.ps1') -Quiet
    Start-Sleep -Seconds 12
}

$after = Get-ExplorerVitals
$afterEnum = Measure-ShellEnum $cfg.Benchmark.Paths
$afterMods = Get-ETLoadedThirdPartyModules

Write-Host ""
Write-Host "  AFTER   explorer.exe pid $($after.Id): $($after.PrivMB) MB private, $($after.Handles) handles, $($after.Threads) threads, $($after.Modules) modules" -ForegroundColor White
foreach ($a in $afterEnum) {
    $p = $a.Path
    $b = $beforeEnum | Where-Object { $_.Path -eq $p }
    if ($b) {
        Write-Host ("          {0,-28} shell {1,5} ms -> {2,5} ms   ratio {3}x -> {4}x" -f (Split-Path $p -Leaf), $b.ShellMs, $a.ShellMs, $b.Ratio, $a.Ratio)
    }
}
Write-Host ""
Write-Host "  modules in explorer.exe          : $($before.Modules) -> $($after.Modules)" -ForegroundColor Green
Write-Host "  third-party DLLs in the process  : $((Get-ETLoadedThirdPartyModules).Count)" -ForegroundColor Green
foreach ($m in $afterMods) { Write-Host ("     {0,-32} [{1}]" -f $m.ModuleName, $m.FileVersionInfo.CompanyName) -ForegroundColor DarkGray }
Write-Host ""
Write-Host "  Some of any memory and handle drop is the restart clearing accumulated" -ForegroundColor Gray
Write-Host "  drift, not the blocking. The module count and the DLL list above are the" -ForegroundColor Gray
Write-Host "  part attributable to this change." -ForegroundColor Gray
Write-Host ""
Write-Host "  undo:  .\Restore-Explorer.ps1 -From `"$bk`"" -ForegroundColor Yellow
Write-Host ""
Save-Log $bk
