# Windows Search crawl scope

Everything in here was measured, not read off a blog. Where a number appears it
came from a real machine, and the Windows build is named so you can tell whether
it still applies to yours.

## The short version

1. You cannot set the crawl scope from the registry. Not even as an elevated
   Administrator.
2. The registry will happily show you rules that are not in effect.
3. The only durable route is `ISearchCrawlScopeManager`, which is what the
   Indexing Options dialog calls.
4. Those interfaces ship no type library, and the IIDs commonly published for
   them are not always the ones a given Windows build implements.

## 1. The registry is not writable

The rules live under:

```
HKLM\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\
    DefaultRules       the service's own baseline
    WorkingSetRules    a derived cache, normalised from the others on startup
    UserScopeRules     what the API writes
```

Their ACLs, on build 10.0.26100:

```
DefaultRules
  NT SERVICE\TrustedInstaller   FullControl
  NT AUTHORITY\SYSTEM           SetValue, CreateSubKey, CreateLink, ReadKey
  BUILTIN\Administrators        CreateLink, ReadKey          <-- no write
  BUILTIN\Users                 CreateLink, ReadKey
  NT SERVICE\WSearch            FullControl

UserScopeRules
  not readable or writable by Administrators at all
```

An elevated `New-Item` under `UserScopeRules` fails with *Access to the registry
key is denied*. Administrators can still **delete** some subkeys, which is a
trap: deletion appears to work, and then the WSearch service regenerates
`DefaultRules` from its built-in baseline on its next start. Whole-drive rules
deleted at 17:16 on the reference machine were back by 17:19.

### What deletion *does* accomplish

The service only restores what it considers a built-in default: one whole-drive
rule per fixed volume currently present. Anything else stays deleted. On the
reference machine that permanently removed:

- 34 whole-drive rules for volumes no longer attached (25 of them for one
  removable drive letter that had seen 25 different sticks)
- stale Office content paths
- all 794 entries in `WorkingSetRules`, which is a derived cache and safe to
  wipe. Nearly all of them were individual dependency subdirectories from
  projects deleted long ago, and every crawl decision walked that list.

`DefaultRules` went from 64 entries to 23. That is what
`Clear-SearchRuleJunk.ps1` is for, and it is all it claims to do.

## 2. The registry lies about what is in scope

This is the one that costs people days.

On the reference machine, `DefaultRules` contained:

```
include=1  file:///B:\[986ad7c0-…]\
include=1  file:///D:\[784df635-…]\
```

Two whole drives, marked included, sitting right there in the registry. Asked
through the API:

```
IncludedInCrawlScope("file:///B:\Coding\")     -> False
IncludedInCrawlScope("file:///D:\Documents\")  -> False
```

Both drives were **entirely out of scope**. The rules were inert. The reported
symptom, "Explorer search never finds my projects", was not an index full of
`node_modules` drowning out the signal. The indexer had never looked at that
drive at all.

So: never diagnose crawl scope by reading the registry.

```powershell
.\Set-SearchScope.ps1 -Test 'C:\Projects','C:\Projects\app\node_modules'
```

### The volume GUID is not the volume GUID

A related trap. Crawl rules identify a volume like this:

```
file:///B:\[986ad7c0-…]\
```

That bracketed GUID is **not** the NTFS volume GUID. For the same drive at the
same moment:

```
mountvol B: /L   ->  \\?\Volume{0ecee025-…}\
crawl rules      ->  B:\[986ad7c0-…]
```

Completely different identifiers. A rule written with the `mountvol` GUID names
a volume the indexer does not recognise, and it is **silently ignored**: no
error, no warning, it simply never matches anything. If you must construct one
of these strings, learn the identifier from the indexer's own existing rules,
never from `mountvol`.

ExplorerTune sidesteps this entirely by going through the API with plain paths.

## 3. No recursive name exclusion

A `*` in a crawl rule matches **exactly one path segment**. The shipped defaults
prove it themselves:

```
include=0  file:///*\$RECYCLE.BIN\
include=0  file:///C:\[...]\Users\*\AppData\
```

There is no `**\node_modules`. So excluding a directory *name* means one rule per
nesting depth:

