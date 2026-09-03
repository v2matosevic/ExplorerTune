# Case study: one real machine

The audit ExplorerTune was built from, anonymised. A developer workstation,
Windows 11 Pro build 26100, 48 GB RAM, four fixed volumes, 138 hours of uptime.
The complaint was ordinary: *Explorer is slow and search never finds anything.*

Numbers here came from `Audit-Explorer.ps1`. They are one machine, not a
benchmark. The value is in the *shape* of the problems, which turns out to be
common.

## Baseline

| Metric | Measured | Healthy |
|---|---|---|
| explorer.exe private bytes | 633 MB | 120-200 MB |
| explorer.exe handles | 8,032 | ~2,000 |
| explorer.exe threads | 304 | 60-100 |
| Loaded modules | 404 | ~250 |
| Third-party DLLs inside explorer.exe | 17 | 0-3 |
| Third-party shell handler registrations | 61 of 114 | <15 |
| Icon overlay handlers | 18 registered, 15 honoured | <15 |
| Search crawl rules | 794 working-set + 64 default | <30 |
| Shellbags | 2,006 BagMRU keys | <500 |
| Thumbnail cache | 376 MB | fine, not a problem |

Shell enumeration against raw filesystem, same folders:

```
Downloads     14 items    shell  65 ms    fs  3 ms
Desktop       11 items    shell  11 ms    fs  1 ms
Documents      2 items    shell  21 ms    fs  1 ms
```

The filesystem was never the problem. Everything layered on top of it was.

That ratio is noisy — repeated runs on Downloads gave 25x, 65x and 155x
depending on cache state. Treat it as an order of magnitude. The filesystem half
was 1-3 ms every single time.

## What was already fine

Worth listing, because the internet's standard advice would have had this person
change all of it for nothing:

- web and cloud search integration already off, all six flags
- `LaunchTo` already set to This PC rather than Home
- thumbnail cache at 376 MB, which is normal; clearing it costs a re-render and
  gains nothing
- no mapped or disconnected network drives
- four autostart entries, all wanted

Whoever set this machine up had already done the easy tier. What remained was
structural.

## Problem 1: seventeen third-party DLLs in the shell

Loaded into explorer.exe at audit time, from nine different vendors: two cloud
sync clients, a creative suite's sync agent and its PDF context menu, an
archiver, an ISO tool, a text editor, an FTP client's copy hook, a graphics
suite's property handlers, and a GPU control panel.

Two entries stood out.

**A copy hook.** Consulted on every folder copy, move, rename and delete,
whether or not the application is running. One registry entry, a cost on every
file operation the user performs.

**Per-extension property and thumbnail handlers.** Two DLLs from a graphics
suite, registered against file extensions rather than under a context-menu hook.
They did not appear in a context-menu scan at all, but they were loaded in the
process, and handlers of that kind run when you *look* at a folder, not when you
right-click.

## Problem 2: ten registrations for software that was not installed

One sync client had been uninstalled. Its directory was gone from both
`Program Files` and `%LOCALAPPDATA%`. Ten registrations survived:

- 3 icon overlay handlers in each of two registry views = 6
- 4 context-menu handlers (Directory, Drive, `*`, AllFilesystemObjects)

Every one resolved to a CLSID with **no COM server**. Explorer was calling
`CoCreateInstance` on all ten, on every right-click and every icon paint, taking
the failure, and moving on.

This is why dead-registration removal is automatic and on by default. There is
nothing to weigh up.

## Problem 3: the overlay slot war

Windows honours the first 15 overlay handlers by sort order. Eighteen were
registered. The key names:

```
"   AccExtIco1".."3"      U+0020 x3    creative suite sync
"   DropboxExt01".."10"   U+0020 x3    a sync client, ten slots
" MEGA (Pending)"         U+0001       another sync client
" MEGA (Synced)"          U+0001
" MEGA (Syncing)"         U+0001
"EnhancedStorageShell"    unpadded     Microsoft
"Offline Files"           unpadded     Microsoft
```

Three vendors padded their key names to jump the queue. One used **U+0001**, a
C0 control character, which sorts ahead of everyone padding with spaces. Between
them they held sixteen contenders ahead of Microsoft's two unpadded handlers,
which were therefore evicted.

The fix needed no judgement call: deleting the three dead entries brought the
total to exactly fifteen, so every remaining handler including Microsoft's own
fitted. **Trimming the working sync client's ten slots was not necessary**, which
is why ExplorerTune does not propose it.

This also caused a bug worth recording. Matching those key names with `^MEGA`
finds nothing, and `String.Trim()` does not fix it, because `Trim()` removes
Unicode whitespace but not control characters. The normaliser has to strip
`^[\s\p{C}]+`.

## Problem 4: search was looking at the wrong disks, then at none of them

The registry held 38 whole-drive include rules: the four present volumes, one
for a drive letter that no longer existed, and **34 for volumes no longer
attached** — 25 of them for a single removable letter that had seen 25 different
sticks. On top sat 794 auto-generated exclusion rules, nearly all individual
dependency subdirectories from two copies of a project that had been deleted.

That was the obvious diagnosis, and it was wrong.

Asked through the API, the two drives holding all the user's actual work were
**entirely out of the live crawl scope**, while the registry showed `include=1`
for both. Search never found their projects because it had never looked at them.
Not bloat. Blindness.

Full detail: [search-scope.md](search-scope.md).

## Problem 5: drift

8,032 handles and 304 threads after 138 hours is the Win11 XAML shell
accumulating. No registry setting addresses it. A restart takes about a second
and costs you your open Explorer windows.

## Results

| Metric | Before | After |
|---|---|---|
| explorer.exe private bytes | 633 MB | **171 MB** |
| explorer.exe handles | 8,032 | **3,744** |
| explorer.exe threads | 304 | **136** |
| Loaded modules | 404 | **304** |
| Third-party DLLs inside explorer.exe | 17 | **3** |
| Icon overlays | 18 registered / 15 honoured | **15 / 15, none evicted** |
| Dead registrations | 10 | **0** |
| Crawl rules | 794 + 64 | **120 + 23** |
| Project drive in search scope | no | **yes**, build output excluded |

Twenty-six CLSIDs blocked across six vendors, ten dead registrations deleted.

**Read that memory drop carefully.** Much of it is the restart clearing 138 hours
of accumulated drift, not the blocking. The honest, attributable measures are the
module count (404 to 304) and the DLL list: all nine blocked DLLs confirmed
absent from the process afterwards. This is why the optimiser prints both and
says so.

## Three things that turned out to be wrong

Kept because being wrong in public is more useful than the tidy version.

**The volume GUID in a crawl rule is not the volume GUID.** Rules for the
project drive used one identifier; `mountvol` reported a completely different one
for the same volume at the same moment. Rules generated from `mountvol` would
have been silently ignored — no error, they just never match. Caught by diffing
generated output against the machine's own live rules before applying anything.

**The crawl scope cannot be written from the registry.** The first
implementation did exactly that. The writes were denied even elevated, and the
service restored what had been deleted within three minutes. That whole approach
had to be replaced with the COM API.

**A script reported success it had not achieved.** That same run printed
"wrote 82 rules" while all 82 writes were being denied, because the counter came
from the length of the input list rather than from what succeeded. The
verification step caught the lie and reported zero rules absorbed, which is the
only reason it was noticed. Two lessons, both now in `CLAUDE.md`: increment
inside the `try`, and verify by asking the system for its state rather than
re-reading the value you just tried to set.
