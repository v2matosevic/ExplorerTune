$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
# NOTE: do not name this H - "h" is a built-in alias for Get-History and
# aliases beat functions in command resolution, so H "x" silently does nothing.
function Show-Head($t) { Write-Output ""; Write-Output ("=== " + $t + " ===") }

. (Join-Path $PSScriptRoot 'lib\Config.ps1')
$cfg = Get-ETConfig

Show-Head "SYSTEM"
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"OS      : $($os.Caption) build $($cv.CurrentBuild).$($cv.UBR)"
"RAM     : $([math]::Round($os.TotalVisibleMemorySize/1MB,1)) GB total, $([math]::Round($os.FreePhysicalMemory/1MB,1)) GB free"
"Uptime  : $([math]::Round(((Get-Date)-$os.LastBootUpTime).TotalHours,1)) h"
$sysdrv = Get-PSDrive C
"C: free : $([math]::Round($sysdrv.Free/1GB,1)) GB of $([math]::Round(($sysdrv.Free+$sysdrv.Used)/1GB,1)) GB"

Show-Head "SHELL PROCESSES"
foreach ($n in 'explorer', 'SearchIndexer', 'SearchHost', 'StartMenuExperienceHost', 'OneDrive', 'TextInputHost', 'ShellExperienceHost', 'RuntimeBroker') {
    Get-Process -Name $n | ForEach-Object {
        $up = if ($_.StartTime) { "{0:N1}h" -f ((Get-Date) - $_.StartTime).TotalHours } else { '?' }
        "{0,-24} pid {1,-7} WS {2,7} MB  priv {3,7} MB  hnd {4,6}  thr {5,4}  up {6}" -f $n, $_.Id, [math]::Round($_.WorkingSet64 / 1MB, 1), [math]::Round($_.PrivateMemorySize64 / 1MB, 1), $_.Handles, $_.Threads.Count, $up
    }
}
$dh = Get-Process dllhost
"dllhost instances       : $($dh.Count)  total WS $([math]::Round((($dh | Measure-Object WorkingSet64 -Sum).Sum)/1MB,1)) MB"

New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script | Out-Null

function Get-HandlerInfo($clsid) {
    foreach ($root in 'HKCR:\CLSID', 'HKCR:\Wow6432Node\CLSID') {
        $k = Join-Path $root $clsid
        $srv = (Get-ItemProperty -LiteralPath (Join-Path $k 'InprocServer32') -Name '(default)').'(default)'
        if (-not $srv) { $srv = (Get-ItemProperty -LiteralPath (Join-Path $k 'LocalServer32') -Name '(default)').'(default)' }
        if ($srv) {
            $name = (Get-ItemProperty -LiteralPath $k -Name '(default)').'(default)'
            $path = [Environment]::ExpandEnvironmentVariables(($srv -replace '"', ''))
            $co = ''
            if (Test-Path -LiteralPath $path) { $co = (Get-Item -LiteralPath $path).VersionInfo.CompanyName }
            return [pscustomobject]@{ Name = $name; Dll = $path; Company = $co }
        }
    }
    return $null
}

# A blocked CLSID stays REGISTERED - blocking stops Explorer loading the DLL, it
# does not remove the hook. Counting registrations without this makes a tuned
# machine look untouched.
$Blocked = @{}
foreach ($bp in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked',
                'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked') {
    if (-not (Test-Path -LiteralPath $bp)) { continue }
    (Get-ItemProperty -LiteralPath $bp).PSObject.Properties |
        Where-Object { $_.Name -match '^\{' } | ForEach-Object { $Blocked[$_.Name.ToUpper()] = $_.Value }
}

$scan = @(
    'HKCR:\*\shellex\ContextMenuHandlers',
    'HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers',
    'HKCR:\Directory\shellex\ContextMenuHandlers',
    'HKCR:\Directory\Background\shellex\ContextMenuHandlers',
    'HKCR:\Directory\shellex\DragDropHandlers',
    'HKCR:\Directory\shellex\CopyHookHandlers',
    'HKCR:\Folder\shellex\ContextMenuHandlers',
    'HKCR:\Folder\shellex\DragDropHandlers',
    'HKCR:\Drive\shellex\ContextMenuHandlers',
    'HKCR:\*\shellex\PropertySheetHandlers',
    'HKCR:\Directory\shellex\PropertySheetHandlers',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
)

