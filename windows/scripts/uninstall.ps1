# Claude Pet for Windows (spike): undo install.ps1.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
$ErrorActionPreference = 'Stop'
$claude = Join-Path $HOME '.claude'
$pet = Join-Path $claude 'pet'
$emit = Join-Path $pet 'pet-emit.exe'

Write-Host '==> stopping the pet'
Get-Process ClaudePet -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process ClaudePet -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue

if (Test-Path $emit) {
  Write-Host '==> removing the hooks from settings.json (backed up first)'
  & $emit --unpatch-settings (Join-Path $claude 'settings.json')
  if ($LASTEXITCODE -ne 0) { throw 'unpatching settings.json failed - nothing else was removed' }
}

Write-Host '==> removing the app and the hook binary'
$app = Join-Path $env:LOCALAPPDATA 'Programs\ClaudePet'
Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Pet.lnk') -Force -ErrorAction SilentlyContinue
# Launch at login (the tray's checkbox), and the state Task Manager keeps for it.
foreach ($key in 'Run', 'Explorer\StartupApproved\Run') {
  Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\$key" -Name ClaudePet -ErrorAction SilentlyContinue
}
# pet-emit.exe, the runtime DLLs, and the *.old-N copies install.ps1 left when one was in use.
$binaries = { Get-ChildItem $pet -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '\.(exe|dll)(\.old-\d+)?$' -or $_.Name -like 'pet-emit*' } }
& $binaries | Remove-Item -Force -ErrorAction SilentlyContinue
# The shell's prefs and log (claude-pet-windows is where builds before productName kept them).
foreach ($d in 'ClaudePet', 'claude-pet-windows') {
  Remove-Item (Join-Path $env:APPDATA $d) -Recurse -Force -ErrorAction SilentlyContinue
}

$left = @(& $binaries) + @(if (Test-Path $app) { Get-Item $app })
if ($left.Count) {
  Write-Host 'Some files are still in use (a Claude Code session running a hook?). Close it and run this again:'
  $left | ForEach-Object { Write-Host "  $($_.FullName)" }
  exit 1
}
Write-Host "Removed. Session records in $pet were left in place."
