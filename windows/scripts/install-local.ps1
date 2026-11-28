# Claude Pet for Windows: build this checkout and install it, as CI's bundle would be.
#   powershell -ExecutionPolicy Bypass -File windows\scripts\install-local.ps1 [-Force]
#
# The same steps as .github/workflows/windows.yml: a release pet-emit with the Swift runtime DLLs,
# smoke-tested with only the bundle's DLLs on PATH; the Electron app from electron-builder after
# phone access's tests; both laid out as the bundle (pet-emit\, app\); then the bundle's own
# install.ps1. No waiting on CI or on the artifact's download. The app is built in
# %LOCALAPPDATA%\ClaudePet-build (a copy of windows\ and Resources\pet), so the checkout's own
# node_modules (under windows\) is never touched; one run at a time holds that folder.
#
# Like scripts/check-main.sh on the Mac, it refuses a checkout that lacks commits on origin/main:
# the last install wins, and one from a branch cut before a fix merged puts the old code back.
# -Force (or CLAUDE_PET_INSTALL_ANYWAY=1) installs it anyway; don't reach for it on the user's
# behalf.
#
# Needs Swift 6.1.2 for Windows and Node 20+. Keep this file ASCII: Windows PowerShell 5.1 reads
# a BOM-less script as ANSI.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# A shell started before the Swift install lacks it on PATH: the registry's PATH and SDKROOT, as a
# new login would have them, ahead of this shell's own (which keeps a Node set up per session).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
$sdk = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
if ($sdk) { $env:SDKROOT = $sdk }

