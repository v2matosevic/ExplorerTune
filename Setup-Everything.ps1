<#
.SYNOPSIS
  Installs voidtools Everything and wires it into Explorer's right-click menu.
  Dry-run unless -Apply. NOT run for you: this installs a machine-wide tool.

.DESCRIPTION
  Why this exists at all: Explorer's search box cannot be made fast for
  filename search. It queries the Windows Search index with a combined
  name-plus-content query and post-filters the result. Everything reads the
  NTFS Master File Table directly and answers filename queries in single-digit
  milliseconds on any size of volume, with no content index to maintain.

  That split is the whole strategy:
    filename search  -> Everything
    content search   -> Windows Search, scoped by Set-SearchScope.ps1

  HOW IT IS WIRED IN, AND WHY THAT WAY: this adds two static 'shell' verbs
  (Directory and Directory\Background) pointing at Everything.exe. A static
  verb is a registry command string. It costs nothing at runtime, unlike a
  'shellex' handler, which is a DLL loaded into explorer.exe on every
  right-click. We just finished removing nine of those, so adding one back
  would be self-defeating.

  If the Everything installer registers its own DLL handler, block it:
      .\Optimize-Explorer.ps1 -Apply -Only everything-dll
  after adding a target for it. The static verbs below do the same job for free.

.PARAMETER Apply
  Actually install and write.

.PARAMETER SkipInstall
  Only add the context-menu verbs; assume Everything is already installed.

.PARAMETER Hotkey
  Global hotkey to focus Everything. Default 'Ctrl+Alt+F'. Empty string to skip.
#>
[CmdletBinding()]
param([switch]$Apply, [switch]$SkipInstall, [string]$Hotkey = 'Ctrl+Alt+F')

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$candidates = @(
    "$env:ProgramFiles\Everything\Everything.exe"
    "${env:ProgramFiles(x86)}\Everything\Everything.exe"
    "$env:LOCALAPPDATA\Programs\Everything\Everything.exe"
)
$exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

Write-Host ""
Write-Host "  CURRENT" -ForegroundColor White
"    Everything installed : $(if ($exe) { $exe } else { 'no' })"
"    Everything service   : $((Get-Service Everything -ErrorAction SilentlyContinue).Status)"
"    winget available     : $([bool](Get-Command winget -ErrorAction SilentlyContinue))"
Write-Host ""
Write-Host "  PLAN" -ForegroundColor Cyan
if (-not $exe -and -not $SkipInstall) {
    "    winget install --id voidtools.Everything --accept-package-agreements --accept-source-agreements"
    "      ^ machine-wide install, adds a service that reads the NTFS journal"
}
"    add static verb  HKCR\Directory\shell\EverythingSearch            -> 'Search with Everything'"
"    add static verb  HKCR\Directory\Background\shell\EverythingSearch -> 'Search this folder with Everything'"
if ($Hotkey) { "    set global hotkey $Hotkey in Everything.ini" }
Write-Host ""

if (-not $Apply) {
    Say "dry run. nothing was installed or written. re-run with -Apply." warn
    exit 0
}

Assert-Elevated

# ---------------------------------------------------------------- install ----

if (-not $exe -and -not $SkipInstall) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Say "winget is not available; install Everything from https://www.voidtools.com and re-run with -SkipInstall" err
        exit 1
    }
    Say "installing Everything via winget..." plan
    & winget install --id voidtools.Everything --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { Say "winget exited $LASTEXITCODE" warn }
    Start-Sleep -Seconds 5
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $exe) { Say "cannot find Everything.exe after install; stopping before the registry step" err; exit 1 }
Say "using $exe" ok

# ------------------------------------------------------- context-menu verbs ----

$bk = New-BackupDir 'everything'
Backup-RegKey 'HKEY_CLASSES_ROOT\Directory\shell' $bk 'hkcr-directory-shell' | Out-Null
Backup-RegKey 'HKEY_CLASSES_ROOT\Directory\Background\shell' $bk 'hkcr-directory-bg-shell' | Out-Null
Say "backup -> $bk" ok

New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script -ErrorAction SilentlyContinue | Out-Null

$verbs = @(
    @{ Key = 'HKCR:\Directory\shell\EverythingSearch';            Text = 'Search with Everything';            Arg = '-path "%1"' }
    @{ Key = 'HKCR:\Directory\Background\shell\EverythingSearch'; Text = 'Search this folder with Everything'; Arg = '-path "%V"' }
)
foreach ($v in $verbs) {
    New-Item -Path $v.Key -Force | Out-Null
    Set-ItemProperty -LiteralPath $v.Key -Name '(default)' -Value $v.Text -Force
    Set-ItemProperty -LiteralPath $v.Key -Name 'Icon' -Value "`"$exe`",0" -Force
    New-Item -Path (Join-Path $v.Key 'command') -Force | Out-Null
    Set-ItemProperty -LiteralPath (Join-Path $v.Key 'command') -Name '(default)' -Value ("`"$exe`" " + $v.Arg) -Force
    Say "  added verb: $($v.Text)" ok
}

# ------------------------------------------------------------------ hotkey ----

if ($Hotkey) {
    $ini = Join-Path $env:APPDATA 'Everything\Everything.ini'
    if (Test-Path $ini) {
        Copy-Item $ini (Join-Path $bk 'Everything.ini.bak') -Force
        # Everything encodes the hotkey as a numeric vk + modifier mask, which is
        # not worth reverse-engineering here. Point at the UI instead of writing
        # a value that might be wrong.
        Say "  set the hotkey in Everything: Tools -> Options -> General -> Keyboard ($Hotkey)" warn
    }
    else {
        Say "  Everything.ini not created yet; launch Everything once, then set the hotkey in Tools -> Options" warn
    }
}

Say ""
Say "done. right-click any folder to check the verbs appeared." ok
Say "undo:  .\Restore-Explorer.ps1 -From `"$bk`"" warn
Save-Log $bk
