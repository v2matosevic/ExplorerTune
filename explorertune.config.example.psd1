<#
    Copy this to  explorertune.config.psd1  and edit it. That file is
    gitignored, so your folder layout never ends up in a commit.

    Anything you leave out falls back to the built-in default in
    lib/Config.ps1. You do not need to keep sections you are not changing.

    Nothing in here is applied until you run a script with -Apply.
#>
@{

    Search = @{
        # Folders that SHOULD be searchable by content.
        #
        # Environment variables are expanded, so %USERPROFILE% works and keeps
        # the file portable between machines.
        Include = @(
            '%USERPROFILE%\Documents'
            '%USERPROFILE%\Desktop'
            # 'C:\Projects'
            # 'D:\Work'
        )

        # Whole subtrees that should never be indexed. Backup drives, scratch
        # volumes, sample libraries, game installs, VM disks.
        Exclude = @(
            # 'E:\'
            # 'D:\Backups'
            # 'C:\VMs'
        )

        # Directory NAMES excluded underneath every Include path above.
        #
        # Windows Search has no recursive name rule: a '*' in a crawl rule
        # matches exactly one path segment, so each name here costs one rule per
        # nesting depth. That is why NoiseDepths exists and why the rule count
        # looks large. It is a limit of the component, not a workaround.
        NoiseDirs = @(
            'node_modules', '.git', 'vendor', 'dist', 'build', '.next',
            '.turbo', '.svelte-kit', 'target', '__pycache__', '.venv',
            'coverage', '.cache'
            # '.gradle', 'Pods', 'bin', 'obj', 'packages'
        )

        # How many levels below each Include path to cover with NoiseDirs.
        # 5 handles node_modules nested four directories deep in a monorepo.
        # Each extra depth costs NoiseDirs.Count more rules.
        NoiseDepths = 5
    }

    # Folders the audit times as a proxy for folder-open cost. Pick a couple you
    # actually open often, including one large one.
    Benchmark = @{
        Paths = @(
            '%USERPROFILE%\Downloads'
            '%USERPROFILE%\Desktop'
            '%USERPROFILE%\Documents'
        )
    }

    Handlers = @{
        # Catalog ids to block. Run  .\Optimize-Explorer.ps1 -List  to see which
        # of them are actually installed here, and read the Note field in
        # handlers/catalog.psd1 before adding one: blocking a shell extension
        # removes a menu entry or a sync badge.
        #
        # Blocking is reversible with .\Restore-Explorer.ps1.
        Block = @(
            # 'filezilla'      # copy hook, runs on every folder copy/move/rename
            # 'poweriso'
            # 'recuva'
            # 'adobe-acrobat'
        )

        # Ids to protect from Block, e.g. when sharing a config with someone.
        Keep = @(
            # '7zip'
            # 'onedrive'
        )

        # Delete registrations whose CLSID resolves to no COM server. These are
        # leftovers from uninstalled software that Explorer still tries on every
        # right-click and every icon paint. Safe and universal, so on by default.
        RemoveDeadRegistrations = $true
    }

    Watchdog = @{
        # Restart the shell above EITHER of these. A freshly started explorer.exe
        # sits around 150-300 MB with 3-4k handles; a badly drifted one can pass
        # 600 MB and 8k. Check your own baseline in the audit before tightening.
        MaxHandles   = 5000
        MaxPrivateMB = 450

        # Guards, so a restart lands in a gap rather than under your hands.
        IdleMinutes   = 5
        CooldownHours = 6
    }

    Explorer = @{
        # Folder windows in their own process. Costs some memory, buys
        # isolation: a hung extension can no longer take the desktop down.
        SeparateProcess = $true

        # Stop the Office/Graph "Recommended" network fetch on the Home view.
        DisableGraphRecentItems = $true
    }
}