Show-Head "SHELL EXTENSIONS (in-process handlers Explorer loads)"
$rows = @()
foreach ($p in $scan) {
    Get-ChildItem -LiteralPath $p | ForEach-Object {
        $key = $_
        $cl = (Get-ItemProperty -LiteralPath $key.PSPath -Name '(default)').'(default)'
        if (-not $cl -or $cl -notmatch '^\{') { $cl = $key.PSChildName }
        if ($cl -notmatch '^\{') { $cl = $null }
        $info = if ($cl) { Get-HandlerInfo $cl } else { $null }
        $isBlocked = [bool]($cl -and $Blocked.ContainsKey($cl.ToUpper()))
        $rows += [pscustomobject]@{
            Hook    = ($p -replace '^HK(CR|LM):\\', '' -replace '\\shellex\\', '\')
            Entry   = $key.PSChildName
            Company = $(if ($info -and $info.Company) { $info.Company } else { '?' })
            Dll     = $(if ($info) { Split-Path $info.Dll -Leaf } else { '(unresolved)' })
            Blocked = $isBlocked
        }
    }
}
$ms = @($rows | Where-Object { $_.Company -match 'Microsoft' })
$td = @($rows | Where-Object { $_.Company -notmatch 'Microsoft' })
$tdLive = @($td | Where-Object { -not $_.Blocked })
$tdBlk = @($td | Where-Object { $_.Blocked })
"Total handlers registered : $($rows.Count)"
"  Microsoft-signed        : $($ms.Count)"
"  Third-party / unknown   : $($td.Count)"
"     of which BLOCKED     : $($tdBlk.Count)   (registered but Explorer refuses to load them)"
"     of which LIVE        : $($tdLive.Count)   <-- these actually load inside explorer.exe"
""
"--- third-party, LIVE ---"
$tdLive | Sort-Object Company, Entry | Format-Table Hook, Entry, Company, Dll -AutoSize | Out-String -Width 200
"--- third-party, blocked by ExplorerTune ---"
$tdBlk | Sort-Object Company, Entry | Format-Table Entry, Company, Dll -AutoSize | Out-String -Width 200

Show-Head "ICON OVERLAY HANDLERS (hard cap 15, alphabetical wins)"
$i = 0
Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers' | Sort-Object PSChildName | ForEach-Object {
    $i++
    $cl = (Get-ItemProperty -LiteralPath $_.PSPath -Name '(default)').'(default)'
    $info = Get-HandlerInfo $cl
    $bl = $(if ($cl -and $Blocked.ContainsKey($cl.ToUpper())) { '  [BLOCKED]' } else { '' })
    "{0,2}. {1,-44} {2}{3}" -f $i, $_.PSChildName, $(if ($info) { "$($info.Company) / $(Split-Path $info.Dll -Leaf)" } else { '?' }), $bl
}
"   ($i registered; only the first 15 are honoured)"

Show-Head "THIRD-PARTY DLLs ACTUALLY LOADED IN EXPLORER.EXE"
$ex = Get-Process explorer | Sort-Object StartTime | Select-Object -First 1
$np = @($ex.Modules | Where-Object { $_.FileName -notlike '*\WINDOWS\*' })
"  count: $($np.Count)   (this is the number that matters, not the registration count)"
$np | ForEach-Object { "   {0,-34} [{1}]" -f $_.ModuleName, $_.FileVersionInfo.CompanyName }

Show-Head "WINDOWS SEARCH"
$svc = Get-Service WSearch
"Service      : $($svc.Status) / startup $((Get-CimInstance Win32_Service -Filter "Name='WSearch'").StartMode)"
$edb = 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb'
$edbDir = Split-Path $edb -Parent
if (Test-Path $edb) {
    "Windows.edb  : $([math]::Round((Get-Item $edb).Length/1MB,1)) MB  (modified $((Get-Item $edb).LastWriteTime))"
}
elseif (-not (Test-Path $edbDir)) {
    # The store directory is ACL'd to SYSTEM, so an unelevated Test-Path returns
    # false whether or not the file exists. Do not report that as "missing".
    "Windows.edb  : not readable from an unelevated shell (store dir is SYSTEM-only) - not evidence of absence"
}
else { "Windows.edb  : NOT FOUND (store dir readable, file absent)" }
""
# Counts only. Dumping every rule buried the rest of this report in 800 lines,
# and the registry does not reflect the live scope anyway - it showed
# "B: include=1" while the API reported B: entirely out of scope. For the real
# answer run:  .\Set-SearchScope.ps1 -Test '<a path you care about>'
$csmBase = 'HKLM:\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex'
"--- crawl rule counts (registry; NOT the live scope) ---"
foreach ($h in 'DefaultRules', 'WorkingSetRules', 'UserScopeRules') {
    "  {0,-18} {1}" -f $h, @(Get-ChildItem -LiteralPath "$csmBase\$h").Count
}
"  whole-drive include rules, by drive:"
$wd = @{}
Get-ChildItem -LiteralPath "$csmBase\DefaultRules" | ForEach-Object {
    $u = (Get-ItemProperty -LiteralPath $_.PSPath).URL
    if ($u -match '^file:///([A-Z]):\\\[[0-9a-fA-F-]+\]\\$') { $wd[$matches[1]] = 1 + ($wd[$matches[1]]) }
}
$liveDrives = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter })
if ($wd.Count) {
    $wd.Keys | Sort-Object | ForEach-Object {
        "    {0}:  {1,2} rule(s)   {2}" -f $_, $wd[$_], $(if ($liveDrives -contains $_) { 'live' } else { 'DRIVE NOT PRESENT' })
    }
}
else { "    none" }
""
"--- cloud/web search flags ---"
$ss = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
foreach ($n in 'IsAADCloudSearchEnabled', 'IsMSACloudSearchEnabled', 'IsDeviceSearchHistoryEnabled', 'IsDynamicSearchBoxEnabled') { "  {0,-32} {1}" -f $n, $ss.$n }
$sr = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
foreach ($n in 'BingSearchEnabled', 'CortanaConsent') { "  {0,-32} {1}" -f $n, $sr.$n }

