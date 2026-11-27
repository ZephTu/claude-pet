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

# A settings.json shaped like a real one: booleans, 0/1, floats, non-ASCII, the user's own hooks,
# a UTF-8 BOM. Whatever Windows Foundation makes of it, the user's values must come back intact.
$real = @'
{"model":"opus","includeCoAuthoredBy":false,"cleanupPeriodDays":1,"ratio":0.75,"zero":0,
 "statusLine":{"type":"command","command":"bash ~/.claude/statusline.sh"},
 "env":{"GREETING":"\u4f60\u597d \u2014 caf\u00e9"},
 "hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine","timeout":3}]}]}}
'@
[IO.File]::WriteAllText($settings, $real, (New-Object Text.UTF8Encoding($true)))
& $Emit --patch-settings $settings | Out-Null
Check 'a real settings.json (with a BOM) patches' $LASTEXITCODE 0
$p = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
Check '...the hook command is quoted for Git Bash' ($p.hooks.Stop.hooks.command -contains '"$HOME/.claude/pet/pet-emit"') 'True'
Check '...the user''s own Stop hook stays' ($p.hooks.Stop.hooks.command -contains 'echo mine') 'True'
& $Emit --unpatch-settings $settings | Out-Null
$u = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
Check '...and after unpatching: false is still false' $u.includeCoAuthoredBy 'False'
Check '...1 is still 1' $u.cleanupPeriodDays 1
Check '...0.75 is still 0.75' $u.ratio 0.75
Check '...0 is still 0' $u.zero 0
$greeting = [string][char]0x4f60 + [char]0x597d + ' ' + [char]0x2014 + ' caf' + [char]0x00e9
Check '...non-ASCII text survives' $u.env.GREETING $greeting
Check '...the statusline is untouched' $u.statusLine.command 'bash ~/.claude/statusline.sh'
Check '...the user''s hook is still there' (@($u.hooks.Stop.hooks.command) -join ',') 'echo mine'

# The unquoted command an earlier spike build wrote is upgraded in place, not duplicated.
[IO.File]::WriteAllText($settings, '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/pet/pet-emit","timeout":5}]}]}}')
& $Emit --patch-settings $settings | Out-Null
$p = Get-Content $settings -Raw | ConvertFrom-Json
Check 'the old unquoted command is upgraded in place' ((@($p.hooks.Stop.hooks.command)) -join ',') '"$HOME/.claude/pet/pet-emit"'

Remove-Item $home_ -Recurse -Force -ErrorAction SilentlyContinue
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
