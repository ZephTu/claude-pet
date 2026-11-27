# Smoke test of pet-emit.exe on Windows: the hook writes session files, a held permission prompt
# is answered through --decide, --watch prints the state, and settings.json is patched and
# unpatched. Run by CI against the bundle (only the DLLs beside the exe on PATH).
#   powershell -File smoke.ps1 <path to pet-emit.exe>
param([Parameter(Mandatory = $true)][string]$Emit)
$ErrorActionPreference = 'Stop'
$failed = 0
function Check($name, $actual, $expected) {
  if ("$actual" -eq "$expected") { Write-Host "ok   $name" }
  else { Write-Host "FAIL $name`n     expected: $expected`n     actual:   $actual"; $script:failed++ }
}

$home_ = Join-Path ([IO.Path]::GetTempPath()) ("pet-smoke-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $home_ | Out-Null
$env:PET_HOME = $home_
$env:PET_PERMISSION_WAIT = '0'

function Emit($json) {
  $in = Join-Path $home_ 'in.json'
  [IO.File]::WriteAllText($in, $json)
  $p = Start-Process -FilePath $Emit -RedirectStandardInput $in -NoNewWindow -PassThru -Wait
  return $p.ExitCode
}
function Field($session, $name) {
  $f = Join-Path $home_ "sessions\$session.json"
  if (-not (Test-Path $f)) { return '<no file>' }
  return (Get-Content $f -Raw | ConvertFrom-Json).$name
}

$v = & $Emit --version
Check 'pet-emit starts with only its own DLLs' $LASTEXITCODE 0
Write-Host "     version $v"

Check 'SessionStart exits 0' (Emit '{"session_id":"s1","hook_event_name":"SessionStart","transcript_path":"C:\\t\\s.jsonl","cwd":"C:\\work\\demo"}') 0
Check 'SessionStart writes the session as idle' (Field s1 state) 'idle'
Check '...under its folder name' (Field s1 project) 'demo'
Emit '{"session_id":"s1","hook_event_name":"UserPromptSubmit","transcript_path":"C:\\t\\s.jsonl","cwd":"C:\\work\\demo","prompt":"hi"}' | Out-Null
Check 'UserPromptSubmit makes it busy' (Field s1 state) 'busy'

# A held prompt, answered from "the pet".
$env:PET_PERMISSION_WAIT = '20'
$in = Join-Path $home_ 'ask.json'
$out = Join-Path $home_ 'ask.out'
[IO.File]::WriteAllText($in, '{"session_id":"s9","hook_event_name":"PermissionRequest","transcript_path":"C:\\t\\s.jsonl","cwd":"C:\\work\\demo","tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}')
$held = Start-Process -FilePath $Emit -RedirectStandardInput $in -RedirectStandardOutput $out -NoNewWindow -PassThru
$env:PET_PERMISSION_WAIT = '0'
$ask = ''
for ($i = 0; $i -lt 50 -and -not $ask; $i++) {
  Start-Sleep -Milliseconds 200
  $f = Join-Path $home_ 'sessions\s9.json'
  if (Test-Path $f) {
    try { $doc = Get-Content $f -Raw | ConvertFrom-Json; if ($doc.asks) { $ask = @($doc.asks)[-1].id } } catch {}
  }
}
Check 'PermissionRequest makes it waiting' (Field s9 state) 'waiting'
Check '...and records an ask id' ([bool]$ask) 'True'
& $Emit --decide s9 $ask allow
Check '--decide exits 0' $LASTEXITCODE 0
$done = $held.WaitForExit(10000)
Check 'the held hook returns once answered' $done 'True'
$answer = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
Check '...with the allow decision' ($answer -match '"behavior"\s*:\s*"allow"') 'True'

# --watch prints the state as JSON lines.
$wout = Join-Path $home_ 'watch.out'
$w = Start-Process -FilePath $Emit -ArgumentList '--watch' -RedirectStandardOutput $wout -NoNewWindow -PassThru
Start-Sleep -Seconds 3
Stop-Process -Id $w.Id -Force
$line = (Get-Content $wout -TotalCount 1)
$state = $line | ConvertFrom-Json
Check '--watch prints a JSON line with the mood' ([bool]$state.mood) 'True'
Check '...and both sessions' (@($state.sessions).Count) 2

# settings.json: patched and unpatched.
$settings = Join-Path $home_ 'settings.json'
[IO.File]::WriteAllText($settings, '{"model":"opus"}')
& $Emit --patch-settings $settings | Out-Null
Check '--patch-settings exits 0' $LASTEXITCODE 0
$patched = Get-Content $settings -Raw
Check '...adds the hook' ($patched -match 'pet-emit') 'True'
Check '...keeps what was there' (($patched | ConvertFrom-Json).model) 'opus'
& $Emit --unpatch-settings $settings | Out-Null
Check '--unpatch-settings removes it again' ((Get-Content $settings -Raw) -match 'pet-emit') 'False'

Remove-Item $home_ -Recurse -Force -ErrorAction SilentlyContinue
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
