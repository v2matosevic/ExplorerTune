<#
    Configuration loading. Dot-source.

    Precedence: explorertune.config.psd1 in the repo root, then the built-in
    defaults below for anything it does not set. The config file is gitignored,
    so your paths never end up in a commit; explorertune.config.example.psd1 is
    the committed template.

    The defaults deliberately name no drive but C:. A tool that ships someone
    else's folder layout is a tool nobody else can run.
#>

function Get-ETDefaultConfig {
    @{
        Search = @{
            # Folders to put IN the search index. Defaults to the known folders
            # every Windows user has, which are already indexed on a stock
            # install, so the default config is a no-op rather than a surprise.
            Include = @(
                '%USERPROFILE%\Documents'
                '%USERPROFILE%\Desktop'
            )
            # Subtrees to keep OUT entirely. Backup drives, scratch volumes,
            # sample libraries, anything you never search by content.
            Exclude = @()
            # Directory NAMES excluded underneath every Include path. Windows
            # Search has no recursive name rule, so each name costs one rule per
            # nesting depth; see NoiseDepths.
            NoiseDirs = @(
                'node_modules', '.git', 'vendor', 'dist', 'build', '.next',
                '.turbo', '.svelte-kit', 'target', '__pycache__', '.venv',
                'coverage', '.cache'
            )
            # How many levels below each Include path to cover with NoiseDirs.
            # 5 handles node_modules nested four deep inside a monorepo.
            NoiseDepths = 5
        }

        # Folders timed by the audit as a proxy for folder-open cost. Shell
        # enumeration runs every property and thumbnail handler; the raw
        # filesystem does not. The ratio between them is the shell tax.
        Benchmark = @{
            Paths = @(
                '%USERPROFILE%\Downloads'
                '%USERPROFILE%\Desktop'
                '%USERPROFILE%\Documents'
            )
        }

        Handlers = @{
            # Catalog ids to block. Empty by default: blocking someone's tools
            # without being asked is not a default anyone should ship.
            # See handlers/catalog.psd1 for ids, or run:
            #   .\Optimize-Explorer.ps1 -List
            Block = @()
            # Ids to never touch even if listed above.
            Keep = @()
            # Delete registrations whose CLSID resolves to no COM server. These
            # are leftovers from uninstalled software; Explorer retries them on
            # every right-click and every icon paint. Safe and universal, so on
            # by default.
            RemoveDeadRegistrations = $true
        }

        Watchdog = @{
            MaxHandles    = 5000
            MaxPrivateMB  = 450
            IdleMinutes   = 5
            CooldownHours = 6
        }

        Explorer = @{
            # Folder windows in their own process. Costs some memory, buys
            # isolation: a hung extension can no longer take the desktop down.
            SeparateProcess = $true
            # Stop the Office/Graph "Recommended" fetch on the Home view.
            DisableGraphRecentItems = $true
        }
    }
}

function Expand-ETPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    [Environment]::ExpandEnvironmentVariables(($Path -replace '%([^%]+)%', '%$1%'))
}

function Merge-ETHashtable {
    param([hashtable]$Base, [hashtable]$Override)
    $out = @{}
    foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    if (-not $Override) { return $out }
    foreach ($k in $Override.Keys) {
        if ($out[$k] -is [hashtable] -and $Override[$k] -is [hashtable]) {
            $out[$k] = Merge-ETHashtable $out[$k] $Override[$k]
        }
        else { $out[$k] = $Override[$k] }
    }
    return $out
}

function Get-ETConfig {
    <#
    .SYNOPSIS
      Loads explorertune.config.psd1 over the built-in defaults.
    .PARAMETER Path
      Explicit config file. Defaults to explorertune.config.psd1 in the repo root.
    #>
    [CmdletBinding()]
    param([string]$Path)

    $root = Split-Path $PSScriptRoot -Parent
    if (-not $Path) { $Path = Join-Path $root 'explorertune.config.psd1' }

    $cfg = Get-ETDefaultConfig
    $script:ETConfigSource = 'built-in defaults'

    if (Test-Path -LiteralPath $Path) {
        try {
            $user = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
            $cfg = Merge-ETHashtable $cfg $user
            $script:ETConfigSource = $Path
        }
        catch {
            Write-Warning "could not read $Path : $($_.Exception.Message)"
            Write-Warning "falling back to built-in defaults"
        }
    }

    # Expand environment variables in every path-shaped value.
    $cfg.Search.Include   = @($cfg.Search.Include   | ForEach-Object { Expand-ETPath $_ })
    $cfg.Search.Exclude   = @($cfg.Search.Exclude   | ForEach-Object { Expand-ETPath $_ })
    $cfg.Benchmark.Paths  = @($cfg.Benchmark.Paths  | ForEach-Object { Expand-ETPath $_ })

    $cfg.Source = $script:ETConfigSource
    return $cfg
}

function Get-ETHandlerCatalog {
    <#
    .SYNOPSIS
      Loads handlers/catalog.psd1 - the community list of known shell extensions.
    #>
    [CmdletBinding()]
    param([string]$Path)
    $root = Split-Path $PSScriptRoot -Parent
    if (-not $Path) { $Path = Join-Path $root 'handlers\catalog.psd1' }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "handler catalog not found at $Path"
        return @()
    }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    return @($data.Handlers)
}