function Step($text) { Write-Host "==> $text" }
function Must($what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" } }

# ------------------------------------------------------------------ is this checkout behind main?
# Whether $root is the top of its own git checkout (not a source tree without .git sitting inside
# some other repository, which would be judged by that repository's HEAD).
function Test-OwnCheckout {
  $ErrorActionPreference = 'Continue'
  $top = git -C $root rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $top) { return $false }
  return (Resolve-Path $top).Path.TrimEnd('\') -eq $root.TrimEnd('\')
}

function Test-Main {
  # Here only: git's own stderr, redirected, must not count as a PowerShell error (5.1 throws).
  $ErrorActionPreference = 'Continue'
  if (-not (Test-OwnCheckout)) { Write-Host '    not a git checkout of its own - not checked'; return }
  git -C $root remote get-url origin *> $null
  if ($LASTEXITCODE -ne 0) { Write-Host '    no remote named origin - not checked'; return }
  Step 'fetching origin/main'
  # Never a prompt (a passphrase, a host key, a password): fail instead. And 20 s at most, then
  # the whole process tree goes (git, ssh, git-remote-https).
  $env:GIT_TERMINAL_PROMPT = '0'
  $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=5'
  $fetch = Start-Process git -NoNewWindow -PassThru -RedirectStandardError (Join-Path $env:TEMP 'claudepet-fetch.err') -ArgumentList @(
    '-C', "`"$root`"", '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=10',
    'fetch', '-q', 'origin', '+refs/heads/main:refs/remotes/origin/main')
  # PowerShell 5.1 loses the exit code (ExitCode reads empty) unless the handle was taken first.
  $null = $fetch.Handle
  if (-not $fetch.WaitForExit(20000)) {
    taskkill /T /F /PID $fetch.Id *> $null
    Write-Host '    (no answer from origin in 20s - comparing with the last fetched copy)'
  } elseif ($fetch.ExitCode -ne 0) {
    Write-Host '    (could not fetch origin/main - comparing with the last fetched copy)'
  }
  Remove-Item Env:GIT_SSH_COMMAND, Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
  git -C $root rev-parse -q --verify 'refs/remotes/origin/main^{commit}' *> $null
  if ($LASTEXITCODE -ne 0) { Write-Host '    no origin/main to compare with - not checked'; return }
  git -C $root merge-base --is-ancestor refs/remotes/origin/main HEAD
  if ($LASTEXITCODE -eq 0) { return }
  if ($LASTEXITCODE -ne 1) { Write-Host '    could not compare this checkout with origin/main - not checked'; return }
  $missing = git -C $root rev-list --count HEAD..refs/remotes/origin/main
  $branch = git -C $root symbolic-ref -q --short HEAD
  if ($branch) { $fix = "git -C `"$root`" merge origin/main      (or rebase)" }
  else { $branch = 'detached at ' + (git -C $root rev-parse --short HEAD); $fix = "git -C `"$root`" checkout --detach origin/main" }
  Write-Host ''
  Write-Host "!!  This checkout ($branch) is missing $missing commit(s) that are on origin/main:"
  git -C $root log --oneline --no-decorate -8 HEAD..refs/remotes/origin/main | ForEach-Object { Write-Host "      $_" }
  if ([int]$missing -gt 8) { Write-Host '      ...' }
  Write-Host '    Installing it would put the installed pet back to code without them.'
  Write-Host '    Install from main, or bring this checkout up to date first:'
  Write-Host "      $fix"
  throw 'Not installed. Re-run with -Force to install it anyway.'
}
if ($Force -or $env:CLAUDE_PET_INSTALL_ANYWAY -eq '1') {
  Write-Host '    -Force / CLAUDE_PET_INSTALL_ANYWAY=1: origin/main not checked'
} else {
  Test-Main
}

$sha = 'local'
if (Test-OwnCheckout) {
  $sha = "$(git -C $root rev-parse --short HEAD)".Trim()
  if (git -C $root status --porcelain) { Write-Host '    note: uncommitted changes are built in too' }
}

# ------------------------------------------------------------------ one run at a time
# Two runs (two sessions, two worktrees) would mirror over each other's staging copy and bundle
# mid-build and install a mix of both. The lock is held until this script ends.
$stage = Join-Path $env:LOCALAPPDATA 'ClaudePet-build'
New-Item -ItemType Directory -Force $stage | Out-Null
try {
  $lockFile = [IO.File]::Open((Join-Path $stage 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
  throw "another install-local.ps1 is running (it holds $stage\run.lock)"
}

try {
  # ---------------------------------------------------------------- pet-emit
  Step 'building pet-emit (release)'
  Push-Location $root
  try { swift build -c release --product PetEmit; Must 'swift build' } finally { Pop-Location }
  # .build\release is only a symlink, which SwiftPM can't make without Developer Mode.
  $emit = Join-Path $root '.build\x86_64-unknown-windows-msvc\release\PetEmit.exe'
  if (-not (Test-Path $emit)) { throw "no $emit after the build" }

  $bundle = Join-Path $env:TEMP "ClaudePet-bundle-$sha"
  Step "assembling the bundle in $bundle"
  if (Test-Path $bundle) { Remove-Item $bundle -Recurse -Force }
  New-Item -ItemType Directory -Force (Join-Path $bundle 'pet-emit') | Out-Null
  Copy-Item $emit (Join-Path $bundle 'pet-emit\pet-emit.exe')
  $core = (& { $ErrorActionPreference = 'Continue'; where.exe swiftCore.dll 2>$null }) | Select-Object -First 1
  if (-not $core) { throw 'swiftCore.dll is not on PATH: is Swift for Windows installed?' }
  Copy-Item (Join-Path (Split-Path $core) '*.dll') (Join-Path $bundle 'pet-emit')

  # As CI: with no Swift toolchain on PATH, so a runtime DLL missing from the bundle fails here
  # rather than in a hook.
  Step 'smoke-testing pet-emit (only the bundle''s DLLs on PATH)'
  $keepPath = $env:Path
  $env:Path = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
  try {
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'windows\scripts\smoke.ps1') (Join-Path $bundle 'pet-emit\pet-emit.exe')
    Must 'smoke.ps1'
  } finally { $env:Path = $keepPath }

  # ---------------------------------------------------------------- the app
  Step 'building the app (electron-builder)'
  # In a copy of windows\ and Resources\pet, never in the checkout: `npm ci` there deletes
  # windows\node_modules first, and a dev pet or prototype another session runs from it holds
  # electron's files open (EBUSY halfway through leaves that node_modules gutted). The copy keeps
  # its own node_modules between runs and reinstalls only when package-lock.json changed.
  # Resources\pet is package.json's only extraResources entry (../Resources/pet): a new one there
  # must be mirrored here too.
  function Mirror($from, $to, [string[]]$skip) {
    $xd = @(); if ($skip) { $xd = @('/XD') + $skip }
    robocopy $from $to /MIR /NFL /NDL /NJH /NJS /NP @xd | Out-Null
    # robocopy: below 8 is success (1 = files copied); excluded folders are not purged.
    if ($LASTEXITCODE -ge 8) { throw "copying $from failed (robocopy $LASTEXITCODE)" }
    $global:LASTEXITCODE = 0
  }
  Mirror (Join-Path $root 'windows') (Join-Path $stage 'windows') @('node_modules', 'dist', 'dist-*')
  Mirror (Join-Path $root 'Resources\pet') (Join-Path $stage 'Resources\pet')
  $app = Join-Path $stage 'windows'
  $lock = (Get-FileHash (Join-Path $app 'package-lock.json')).Hash
  $stamp = Join-Path $stage 'installed-lock.txt'
  Push-Location $app
  try {
    if (-not (Test-Path 'node_modules') -or -not (Test-Path $stamp) -or (Get-Content $stamp) -ne $lock) {
      # Gone first: an npm ci that fails halfway must not leave a stamp vouching for what it wiped.
      Remove-Item $stamp -ErrorAction SilentlyContinue
      npm ci --no-audit --no-fund; Must 'npm ci'
      Set-Content $stamp $lock
    }
    node --test test/remote.test.js; Must 'phone access tests (node --test)'
    if (Test-Path 'dist') { Remove-Item 'dist' -Recurse -Force }
    # --no-install: the pinned electron-builder in node_modules or nothing, never the registry's
    # latest. Failing to unpack winCodeSign: see "Gotchas already hit" in windows\CLAUDE.md.
    npx --no-install electron-builder --win dir --x64 --publish never; Must 'electron-builder'
  } finally { Pop-Location }

  Copy-Item (Join-Path $app 'dist\win-unpacked') (Join-Path $bundle 'app') -Recurse
  Copy-Item (Join-Path $root 'windows\scripts\install.ps1'), (Join-Path $root 'windows\scripts\uninstall.ps1') $bundle

  # ---------------------------------------------------------------- install
  Step "installing $sha"
  powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bundle 'install.ps1')
  Must 'install.ps1'
  Remove-Item $bundle -Recurse -Force -ErrorAction SilentlyContinue
} finally {
  $lockFile.Dispose()
}