```
file:///C:\Projects\*\node_modules\
file:///C:\Projects\*\*\node_modules\
file:///C:\Projects\*\*\*\node_modules\
...
```

Hence `NoiseDepths` in the config. Thirteen names at five depths is 130 rules for
one include path. That looks absurd and it is the only way to express it. Do not
"simplify" the generated rules into one.

For calibration, the reference machine had `node_modules` at 27 places one level
below the project root, 61 at two levels, and 361 at three. Five depths covers a
normal monorepo.

## 4. The COM interfaces

`Set-SearchScope.ps1` uses:

```
CSearchManager            CLSID 7D096C5F-AC08-4F1F-BEB7-5C22C517CE39
ISearchManager            IID   AB310581-AC80-11D1-8DF3-00C04FB6EF69
  GetCatalog                slot 8
ISearchCatalogManager     IID   discovered at runtime
  get_Name                  slot 1
  GetCatalogStatus          slot 4
  NumberOfItems             slot 13
  GetCrawlScopeManager      slot 26
ISearchCrawlScopeManager  IID   discovered at runtime
  AddUserScopeRule          slot 6
  IncludedInCrawlScope      slot 11
  SaveAll                   slot 14
```

Slots are 1-based method positions after the three `IUnknown` entries.

### Why the IIDs are discovered rather than hardcoded

On build 10.0.26100 the object `GetCatalog` returns **does not implement** the
IIDs usually quoted for `ISearchCatalogManager` (`...EF61`, `...EF62`). A
`QueryInterface` sweep of the `AB310581-AC80-11D1-8DF3-00C04FB6EFxx` family found
exactly one supported interface, `...EF50`. Same story for the scope manager,
which answered to `...EF55`.

Whether that is a documentation error or a build difference, hardcoding it makes
a tool that works on one machine. So `lib/SearchApi.ps1` sweeps for the IIDs at
runtime. `QueryInterface` is read-only and cannot have side effects, so sweeping
is free of risk.

### Why it validates before it writes anything

There is no type library, so the vtable layout is declared by hand. A wrong
method index does not throw. It calls a *different function* with mismatched
arguments. And the neighbours are not harmless:

```
ISearchCatalogManager     slot 5   Reset()
ISearchCrawlScopeManager  slot 13  RevertToDefaultScopes()
```

An off-by-one in either direction is data loss on someone's live machine.

So nothing mutates until three read-only probes pass:

1. `GetIndexerVersionStr` returns a non-empty string.
2. `get_Name` returns **exactly** the catalog name that was passed to
   `GetCatalog`. This validates the candidate IID and the slot together.
3. A **two-sided oracle**: `IncludedInCrawlScope` must return `true` for a path
   that must be in scope and `false` for one that must not.

The third point is the important one. A one-sided check passes by accident: a
misidentified slot returning some nonzero garbage looks like `true`. It cannot be
right about both directions by luck. ExplorerTune uses the user's Desktop (in
scope by default on every Windows install) and `%WINDIR%` (excluded by default on
every Windows install), both from the shipped default rules.

If any probe disagrees, `Validated` stays false and every mutating method throws
instead of running. That is the intended behaviour, not a bug — if you see it,
please open an issue with the printed report and your build number.

### PowerShell cannot call these interfaces

Worth stating plainly because it costs an afternoon otherwise. PowerShell
dispatches COM through `IDispatch`. These interfaces do not implement it, so a
`[ComImport]` cast handed back to PowerShell arrives as a bare
`System.__ComObject` with no methods on it:

```
Method invocation failed because [System.__ComObject]
does not contain a method named 'GetIndexerVersionStr'.
```

Every call has to happen inside the C# added by `Add-Type`, exposed as static
helpers. That is why `lib/SearchApi.ps1` looks the way it does.

## Verifying a change

```powershell
.\Set-SearchScope.ps1 -Status                       # catalog state, item count
.\Set-SearchScope.ps1 -Test 'C:\Some\Path'          # is it in scope, really
```

A scope change does not reindex instantly. `-Status` reports the catalog state
(`Incremental crawl`, `Full crawl`, `Idle`) and the item count, which is the
honest way to watch progress. `SetupCompletedSuccessfully` is not: the service
sets that flag back to 1 itself, so reading it back tells you nothing.
