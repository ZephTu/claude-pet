# Claude Pet for Windows (spike): install from the unzipped bundle.
#   powershell -ExecutionPolicy Bypass -File install.ps1
# Puts pet-emit.exe (and the Swift runtime DLLs it needs) in %USERPROFILE%\.claude\pet, wires
# its hooks into %USERPROFILE%\.claude\settings.json (backed up first), and installs the app to
# %LOCALAPPDATA%\Programs\ClaudePet with a Start menu shortcut. uninstall.ps1 undoes all three.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$claude = Join-Path $HOME '.claude'
if (-not (Test-Path $claude)) { throw "no $claude - Claude Code is not installed here" }
$pet = Join-Path $claude 'pet'
$appDest = Join-Path $env:LOCALAPPDATA 'Programs\ClaudePet'

# A downloaded zip marks every file as from the internet; SmartScreen would stop each exe.
Get-ChildItem $here -Recurse -File | Unblock-File

Write-Host '==> stopping a running pet'
Get-Process ClaudePet -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

Write-Host "==> installing the hook to $pet"
New-Item -ItemType Directory -Force -Path (Join-Path $pet 'sessions') | Out-Null
Get-ChildItem (Join-Path $here 'pet-emit') -File | ForEach-Object {
  $dest = Join-Path $pet $_.Name
  try { Copy-Item $_.FullName $dest -Force }
  catch {
    # A hook running right now holds the file open: Windows lets it be renamed, not overwritten.
    Move-Item $dest ("$dest.old-" + (Get-Random)) -Force
    Copy-Item $_.FullName $dest -Force
  }
}
$emit = Join-Path $pet 'pet-emit.exe'
& $emit --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'pet-emit.exe does not start' }

Write-Host '==> wiring hooks (settings.json is backed up first)'
& $emit --patch-settings (Join-Path $claude 'settings.json')
if ($LASTEXITCODE -ne 0) { throw 'patching settings.json failed - it was left as it was' }

Write-Host "==> installing the app to $appDest"
if (Test-Path $appDest) { Remove-Item $appDest -Recurse -Force }
Copy-Item (Join-Path $here 'app') $appDest -Recurse
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Pet.lnk'))
$link.TargetPath = Join-Path $appDest 'ClaudePet.exe'
$link.Save()
Start-Process (Join-Path $appDest 'ClaudePet.exe')

Write-Host ''
Write-Host 'Installed. Hooks take effect in newly started Claude Code sessions.'