Show-Head "EXPLORER BEHAVIOUR SETTINGS (current)"
$adv = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
foreach ($n in 'LaunchTo', 'ShowRecent', 'ShowFrequent', 'Start_TrackDocs', 'SeparateProcess', 'ShowCloudFilesInQuickAccess', 'ShowSyncProviderNotifications', 'IconsOnly', 'ListviewAlphaSelect', 'ListviewShadow', 'TaskbarAnimations') {
    "  {0,-32} {1}" -f $n, $(if ($null -ne $adv.$n) { $adv.$n } else { '(unset)' })
}

Show-Head "SHELLBAGS (folder-view state; bloat slows folder open)"
$bagmru = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'
$bags = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
"BagMRU keys : $(@(Get-ChildItem -LiteralPath $bagmru -Recurse).Count)"
"Bags keys   : $(@(Get-ChildItem -LiteralPath $bags).Count)"
"AllFolders FolderType : $((Get-ItemProperty 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' -Name 'FolderType').FolderType)"

Show-Head "THUMBNAIL / ICON CACHE"
$cd = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
Get-ChildItem $cd -Filter '*.db' | Sort-Object Length -Descending | Select-Object -First 10 | ForEach-Object {
    "  {0,-34} {1,8} MB" -f $_.Name, [math]::Round($_.Length / 1MB, 2)
}
"  TOTAL: $([math]::Round(((Get-ChildItem $cd -Filter '*.db' | Measure-Object Length -Sum).Sum)/1MB,1)) MB"

Show-Head "NETWORK / MAPPED DRIVES"
$nc = @(Get-CimInstance Win32_NetworkConnection)
if ($nc.Count -eq 0) { "  none" } else { $nc | ForEach-Object { "  {0} -> {1}  status={2}" -f $_.LocalName, $_.RemoteName, $_.ConnectionState } }

Show-Head "RECENT / JUMPLIST LOAD"
$rec = "$env:APPDATA\Microsoft\Windows\Recent"
"  Recent items      : $(@(Get-ChildItem $rec -File).Count)"
"  AutomaticDest     : $(@(Get-ChildItem "$rec\AutomaticDestinations" -File).Count) jumplists"

Show-Head "SHELL ENUMERATION TIMING (proxy for folder-open cost)"
$shell = New-Object -ComObject Shell.Application
foreach ($t in $cfg.Benchmark.Paths) {
    if (Test-Path $t) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $items = $shell.Namespace($t).Items()
        $c = $items.Count
        $null = $items | Select-Object -First 200 | ForEach-Object { $_.Name }
        $sw.Stop()
        "  [shell] {0,-38} {1,6} items {2,7} ms" -f $t, $c, $sw.ElapsedMilliseconds
    }
}
foreach ($t in ($cfg.Benchmark.Paths | Select-Object -First 2)) {
    if (Test-Path $t) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $n = @(Get-ChildItem -LiteralPath $t -Force).Count
        $sw.Stop()
        "  [rawfs] {0,-38} {1,6} items {2,7} ms" -f $t, $n, $sw.ElapsedMilliseconds
    }
}

Show-Head "AUTOSTART (competes with Explorer at logon)"
foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
    (Get-ItemProperty $rk).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { "  {0,-26} {1}" -f $_.Name, $_.Value }
}
""
"ShellServiceObjectDelayLoad:"
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ShellServiceObjectDelayLoad').PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { "  {0} = {1}" -f $_.Name, $_.Value }
