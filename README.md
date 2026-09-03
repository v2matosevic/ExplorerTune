# ExplorerTune

Make the Windows File Explorer you already have fast, instead of replacing it.

No new shell, no background app, no telemetry. A handful of PowerShell scripts
that measure what is actually slowing Explorer down on *your* machine, then fix
the three things that usually are.

Every script is **dry-run by default**, prints exactly what it would change, and
takes a registry export before it touches anything.

```powershell
git clone https://github.com/v2matosevic/ExplorerTune
cd ExplorerTune
.\Audit-Explorer.ps1              # read-only. changes nothing.
```

---

## Why Explorer feels slow

On the machine this was built for, enumerating a folder through the shell took
**65 ms while the raw filesystem took 3 ms**. Same folder, same disk. The
filesystem was never the problem.

The gap is code other programs installed *inside* explorer.exe. Seventeen
third-party DLLs were loaded into the process, running on every right-click,
every property read and every thumbnail. Ten of the registrations pointed at
software that had been uninstalled and no longer existed at all; Explorer was
still trying to load them, failing, and moving on, on every icon paint.

Three problems, three fixes:

| | Problem | What ExplorerTune does |
|---|---|---|
| 1 | Third-party DLLs loaded into explorer.exe | Deletes dead registrations, blocks handlers you name |
| 2 | Explorer's search does not find your files | Sets the crawl scope through the COM API the Indexing Options dialog uses |
| 3 | explorer.exe bloats the longer it runs | Restarts it on a threshold, but only while you are idle |

---

## Quick start

Requires Windows 10 or 11 and PowerShell 5.1 or 7+.

```powershell
# 1. See what is going on. Read-only, needs no admin.
.\Audit-Explorer.ps1

# 2. See which known shell extensions are installed here and what each costs.
.\Optimize-Explorer.ps1 -List

# 3. Set up your own config.
copy explorertune.config.example.psd1 explorertune.config.psd1
notepad explorertune.config.psd1

# 4. Every script shows a plan first. Add -Apply when you agree with it.
.\Optimize-Explorer.ps1                  # plan
.\Optimize-Explorer.ps1 -Apply           # needs admin

.\Set-SearchScope.ps1                    # plan
.\Set-SearchScope.ps1 -Apply             # no admin needed

.\watchdog\Install-Watchdog.ps1          # optional
```

Undo anything:

```powershell
.\Restore-Explorer.ps1 -List
.\Restore-Explorer.ps1 -From .\backups\<timestamp>-shell
```

---

## What each script does

