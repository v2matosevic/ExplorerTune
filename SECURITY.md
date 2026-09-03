# Security policy

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private reporting:
**Security → Report a vulnerability** on this repository.

Include what an attacker could do and how to reproduce it. Expect a first reply
within a week; this is a spare-time project, not a product with an on-call
rotation.

## What this tool does to your system

Stated plainly so you can judge the risk yourself.

**It writes to HKLM and HKCU.** Specifically:

- `HKLM\...\Shell Extensions\Blocked` — adds CLSIDs so Explorer refuses to load
  them, in both the 64-bit and 32-bit registry views
- `HKCR\...\shellex\*` — deletes registrations whose CLSID resolves to no COM
  server
- `HKLM\...\ShellIconOverlayIdentifiers` — deletes dead overlay entries
- `HKCU\...\Explorer\Advanced` — `SeparateProcess`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer` — `DisableGraphRecentItems`
- `HKLM\SOFTWARE\Microsoft\Windows Search\...` — deletes stale crawl rules, only
  in `Clear-SearchRuleJunk.ps1`
- `HKCR\Directory\shell\...` — adds static verbs, only in `Setup-Everything.ps1`

**It calls undocumented-layout COM interfaces.** `lib/SearchApi.ps1` reaches
`ISearchCrawlScopeManager` through hand-declared vtable offsets, because there is
no type library. It discovers the interface IIDs at runtime and refuses every
mutating call unless read-only probes prove the layout first. See
[docs/search-scope.md](docs/search-scope.md).

**It can install other software**, only from `Setup-Everything.ps1`, only with
`-Apply`, and only voidtools Everything via `winget`.

**It talks to no network** other than that `winget` call. No telemetry, no
update check, no analytics.

**It never disables a security feature.** It does not touch Defender,
SmartScreen, UAC, real-time protection, or any antivirus. If a future change
appears to, that is a bug — please report it.

## Things to know before you run it

- **Blocking a shell extension is a functional change**, not just a performance
  one. Sync badges and menu entries disappear. Read the `Note` field in
  `handlers/catalog.psd1` first.
- **Backups are registry exports.** They restore registry state. They cannot
  restore search crawl scope, because that lives in the WSearch service rather
  than the registry.
- **Review before you run.** It is a few thousand lines of PowerShell with no
  binaries and no obfuscation. Reading `Optimize-Explorer.ps1` end to end takes
  about ten minutes, and doing that is a reasonable thing to ask of yourself
  before letting a stranger's script edit HKLM.
