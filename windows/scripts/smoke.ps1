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
Check '...with its transcript (a C:\ path is absolute too)' (Field s1 transcript) 'C:\t\s.jsonl'
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

# A session that finishes gets a notice, once, on the line where it happens.
$nout = Join-Path $home_ 'notice.out'
$w = Start-Process -FilePath $Emit -ArgumentList '--watch' -RedirectStandardOutput $nout -NoNewWindow -PassThru
# The watcher must have seen s1 busy first, or there is nothing to finish.
function Lines { if (Test-Path $nout) { @(Get-Content $nout | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
for ($i = 0; $i -lt 100 -and (Lines).Count -eq 0; $i++) { Start-Sleep -Milliseconds 200 }
Emit '{"session_id":"s1","hook_event_name":"Stop","transcript_path":"C:\\t\\s.jsonl","cwd":"C:\\work\\demo","last_assistant_message":"All 12 tests pass"}' | Out-Null
# A finish is announced once it has held for StateAggregator.settleAfter (10 s); the row
# shows idle at once.
for ($i = 0; $i -lt 100 -and -not @((Lines) | Where-Object { $_.notices }).Count; $i++) { Start-Sleep -Milliseconds 250 }
Stop-Process -Id $w.Id -Force
$lines = Lines
$idleAt = -1; $noticeAt = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  $s1 = @($lines[$i].sessions | Where-Object { $_.sessionId -eq 's1' })
  if ($idleAt -lt 0 -and $s1.Count -and $s1[0].state -eq 'idle') { $idleAt = $i }
  if ($noticeAt -lt 0 -and $lines[$i].notices) { $noticeAt = $i }
}
Check 'the finished row shows idle before the notice' ($idleAt -ge 0 -and $idleAt -lt $noticeAt) 'True'
$notices = @($lines | ForEach-Object { $_.notices } | Where-Object { $_ })
Check 'a finished session gets one notice' $notices.Count 1
Check '...naming the session' ($notices[0].text -like 'demo*') 'True'
Write-Host "     notice: $($notices[0].text)"
$fin = @($lines[-1].finished | Where-Object { $_.sessionId -eq 's1' })
Check 'the finish is listed under Finished' $fin.Count 1
Check '...with its summary' $fin[0].summary 'All 12 tests pass'
Check '...and counted in the badge' ([int]$lines[-1].badge -ge 1) 'True'
$fin[0].eventIds[0] | & $Emit --mark-read -
Check '--mark-read (ids on stdin) exits 0' $LASTEXITCODE 0
Check '...and records the mark' ((Get-Content (Join-Path $home_ 'read.json') -Raw) -match [regex]::Escape($fin[0].eventIds[0])) 'True'
& $Emit --mark-read --all
Check '--mark-read --all exits 0' $LASTEXITCODE 0
# A read.json that can't be read right now is not "nothing read": left as it is.
$readJson = Join-Path $home_ 'read.json'
$good = Get-Content $readJson -Raw
[IO.File]::WriteAllText($readJson, '{"read":')
$p = Start-Process -FilePath $Emit -ArgumentList '--mark-read', '--all' -RedirectStandardError (Join-Path $home_ 'mr.err') -NoNewWindow -PassThru -Wait
Check '--mark-read refuses an unreadable read.json' $p.ExitCode 1
Check '...and leaves it alone' (Get-Content $readJson -Raw) '{"read":'
[IO.File]::WriteAllText($readJson, $good)
$w = Start-Process -FilePath $Emit -ArgumentList '--watch' -RedirectStandardOutput $wout -NoNewWindow -PassThru
Start-Sleep -Seconds 3
Stop-Process -Id $w.Id -Force
Check '...and the row goes' (@((Get-Content $wout -TotalCount 1 | ConvertFrom-Json).finished).Count) 0
$detail = & $Emit --detail s1
Check '--detail prints the hover card' ((($detail | ConvertFrom-Json).path) -eq 'C:\work\demo') 'True'

# Snooze and mute (the row's clock and x), and the quota readout, as --watch reports them.
function WatchOnce {
  $o = Join-Path $home_ ("w-" + [guid]::NewGuid() + ".out")
  $p = Start-Process -FilePath $Emit -ArgumentList '--watch' -RedirectStandardOutput $o -NoNewWindow -PassThru
  for ($i = 0; $i -lt 50 -and -not ((Test-Path $o) -and (Get-Content $o -TotalCount 1)); $i++) { Start-Sleep -Milliseconds 200 }
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  $l = if (Test-Path $o) { Get-Content $o -TotalCount 1 } else { $null }
  if (-not $l) { Write-Host 'FAIL --watch printed no line'; $script:failed++; return [pscustomobject]@{ sessions = @(); quota = @() } }
  return ($l | ConvertFrom-Json)
}
function RowOf($doc, $session) { @($doc.sessions | Where-Object { $_.sessionId -eq $session }) }
Emit '{"session_id":"m1","hook_event_name":"PermissionRequest","transcript_path":"C:\\t\\s.jsonl","cwd":"C:\\work\\demo","tool_name":"Bash","tool_input":{"command":"ls"}}' | Out-Null
Check 'a second prompt waits' (Field m1 state) 'waiting'
$before = WatchOnce
& $Emit --snooze m1 15
Check '--snooze exits 0' $LASTEXITCODE 0
$p = Start-Process -FilePath $Emit -ArgumentList '--snooze', 'm1', '7' -RedirectStandardError (Join-Path $home_ 'sn.err') -NoNewWindow -PassThru -Wait
Check '--snooze refuses a delay it does not offer' $p.ExitCode 2
$after = WatchOnce
Check 'a snoozed row says when it comes back' ((RowOf $after m1)[0].snoozedFor -match '^1[45]m$') 'True'
Check '...and leaves the badge' ([int]("0" + $after.badge)) ([int]("0" + $before.badge) - 1)
& $Emit --mute m1
Check '--mute exits 0' $LASTEXITCODE 0
$after = WatchOnce
Check 'a muted session leaves the list' @(RowOf $after m1).Count 0
Check '...and is counted as muted' $after.hidden 1
Emit '{"session_id":"m1","hook_event_name":"UserPromptSubmit","transcript_path":"C:\\t\\s.jsonl","cwd":"C:\\work\\demo","prompt":"go on"}' | Out-Null
$after = WatchOnce
Check 'typing into it brings it back' @(RowOf $after m1).Count 1
& $Emit --mute m1
& $Emit --unmute-all
Check '--unmute-all exits 0' $LASTEXITCODE 0
Check '...and brings it back' @(RowOf (WatchOnce) m1).Count 1
# PET_HOME does not move ~\.claude: an old claude-hud's own cache there would be read too.
$hudCache = Join-Path $env:USERPROFILE '.claude\plugins\claude-hud\.usage-cache.json'
if (Test-Path $hudCache) {
  Write-Host "skip the quota checks: $hudCache exists on this machine"
} else {
  Check 'no quota reading: the fallback line' ([bool]$after.quotaFallback -and @($after.quota).Count -eq 0) 'True'
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
  $at = [DateTime]::UtcNow
  $hud = '{"updated_at":"' + $at.ToString($fmt, $inv) + '","five_hour":{"used_percentage":42,"resets_at":"' +
    $at.AddMinutes(90).ToString($fmt, $inv) + '"},"seven_day":{"used_percentage":17.4,"resets_at":"' +
    $at.AddDays(3).ToString($fmt, $inv) + '"}}'
  [IO.File]::WriteAllText((Join-Path $home_ 'hud-usage.json'), $hud)
  $q = @((WatchOnce).quota)
  Check 'claude-hud''s snapshot gives two meters' $q.Count 2
  Check '...the five-hour one' "$($q[0].label) $($q[0].percent)" '5h 42'
  Check '...and the week' "$($q[1].label) $($q[1].percent)" 'week 17'
}

# Which terminal a session is in: Windows Terminal from WT_SESSION, but not under a terminal that
# names itself (VS Code inherits WT_SESSION when started from one).
$saved = @{ TERM_PROGRAM = $env:TERM_PROGRAM; ORCA_TERMINAL_HANDLE = $env:ORCA_TERMINAL_HANDLE; WT_SESSION = $env:WT_SESSION }
$env:TERM_PROGRAM = $null; $env:ORCA_TERMINAL_HANDLE = $null
$env:WT_SESSION = '9fe93318-97be-4312-aa76-aebcb40de3ea'
Emit '{"session_id":"w1","hook_event_name":"SessionStart","transcript_path":"C:\\t\\w.jsonl","cwd":"C:\\work\\wt"}' | Out-Null
Check 'WT_SESSION records Windows Terminal' (Field w1 terminal).kind 'wt'
Check '...with the session as its handle' (Field w1 terminal).handle '9fe93318-97be-4312-aa76-aebcb40de3ea'
$env:TERM_PROGRAM = 'vscode'
Emit '{"session_id":"w2","hook_event_name":"SessionStart","transcript_path":"C:\\t\\w.jsonl","cwd":"C:\\work\\code"}' | Out-Null
Check '...but not under a terminal that names itself' ([bool](Field w2 terminal)) 'False'
foreach ($k in $saved.Keys) {
  if ($saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
}
# The jump to a Windows Terminal tab goes through the session's pid: no pid, no jump offered.
# (A row with a pid needs a live Claude Code behind it, which CI doesn't have.)
$doc = Get-Content (Join-Path $home_ 'sessions\w1.json') -Raw | ConvertFrom-Json
$doc.sessionId = 'w4'
$doc.PSObject.Properties.Remove('pid')
[IO.File]::WriteAllText((Join-Path $home_ 'sessions\w4.json'), ($doc | ConvertTo-Json -Depth 10 -Compress))
$w = Start-Process -FilePath $Emit -ArgumentList '--watch' -RedirectStandardOutput $wout -NoNewWindow -PassThru
Start-Sleep -Seconds 3
Stop-Process -Id $w.Id -Force
$row = @((Get-Content $wout -TotalCount 1 | ConvertFrom-Json).sessions) | Where-Object { $_.sessionId -eq 'w4' }
Check '--watch lists a Windows Terminal session without a pid' ([bool]$row) 'True'
Check '...but offers no jump to it' ([bool]$row.termKind) 'False'
function Jump($session) {
  $err = Join-Path $home_ 'jump.err'
  return (Start-Process -FilePath $Emit -ArgumentList '--jump', $session -RedirectStandardError $err -NoNewWindow -PassThru -Wait).ExitCode
}
Check '--jump refuses a session id with a path in it' (Jump 'w1\..\x') 1
Check '--jump fails cleanly for an unknown session' (Jump 'nosuch') 1

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

# The task board's store and reading area (pet-emit --board, PetBoard): one JSON request on stdin.
function Board($json) {
  $in = Join-Path $home_ 'board-in.json'
  $out = Join-Path $home_ 'board-out.json'
  [IO.File]::WriteAllText($in, $json)
  Start-Process -FilePath $Emit -ArgumentList '--board' -RedirectStandardInput $in -RedirectStandardOutput $out -NoNewWindow -Wait | Out-Null
  return (Get-Content $out -Raw | ConvertFrom-Json)
}
Check '--board store starts empty' (@((Board '{"op":"store"}').result.phrases).Count) 0
Board '{"op":"phrases","action":"add","text":"looks good"}' | Out-Null
Check '--board phrases: one added' ((Board '{"op":"phrases","action":"add","text":"Looks good."}').result.phrases -join ',') 'looks good'
Board '{"op":"board-prefs","prefs":{"hq-launch":"wt","other":"x"}}' | Out-Null
$st = (Board '{"op":"store"}').result
Check '...prefs keep only the board''s keys' (($st.prefs.PSObject.Properties.Name) -join ',') 'hq-launch'
$doc = Join-Path $home_ 'note.md'
[IO.File]::WriteAllText($doc, '# hi')
$req = @{ op = 'read-doc'; path = 'note.md:3'; cwd = $home_ } | ConvertTo-Json -Compress
Check '--board read-doc: a relative path under a C:\ folder' (Board $req).result.text '# hi'
Check '--board: an unknown op is an error' ([bool](Board '{"op":"nope"}').error) 'True'

# Prompts held open: a session waiting on a question, held by a live process (this one).
function HeldSession($sid, $ask, $kind, $holder) {
  $until = [DateTime]::UtcNow.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $s = @{ sessionId = $sid; project = 'p'; cwd = 'C:\p'; state = 'waiting'; since = $now; updatedAt = $now;
    waitingOn = 'x'; detail = ''; tool = 'AskUserQuestion'; askId = $ask; askKind = $kind; askHeldBy = $holder;
    askHeldUntil = $until; questions = @(@{ question = 'Which?'; options = @(@{ label = 'A' }) }) }
  New-Item -ItemType Directory -Force (Join-Path $home_ 'sessions') | Out-Null
  [IO.File]::WriteAllText((Join-Path $home_ "sessions\$sid.json"), ($s | ConvertTo-Json -Depth 6 -Compress))
}
HeldSession 'q1' 'ask-q' 'question' $PID
$p = (Board '{"op":"prompt","session":"q1"}').result
Check '--board prompt: the held question' "$($p.kind) $($p.ask) $($p.questions[0].question)" 'question ask-q Which?'
Board '{"op":"answer-question","session":"q1","ask":"ask-q","answers":{"Which?":"A"}}' | Out-Null
$d = Get-Content (Join-Path $home_ 'decisions\q1.json') -Raw | ConvertFrom-Json
Check '...answer-question writes the pick for the hold' "$($d.askId) $($d.behavior) $($d.answers.'Which?')" 'ask-q allow A'
Check '...an answer to another ask is refused' ([bool](Board '{"op":"answer-question","session":"q1","ask":"old","answers":{"Which?":"A"}}').error) 'True'
Check '...Allow is not a question''s answer' ([bool](Board '{"op":"decide","session":"q1","ask":"ask-q","behavior":"allow"}').error) 'True'
HeldSession 'p1' 'ask-p' '' $PID
Board '{"op":"decide","session":"p1","ask":"ask-p","behavior":"deny"}' | Out-Null
$d = Get-Content (Join-Path $home_ 'decisions\p1.json') -Raw | ConvertFrom-Json
Check '--board decide: a permission prompt' "$($d.askId) $($d.behavior)" 'ask-p deny'
HeldSession 'g1' 'ask-g' 'question' 999999
Check '...nothing holds it any more: refused' ([bool](Board '{"op":"prompt","session":"g1"}').error) 'True'
# Typing into a terminal (PetControl): refused without a running process recorded for it.
HeldSession 'pl1' 'ask-pl' 'plan' $PID
Check '--board plan-approve: no terminal recorded, refused' ([bool](Board '{"op":"plan-approve","session":"pl1","ask":"ask-pl"}').error) 'True'
Check '...another ask: refused' ([bool](Board '{"op":"plan-approve","session":"pl1","ask":"old"}').error) 'True'
Check '--board send: no terminal recorded, refused' ([bool](Board '{"op":"send","session":"pl1","text":"hi"}').error) 'True'
Check '--board send: /model alone is refused' ([bool](Board '{"op":"send","session":"pl1","text":"/model"}').error) 'True'
Check '--board interrupt: a background session has no terminal' ([bool](Board '{"op":"interrupt","session":"pl1","bg":"abcdef12"}').error) 'True'
Check '--board stop-session: not a session id' ([bool](Board '{"op":"stop-session","session":"pl1"}').error) 'True'

Remove-Item $home_ -Recurse -Force -ErrorAction SilentlyContinue
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
