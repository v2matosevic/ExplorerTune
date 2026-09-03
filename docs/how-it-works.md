# How it works

The mechanisms behind each change, and how to read the numbers.

## Shell extensions

A shell extension is a COM object registered under a *hook* in `HKEY_CLASSES_ROOT`.
When Explorer needs that hook, it instantiates the object, which loads the DLL
**into explorer.exe** and runs vendor code in the shell's own process.

The hooks that matter:

| Hook | When it runs |
|---|---|
| `ContextMenuHandlers` | right-click on a file, folder, drive or folder background |
| `DragDropHandlers` | drag onto a folder |
| `CopyHookHandlers` | **every** folder copy, move, rename and delete |
| `PropertySheetHandlers` | opening Properties |
| Thumbnail / property handlers (per file extension) | **merely looking at a folder** |
| `ShellIconOverlayIdentifiers` | **every icon paint** |

The bottom three are the expensive ones, because they run without you doing
anything deliberate. A context-menu handler you can at least avoid by not
right-clicking. A thumbnail handler runs when you open the folder.

`Audit-Explorer.ps1` reports both a registration count and, separately, the DLLs
actually mapped into explorer.exe. The second number is the one that matters.

### Static verbs cost nothing

Not every context-menu entry is a shell extension. A *static verb* is plain
registry data:

```
HKCR\Directory\shell\MyTool\(default)          = "Open with MyTool"
HKCR\Directory\shell\MyTool\command\(default)  = "C:\...\mytool.exe" "%1"
```

Explorer reads a string and shells out. No DLL, no in-process code, nothing
loaded at startup. Visual Studio Code does this, which is why the catalog lists
it as costing nothing measurable and offers nothing to block.

This is also why `Setup-Everything.ps1` adds *static verbs* rather than
installing a handler DLL. Adding a `shellex` handler to a tool whose purpose is
removing `shellex` handlers would be self-defeating.

If you write installers: use static verbs.

### Blocking, not deleting

To stop Explorer loading a handler, add its CLSID to:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked
HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked
```

as a `REG_SZ` whose name is the CLSID. Explorer then refuses to instantiate it.

Both views matter: a 32-bit handler is invisible from the 64-bit view alone.

Why block rather than delete the vendor's `shellex` key:

- the vendor's next update recreates a deleted key, so the change silently
  reverts and you get to debug it twice
- undo is deleting one value, versus restoring a registry subtree
- nothing about the vendor's installation is modified, so uninstall still works

`Restore-Explorer.ps1` removes every value ExplorerTune added (they are tagged
`ExplorerTune: <label>` in their data) and then imports the backups. It has to
do the removal explicitly, because a registry *import* cannot delete a value the
backup simply did not contain.

### Dead registrations

If a CLSID resolves to no `InprocServer32` and no `LocalServer32`, no code backs
it. The software is uninstalled and the hook is a leftover. Explorer still calls
`CoCreateInstance` on it, takes the failure, and moves on, on every right-click
and every icon paint.

There is nothing to weigh up, so these are deleted rather than blocked, and it
is on by default. The reference machine had ten from a single uninstalled sync
client.

Detection is automatic, so this works for software the catalog has never heard
of.

### The 15-slot overlay cap

Windows honours only the **first 15** entries under
`ShellIconOverlayIdentifiers`, by sort order. Vendors compete for the front of
that queue by padding their key names:

```
"   AccExtIco1"           three leading spaces
"   DropboxExt01".."10"   three leading spaces, ten slots for one product
" MEGA (Synced)"          U+0001, a C0 control character
"EnhancedStorageShell"    unpadded  (Microsoft)
"Offline Files"           unpadded  (Microsoft)
```

Space sorts before letters, so padding wins; `U+0001` sorts before space, so it
wins harder. On the reference machine eighteen were registered, three sync
clients held sixteen of the honoured fifteen, and Windows' own two overlays were
evicted.

Two practical consequences:

- Count before you cut. Removing three dead entries brought that machine to
  exactly fifteen and let Microsoft's own overlays back, without touching
  anything in use. Cutting a working client's overlays was unnecessary.
- **Normalise before matching.** `String.Trim()` removes Unicode whitespace but
  **not** control characters, so `Trim()` plus a `^MEGA` match finds zero of six
  `U+0001`-prefixed keys. Strip `^[\s\p{C}]+`. This cost a debugging round; the
  code carries a comment so it does not cost another.

## Reading the timings

`Audit-Explorer.ps1` times two things per folder:

- **shell** — enumeration through `Shell.Application`, which runs every property
  and thumbnail handler, the same work Explorer does
- **fs** — `Get-ChildItem`, which runs none of it

The ratio is the shell tax. On the reference machine it was 20x to 155x
depending on the folder.

**It is noisy.** Repeated runs on the same folder gave 25x, 65x and 155x
depending on cache state. Treat it as an order of magnitude. The filesystem half
is the stable number: 1 to 3 ms, every time.

The attributable, low-variance measure of a blocking change is the **module
count** and the **third-party DLL list** for explorer.exe, which is why the
optimiser prints both before and after and says plainly that memory and handle
drops are partly the restart.

## Explorer settings

Two settings, both configurable, both off if you say so.

**`SeparateProcess = 1`** (`HKCU\...\Explorer\Advanced`) launches folder windows
in their own process. Costs memory, buys isolation: a hung extension can no
longer take the desktop with it. Note the audit reports the *oldest* explorer.exe
as the shell, since with this on there are several.

**`DisableGraphRecentItems = 1`**
(`HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer`) stops the Office/Graph
"Recommended" fetch on the Home view — a network round trip on a file manager
window.

## Drift and the watchdog

The Windows 11 XAML shell accumulates handles and threads with uptime. After 138
hours on the reference machine: 633 MB private, 8,032 handles, 304 threads.
After a restart: 171 MB, 3,744, 136. No setting changes this.

A restart closes open Explorer windows, so the watchdog refuses to act unless
**all four** hold:

1. a threshold is exceeded (`MaxHandles` or `MaxPrivateMB`)
2. no Explorer windows are open
3. you have been idle at least `IdleMinutes` (via `GetLastInputInfo`)
4. the last restart was over `CooldownHours` ago

Every check appends a row to `logs/watchdog.csv` including the decision and why,
so you can see your own drift rate before choosing thresholds.

It never launches the shell from an elevated process. An elevated explorer.exe
inherits the elevated token: drag-and-drop from normal apps stops working and
every child it spawns runs as administrator. `Restart-Explorer.ps1` detects that
case and refuses with an explanation.

## Search

See [search-scope.md](search-scope.md). It is its own document because almost
nothing about it is what you would expect.
