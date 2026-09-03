# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-03

First public release. Built and verified against Windows 11 Pro build 26100.

### Added

- `Audit-Explorer.ps1` — read-only report: shell processes, handler
  registrations split into blocked and live, third-party DLLs actually loaded
  into explorer.exe, icon overlay ranking, search state, shellbags, thumbnail
  cache, shell-vs-filesystem enumeration timings.
- `Optimize-Explorer.ps1` — automatic removal of dead shell registrations,
  opt-in blocking of catalogued handlers via the `Blocked` list in both registry
  views, and two Explorer settings. Prints before/after including the module
  count and DLL list.
- `handlers/catalog.psd1` — 24 known shell extensions with what each one is,
  when it runs, and what breaks if you block it. Community-editable; nothing is
  blocked by default.
- `Set-SearchScope.ps1` — crawl scope through `ISearchCrawlScopeManager`, driven
  by config. `-Test` queries live scope, `-Status` reports catalog state. Needs
  no administrator.
- `lib/SearchApi.ps1` — runtime discovery of the search COM interfaces by
  QueryInterface sweep, with read-only validation including a two-sided oracle
  before any mutating call is permitted.
- `Clear-SearchRuleJunk.ps1` — deletes the derived rule cache and crawl rules
  for volumes no longer attached.
- `Setup-Everything.ps1` — installs voidtools Everything and adds two static
  context-menu verbs, deliberately not a `shellex` handler.
- `watchdog/` — scheduled task that restarts explorer.exe past a handle or
  memory threshold, gated on no open windows, user idle, and a cooldown. Logs
  every decision to CSV.
- `Restore-Explorer.ps1` — undo from a run's registry exports, including
  explicit removal of the `Blocked` values this tool added.
- `explorertune.config.example.psd1` — all machine-specific paths and
  thresholds; the real config file is gitignored.
- Docs: how-it-works, search-scope, an anonymised case study, troubleshooting.

### Notes

- Nothing writes without `-Apply`. Every applying run exports the registry keys
  it will touch first and prints the restore command.
- No handler is blocked by default. Blocking is opt-in per catalog id.

[Unreleased]: https://github.com/v2matosevic/ExplorerTune/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/v2matosevic/ExplorerTune/releases/tag/v0.1.0
