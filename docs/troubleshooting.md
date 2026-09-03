# Troubleshooting

## "running scripts is disabled on this system"

PowerShell's execution policy. Either allow signed-and-local scripts for your
user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

or run a single script without changing anything permanently:

```powershell
powershell -ExecutionPolicy Bypass -File .\Audit-Explorer.ps1
```

## "This writes to HKLM and needs an elevated shell"

`Optimize-Explorer.ps1 -Apply` and `Clear-SearchRuleJunk.ps1 -Apply` write to
HKLM. Open PowerShell as Administrator and run them again.

`Set-SearchScope.ps1` does **not** need admin. If something tells you it does,
that is a bug worth reporting.

## The search scope script says the layout could not be verified

```
The COM interface layout on this Windows build could not be verified,
so no mutating call will be made.
```

Working as designed. `lib/SearchApi.ps1` discovers the search COM interfaces at
runtime and proves the layout with read-only probes before it will call anything
that changes state. A wrong method index would call a *different* function, and
the neighbouring methods include `Reset()` and `RevertToDefaultScopes()`. When
the proof fails it refuses rather than guessing.

Read-only use still works:

```powershell
.\Set-SearchScope.ps1 -Status
.\Set-SearchScope.ps1 -Test 'C:\Some\Path'
```

Please open an issue with the printed report and your build number:

```powershell
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
```

Meanwhile, set the scope by hand: Control Panel → Indexing Options → Modify.

## Explorer did not come back after a restart

Press <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Esc</kbd> → File → Run new task →
`explorer.exe`.

If you ran `Restart-Explorer.ps1` from an **elevated** shell and it refused to
relaunch, that is deliberate. An elevated explorer.exe inherits the elevated
token: drag-and-drop from normal applications stops working, and every process
it launches runs as administrator. Run it from a normal shell.

## A context menu entry I wanted is gone

Undo the whole run:

```powershell
.\Restore-Explorer.ps1 -List
.\Restore-Explorer.ps1 -From .\backups\<timestamp>-shell
```

Or keep the rest and unblock one thing. Find its CLSID:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' |
    Select-Object -Property * |
    Format-List
```

Entries ExplorerTune added have data starting `ExplorerTune:`. Remove one from
both views and restart the shell:

```powershell
$clsid = '{...}'
foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked',
               'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked') {
    Remove-ItemProperty -LiteralPath $p -Name $clsid -ErrorAction SilentlyContinue
}
.\Restart-Explorer.ps1
```

Then add that id to `Handlers.Keep` in your config so a later run does not
re-block it.

## Search still does not find my files

Three things to check, in order.

**Is the folder actually in scope?** Ask the indexer, never the registry:

```powershell
.\Set-SearchScope.ps1 -Test 'C:\Projects'
```

**Has it finished indexing?** A scope change does not take effect instantly.

```powershell
.\Set-SearchScope.ps1 -Status
```

`Full crawl` or `Incremental crawl` means it is still working. Watch the item
count climb. A large include path can take hours.

**Are you searching for content or for a name?** Content search needs the file
type to have an installed IFilter and needs the crawl to have reached it.
Filename search through Explorer is slow by design — see the Everything section
in the [README](../README.md).

## The audit shows 50 third-party handlers after I blocked things

Correct, and not a failure. **Blocking does not remove the registration**; it
stops Explorer loading the DLL. The audit reports both:

```
Third-party / unknown   : 51
   of which BLOCKED     : 13
   of which LIVE        : 38
```

and separately the number that actually matters:

```
=== THIRD-PARTY DLLs ACTUALLY LOADED IN EXPLORER.EXE ===
  count: 3
```

## `Windows.edb : not readable from an unelevated shell`

The index store directory is ACL'd to SYSTEM, so an unelevated `Test-Path`
returns false whether or not the file exists. The audit says so rather than
claiming the file is missing. Nothing is wrong.

## The watchdog never fires

By design it holds off unless a threshold is crossed **and** no Explorer windows
are open **and** you are idle **and** the cooldown has passed. Check what it
decided:

```powershell
Get-Content .\logs\watchdog.csv
```

Every row records the decision and the reason. To see the threshold logic
without waiting:

```powershell
.\watchdog\Watch-Explorer.ps1 -WhatIf
.\watchdog\Watch-Explorer.ps1 -WhatIf -Force     # ignore the idle/window guards
```

If your explorer.exe simply never drifts past 5,000 handles, you do not need the
watchdog. That is a good outcome.

## Uninstalling all of it

```powershell
.\Restore-Explorer.ps1 -List           # then restore each backup, oldest last
.\watchdog\Install-Watchdog.ps1 -Uninstall
```

Search scope is not restored by a registry import, because it does not live in
the registry. Reset it through Indexing Options → Modify, or run
`Set-SearchScope.ps1 -Apply` with an edited config.

Then delete the folder. Nothing is installed outside it except the scheduled
task, the registry values named above, and Everything if you asked for it
(uninstall that from Apps & features).
