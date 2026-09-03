## What this changes

<!-- One or two sentences. -->

## Tested on

- Windows build: <!-- (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild -->
- PowerShell: <!-- $PSVersionTable.PSVersion -->

## Checklist

- [ ] Parse check and PSScriptAnalyzer pass locally
- [ ] Nothing writes without `-Apply`
- [ ] Any new write is preceded by `Backup-RegKey` and prints the restore command
- [ ] No usernames, drive layouts, volume GUIDs or SIDs in the diff
- [ ] Success counts come from what actually succeeded, not from input length

<!-- For a catalog entry, paste the -List line showing it resolves: -->
<!-- .\Optimize-Explorer.ps1 -List -->
