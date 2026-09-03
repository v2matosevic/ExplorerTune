# Contributing

The most useful contribution is not code. It is a catalog entry.

## Adding a shell extension to the catalog

`handlers/catalog.psd1` is the list of things that load inside explorer.exe. It
only covers what the people here happen to have installed, which is a fraction
of what is out there. If your machine loads something the catalog does not know
about, adding it is a small self-contained PR and immediately useful to everyone
else.

### Find what you have

```powershell
.\Audit-Explorer.ps1
```

Two sections matter. `THIRD-PARTY DLLs ACTUALLY LOADED IN EXPLORER.EXE` is the
ground truth for your machine. `SHELL EXTENSIONS` lists what is registered and
where it is hooked.

### Write the entry

```powershell
@{
    Id = 'somevendor'; Label = 'SomeVendor Toolbar'; Dll = @('svshell64.dll', 'svshell.dll')
    Kind = 'contextmenu'
    Cost = 'right-click on files and folders'
    Note = 'Adds a "Send to SomeVendor" submenu. Blocking removes it; the desktop app is unaffected.'
    Verified = '10.0.26100'
}
```

Field by field:

- **`Id`** — stable, kebab-case. People put this in their config, so treat it as
  API: do not rename an existing one.
- **`Dll`** — file **names**, never paths. Vendors move install directories, and
  a name matches everywhere. Include both the 64-bit and 32-bit name when both
  exist. Version-suffixed names are handled automatically, so
  `DropboxExt64.dll` matches the real `DropboxExt64.96.0.dll`.
- **`Kind`** — `contextmenu`, `overlay`, `property`, `thumbnail`, `copyhook`, or
  `mixed`.
- **`Cost`** — **the most valuable field.** When does this run? Be concrete.
  "right-click on files" and "every time you look at a folder" are wildly
  different costs, and the second is the one people never suspect. If it is a
  copy hook, say that it runs on every copy, move, rename and delete.
- **`Note`** — what visibly stops working if someone blocks it. Somebody is
  going to read this line and then block the thing. Write it for them. If the
  honest answer is "do not block this, it is load-bearing", write that.
- **`Verified`** — the Windows build you confirmed it on, or `''`.

### Check it resolves

```powershell
.\Optimize-Explorer.ps1 -List
```

Your entry should show `present: yes` on a machine that has the software. If it
shows `-` while the DLL is clearly loaded, the `Dll` names are wrong.

### House rules for the catalog

- **Nothing is blocked by default.** Never add an id to a default block list.
  Blocking is the user's decision, made per id, in their own config.
- **No value judgements.** "Bloatware" tells the reader nothing. When it runs
  and what breaks tells them everything.
- **No uninstall advice** unless a handler cannot be usefully blocked (TeraCopy
  is the example: blocking removes the integration it exists for).

## Code

### Ground rules

These are not style preferences. Each one is in there because breaking it caused
a real problem.

- **Never write without `-Apply`.** Every mutating script is dry-run by default
  and prints a plan first. Do not add one that acts on bare invocation.
- **Back up before you write.** Call `Backup-RegKey` for every registry root you
  are about to touch, into a `New-BackupDir` folder, and print the restore
  command at the end. A change with no export is a bug.
- **Block shell extensions, do not delete them.** Deleting a vendor's key gets
  undone by their next update; a Blocked entry does not, and undo is one value.
  The only exception is a registration whose CLSID resolves to no COM server.
- **Static verbs, never new `shellex` handlers.** A `shell\<verb>\command` string
  costs nothing at runtime. A `shellex` handler is a DLL in explorer.exe. This
  project exists to remove those; do not add one.
- **Count real successes.** Never report "wrote N" from the length of the input
  list. An early version printed "wrote 82 rules" while all 82 were being denied
  by an ACL. Increment inside the `try`.
- **Verify against the system, not against your own write.** Confirm a blocked
  DLL by checking explorer.exe's module list. Confirm search scope with
  `IncludedInCrawlScope`. Re-reading the registry value you just set proves
  nothing.
- **Nothing machine-specific in a commit.** No usernames, no drive layouts, no
  volume GUIDs, no SIDs. Paths belong in `explorertune.config.psd1`, which is
  gitignored, or in the example config as `%USERPROFILE%`-style strings.

### Touching the COM interop

`lib/SearchApi.ps1` calls interfaces that ship no type library, through
hand-declared vtable offsets. `ISearchCatalogManager` has `Reset()` at slot 5
and the scope manager has `RevertToDefaultScopes()` at slot 13, so a wrong index
is not a crash, it is data loss on someone's machine.

If you change anything in there, the discovery-and-validation contract must
hold: read-only probes first, including a **two-sided oracle** (a case that must
be true *and* one that must be false), and `Validated` false means every
mutating call throws. A one-sided check passes by accident; a two-sided one
cannot.

Background: [docs/search-scope.md](docs/search-scope.md).

### Before opening a PR

```powershell
# parse check
Get-ChildItem -Recurse -Include *.ps1,*.psd1 | ForEach-Object {
    $e = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e.Count) { "FAIL $($_.Name)"; $e | ForEach-Object { $_.Message } }
}

# linter, same as CI
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

Then run the dry runs and paste the output into the PR:

```powershell
.\Audit-Explorer.ps1
.\Optimize-Explorer.ps1 -List
.\Optimize-Explorer.ps1
.\Set-SearchScope.ps1
```

Say which Windows build and PowerShell version you tested on. "Works on my
machine" is genuinely useful data here as long as you say which machine.

## Reporting a bug

Include the output of `.\Audit-Explorer.ps1` **with anything identifying
removed** — it contains your username, drive layout and installed software, so
read it before pasting. Your Windows build number and PowerShell version matter
more than most fields.

## Security

Do not open a public issue for a security problem. See
[SECURITY.md](SECURITY.md).
