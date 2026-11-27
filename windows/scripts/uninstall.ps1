# Claude Pet for Windows (spike): undo install.ps1.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
$ErrorActionPreference = 'Stop'
$claude = Join-Path $HOME '.claude'
$pet = Join-Path $claude 'pet'
$emit = Join-Path $pet 'pet-emit.exe'

Write-Host '==> stopping the pet'
Get-Process ClaudePet -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path $emit) {
  Write-Host '==> removing the hooks from settings.json (backed up first)'
  & $emit --unpatch-settings (Join-Path $claude 'settings.json')
  if ($LASTEXITCODE -ne 0) { throw 'unpatching settings.json failed - nothing else was removed' }
}

Write-Host '==> removing the app and the hook binary'
Remove-Item (Join-Path $env:LOCALAPPDATA 'Programs\ClaudePet') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Pet.lnk') -Force -ErrorAction SilentlyContinue
Get-ChildItem $pet -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in '.exe', '.dll' -or $_.Name -like 'pet-emit*' } |
  Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "Removed. Session records in $pet were left in place."
