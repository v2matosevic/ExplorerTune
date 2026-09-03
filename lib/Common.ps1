<#
    Shared helpers. Dot-source; do not run.
#>

$script:ETRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Elevated {
    if (-not (Test-Elevated)) {
        Write-Host ""
        Write-Host "  This writes to HKLM and needs an elevated shell." -ForegroundColor Red
        Write-Host "  Reopen PowerShell as Administrator and run it again." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
}

function New-BackupDir {
    param([string]$Tag)
    $d = Join-Path $script:ETRoot ("backups\{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Tag)
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Backup-RegKey {
    <#  reg.exe export, because a Clixml dump of a registry tree cannot be
        imported back. Returns the file path, or $null if the key was absent. #>
    param(
        [Parameter(Mandatory)][string]$Key,   # e.g. HKLM\SOFTWARE\...
        [Parameter(Mandatory)][string]$Dir,
        [string]$Name
    )
    if (-not $Name) { $Name = ($Key -replace '[\\:*?"<>|]', '_') }
    $file = Join-Path $Dir "$Name.reg"
    $null = & reg.exe export $Key $file /y 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return $file
}

$script:ETLog = @()
function Say {
    param([string]$Msg, [string]$Level = 'info')
    $c = switch ($Level) {
        'ok' { 'Green' } 'warn' { 'Yellow' } 'err' { 'Red' } 'plan' { 'Cyan' } default { 'Gray' }
    }
    Write-Host $Msg -ForegroundColor $c
    $script:ETLog += ("{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg)
}

function Save-Log {
    param([string]$Dir, [string]$Name = 'run.log')
    if ($Dir) { $script:ETLog | Set-Content -LiteralPath (Join-Path $Dir $Name) -Encoding UTF8 }
}

# ----------------------------------------------------------- explorer ----

function Get-ExplorerVitals {
    $e = Get-Process explorer -ErrorAction SilentlyContinue
    if (-not $e) { return $null }
    # With SeparateProcess on there can be several. The oldest owns the desktop.
    $shell = $e | Sort-Object StartTime | Select-Object -First 1
    [pscustomobject]@{
        Id        = $shell.Id
        PrivMB    = [math]::Round($shell.PrivateMemorySize64 / 1MB, 1)
        WorkingMB = [math]::Round($shell.WorkingSet64 / 1MB, 1)
        Handles   = $shell.Handles
        Threads   = $shell.Threads.Count
        Modules   = $(try { $shell.Modules.Count } catch { -1 })
        UptimeH   = $(if ($shell.StartTime) { [math]::Round(((Get-Date) - $shell.StartTime).TotalHours, 1) } else { -1 })
        Instances = $e.Count
    }
}

function Get-ETLoadedThirdPartyModules {
    <#  DLLs mapped into explorer.exe that did not come from %WINDIR%. This is
        the number that matters: a blocked handler stays REGISTERED, so counting
        registrations makes a tuned machine look untouched. #>
    $e = Get-Process explorer -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
    if (-not $e) { return @() }
    try { @($e.Modules | Where-Object { $_.FileName -notlike "$env:WINDIR\*" }) } catch { @() }
}

function Measure-ShellEnum {
    <#  Times enumeration through the shell namespace, which runs every property
        and thumbnail handler, against the raw filesystem, which runs none. The
        ratio is the shell tax.

        Treat it as an order of magnitude, not a precise figure: repeated runs
        on the same folder vary by 5x depending on cache state. The raw
        filesystem number is the stable half. #>
    param([string[]]$Paths)
    $shell = New-Object -ComObject Shell.Application
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $items = $shell.Namespace($p).Items()
        $c = $items.Count
        $null = $items | Select-Object -First 200 | ForEach-Object { $_.Name }
        $sw.Stop(); $shellMs = $sw.ElapsedMilliseconds
        $sw.Restart()
        $null = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue).Count
        $sw.Stop(); $fsMs = [math]::Max($sw.ElapsedMilliseconds, 1)
        [pscustomobject]@{
            Path = $p; Items = $c; ShellMs = $shellMs; FsMs = $fsMs
            Ratio = [math]::Round($shellMs / $fsMs, 1)
        }
    }
}

# ------------------------------------------------------------- CLSIDs ----

function Get-ETClsidServer {
    <#  Resolves a CLSID to the file backing it, or $null if nothing does -
        which is what makes a registration "dead". Checks both registry views:
        a 32-bit handler is invisible from the 64-bit view alone. #>
    param([Parameter(Mandatory)][string]$Clsid)
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null; $k = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::ClassesRoot, $view)
            foreach ($kind in 'InprocServer32', 'LocalServer32') {
                $k = $base.OpenSubKey("CLSID\$Clsid\$kind")
                if ($k) {
                    $v = $k.GetValue('')
                    $k.Close(); $k = $null
                    if ($v) { return [Environment]::ExpandEnvironmentVariables(($v -replace '"', '')) }
                }
            }
        }
        catch { Write-Verbose "CLSID $Clsid not readable in $view : $($_.Exception.Message)" }
        finally { if ($k) { $k.Close() }; if ($base) { $base.Close() } }
    }
    return $null
}

function Get-ETClsidByDll {
    <#  Maps DLL file names to the CLSIDs registered against them.

        Walks the CLSID hive through the .NET registry API rather than the
        PowerShell provider. The provider version of this took over ten minutes
        on a machine with ~20k CLSIDs; this takes seconds.

        Matching is by file NAME, never path, because vendors move their install
        directories. It also accepts a version-suffixed variant, so a catalog
        entry of DropboxExt64.dll matches the real DropboxExt64.96.0.dll.

        Returns @{ 'wanted.dll' = @('{clsid}', ...) }, keys lower-cased.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DllNames)

    $out = @{}
    if (-not $DllNames -or $DllNames.Count -eq 0) { return $out }

    # want-key -> prefix to also accept ("dropboxext64" -> "dropboxext64.")
    $want = @{}
    foreach ($d in ($DllNames | Sort-Object -Unique)) {
        if (-not $d) { continue }
        $lower = $d.ToLower()
        $want[$lower] = [IO.Path]::GetFileNameWithoutExtension($lower) + '.'
    }

    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null; $root = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::ClassesRoot, $view)
            $root = $base.OpenSubKey('CLSID')
            if (-not $root) { continue }
            foreach ($name in $root.GetSubKeyNames()) {
                if ($name -notlike '{*') { continue }
                $k = $null
                try {
                    $k = $root.OpenSubKey("$name\InprocServer32")
                    if (-not $k) { continue }
                    $v = $k.GetValue('')
                    if (-not $v) { continue }
                    $leaf = ([IO.Path]::GetFileName(($v -replace '"', ''))).ToLower()
                    if (-not $leaf) { continue }
                    foreach ($w in $want.Keys) {
                        if ($leaf -eq $w -or ($leaf.StartsWith($want[$w]) -and $leaf.EndsWith('.dll'))) {
                            if (-not $out.ContainsKey($w)) { $out[$w] = @() }
                            if ($out[$w] -notcontains $name) { $out[$w] += $name }
                        }
                    }
                }
                catch { Write-Verbose "skipping CLSID $name : $($_.Exception.Message)" }
                finally { if ($k) { $k.Close() } }
            }
        }
        catch { Write-Verbose "CLSID hive not enumerable in $view : $($_.Exception.Message)" }
        finally { if ($root) { $root.Close() }; if ($base) { $base.Close() } }
    }
    return $out
}
