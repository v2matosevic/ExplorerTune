@{
    ExcludeRules = @(
        # Write-Host is the right call here: this is an interactive console tool
        # and the plan/report output is for a person, not a pipeline. Where
        # output IS data (Audit-Explorer.ps1) it goes to the success stream.
        'PSAvoidUsingWriteHost',

        # Every write is gated behind an explicit -Apply switch and preceded by a
        # printed plan and a registry export. ShouldProcess on top of that would
        # add a second, differently-worded confirmation for the same decision.
        'PSUseShouldProcessForStateChangingFunctions',

        # Watch-Explorer.ps1 declares its own -WhatIf because it is a decision
        # report, not a ShouldProcess wrapper.
        'PSReservedParameter',

        # Get-ExplorerVitals and Get-ETLoadedThirdPartyModules return
        # collections of things. The singular rename reads worse and matches no
        # convention anyone follows (Get-ChildItem, Get-Process).
        'PSUseSingularNouns'
    )
}