| Script | Admin | Purpose |
|---|---|---|
| `Audit-Explorer.ps1` | no | Measures everything, changes nothing. Run before and after. |
| `Optimize-Explorer.ps1` | to `-Apply` | Removes dead shell registrations, blocks handlers you list. |
| `Set-SearchScope.ps1` | no | Sets the search crawl scope. `-Test` asks what is really in scope. |
| `Clear-SearchRuleJunk.ps1` | to `-Apply` | Deletes stale crawl rules and rules for drives you no longer own. |
| `Setup-Everything.ps1` | to `-Apply` | Installs [Everything](https://www.voidtools.com) and wires it into the right-click menu. |
| `Restart-Explorer.ps1` | no | Restarts the shell safely. |
| `Restore-Explorer.ps1` | to restore | Undoes a previous run from its backup. |
| `watchdog\Install-Watchdog.ps1` | maybe | Scheduled task that restarts Explorer when it drifts. |

---

## 1. The shell-extension tax

Every entry in `handlers/catalog.psd1` is a shell extension that loads inside
explorer.exe. The catalog records what each one is, **when it runs**, and what
visibly breaks if you block it:

```
id               present    label                            runs on
7zip             yes        7-Zip                            right-click on files, folders and drives
filezilla        yes        FileZilla copy hook              EVERY folder copy, move, rename and delete
corel            yes        Corel property handlers          every time you LOOK at a folder
vscode           -          Visual Studio Code               nothing measurable
```

That "runs on" column is the useful one. A context-menu handler costs you
something when you right-click. A **property or thumbnail handler costs you
something when you merely look at a folder**, which is far worse and far less
obvious. A **copy hook** is consulted on every copy, move, rename and delete
whether or not the application is running.

`vscode` is in the catalog as a good example: it registers *static verbs*, which
are plain registry strings and cost nothing at runtime. There is nothing to
block. Every installer should work this way.

**Nothing is blocked by default.** You opt in per id:

```powershell
.\Optimize-Explorer.ps1 -Apply -Block filezilla,poweriso
```

Blocking adds the CLSID to `HKLM\...\Shell Extensions\Blocked`, and Explorer
refuses to load the DLL. The vendor's installation is untouched, so an app
update will not fight it, and undo is deleting one registry value.

Dead registrations are different: if a CLSID resolves to no COM server at all,
the software is gone and the hook is pure waste. Those are detected
automatically and deleted (after a backup), because there is nothing to weigh up.

### Icon overlays, and the queue-jumping arms race

Windows honours only the **first 15** icon-overlay handlers, by sort order. Look
at what vendors do about that:

```
key name                  leading code points
"   AccExtIco1"           U+0020 U+0020 U+0020    three spaces
"   DropboxExt01".."10"   U+0020 U+0020 U+0020    three spaces, ten slots
" MEGA (Synced)"          U+0001 U+0020           a control character
"EnhancedStorageShell"    (none)                  Microsoft
"Offline Files"           (none)                  Microsoft
```

They pad their key names to sort ahead of each other. One sync client uses
**U+0001**, a C0 control character, to beat everyone padding with spaces.
Between them they filled all fifteen slots, and Windows' own two handlers were
pushed out entirely.

On that machine, deleting the three dead entries from an uninstalled client was
enough to bring the total to exactly fifteen and let Microsoft's own overlays
back in, without touching anything anyone was using.

---

## 2. Search that actually finds your files

If Explorer's search box does not find things you know exist, the usual reason
is that the folder is not in the crawl scope, and the usual reason for *that* is
not what you would guess.

Two facts worth knowing before you go looking in the registry:

**The crawl scope cannot be set from the registry.** The keys under
`HKLM\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager` deny writes even to
an elevated Administrator, and the WSearch service regenerates them on every
start. Rules deleted there are back within a minute.

**The registry lies about what is in scope.** On the reference machine,
`DefaultRules` contained `include=1` for two whole drives while the API reported
both as **entirely out of scope**. Search was not overloaded with junk; it was
ignoring the project drive completely.

So always ask the indexer, never the registry:

```powershell
.\Set-SearchScope.ps1 -Test 'C:\Projects','C:\Projects\app\node_modules'

    file:///C:\Projects\                              True
    file:///C:\Projects\app\node_modules\             False
```

Set it from config, through `ISearchCrawlScopeManager`, the same API the
Indexing Options dialog calls:

```powershell
Search = @{
    Include     = @('C:\Projects', '%USERPROFILE%\Documents')
    Exclude     = @('E:\', 'D:\Backups')
    NoiseDirs   = @('node_modules', '.git', 'vendor', 'dist', 'build')
    NoiseDepths = 5
}
```

Windows Search has **no recursive name exclusion**. A `*` in a crawl rule
matches exactly one path segment, which the shipped defaults demonstrate
themselves with `file:///*\$RECYCLE.BIN\`. There is no `**\node_modules`, so
each name needs one rule per nesting depth. That is why the plan says
"130 rules" for thirteen directory names. It is a limit of the component.

Full detail, including how the interface layout is discovered and verified at
runtime: **[docs/search-scope.md](docs/search-scope.md)**.

### Filename search has a ceiling

Explorer's search box will never match a dedicated MFT indexer for finding files
by name. It queries the Windows Search index with a combined name-and-content
query and post-filters. [Everything](https://www.voidtools.com) reads the NTFS
Master File Table directly and answers in single-digit milliseconds on any size
of volume, with no content index to maintain.

So the split this project recommends is deliberate:

- **filename search** goes to Everything. `Setup-Everything.ps1` installs it and
  adds two right-click verbs, deliberately as static verbs so they cost nothing.
- **content search** goes to Windows Search, scoped properly.

---

## 3. Drift

The Windows 11 XAML shell accumulates handles and threads the longer it runs.
Measured on the reference machine after 138 hours of uptime:

| | after 138 h | after restart |
|---|---|---|
| private bytes | 633 MB | 171 MB |
| handles | 8,032 | 3,744 |
| threads | 304 | 136 |

No setting fixes that. Only a restart does, and it takes about a second.

The watchdog checks every 30 minutes and restarts the shell only when a
threshold is crossed **and** no Explorer windows are open **and** you have been
idle for five minutes **and** the last restart was over six hours ago. It logs
every check to `logs/watchdog.csv`, so you can see your own drift rate instead
of guessing at thresholds.

If you would rather do it by hand, `Restart-Explorer.ps1` is the whole feature.

---

## Safety

This edits the registry, so:

- **Dry-run by default.** No script writes anything without `-Apply`.
- **Backup first.** Every applying run exports the keys it will touch to
  `backups/<timestamp>-<tag>/` and prints the exact restore command.
- **Reversible by design.** Handlers are *blocked*, not deleted, so a vendor
  update cannot half-undo the change and undo is one registry value.
- **Verified against reality.** After a change, a blocked DLL is confirmed gone
  from explorer.exe's module list, and search scope is confirmed by asking the
  indexer. Not by re-reading the value we just wrote.
- **It refuses when it cannot verify.** The search API's interface layout is
  discovered and proven at runtime; if that check fails, every mutating call is
  disabled rather than attempted. See
  [docs/search-scope.md](docs/search-scope.md) for why that matters.

What it will not do: install a service, phone home, "clean" your registry, or
touch anything it did not tell you about first.

---

## Docs

- **[docs/how-it-works.md](docs/how-it-works.md)** — the mechanisms: the Blocked
  list, the overlay cap, static verbs vs shellex handlers, what the timings mean.
- **[docs/search-scope.md](docs/search-scope.md)** — Windows Search internals,
  the COM interface discovery, and why the registry is the wrong place to look.
- **[docs/case-study.md](docs/case-study.md)** — the full anonymised audit of the
  machine this was built for, with the numbers and the three things that turned
  out to be wrong.
- **[docs/troubleshooting.md](docs/troubleshooting.md)**

## Contributing

The handler catalog is the part that gets better with more people. If Explorer
loads something on your machine that is not in `handlers/catalog.psd1`, adding it
is a small, self-contained PR and genuinely useful to everyone else.

See **[CONTRIBUTING.md](CONTRIBUTING.md)**.

## Licence

MIT. See [LICENSE](LICENSE).
