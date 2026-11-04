param([switch]$Live)
$ErrorActionPreference = 'Stop'
$homeDir = $HOME
$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $homeDir '.cache' }
$cache = Join-Path $cache 'agent-limits'
$claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $homeDir '.claude' }
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $homeDir '.codex' }
function Read-JsonFile([string]$Path) {
  if (Test-Path -LiteralPath $Path) { try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch {} }
  return $null
}
function Convert-Window($Window, [int]$Minutes) {
  if ($null -eq $Window) { return $null }
  $label = if ($Minutes -lt 1440) { "$( [math]::Floor($Minutes / 60) )h" } else { "$( [math]::Floor($Minutes / 1440) )d" }
  $reset = $null
  if ($Window.resets_at) {
    try { $reset = [DateTimeOffset]::Parse([string]$Window.resets_at).ToUnixTimeSeconds() } catch {}
  }
  return [pscustomobject]@{ label = $label; minutes = $Minutes; pct = [double]$Window.used_percentage; resets_at = $reset }
}
function Save-Json($Path, $Value) {
  New-Item -ItemType Directory -Force -Path $cache | Out-Null
  $tmp = "$Path.$PID.tmp"
  $Value | ConvertTo-Json -Depth 20 -Compress | Set-Content -LiteralPath $tmp -Encoding utf8
  Move-Item -Force -LiteralPath $tmp -Destination $Path
}
if ($Live) {
  New-Item -ItemType Directory -Force -Path $cache | Out-Null
  $cred = Read-JsonFile (Join-Path $claudeHome '.credentials.json')
  $token = $cred.claudeAiOauth.accessToken
  if ($token) {
    try {
      $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers @{ Authorization = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' } -TimeoutSec 10
      $limits = [ordered]@{}
      if ($resp.five_hour) { $limits.five_hour = $resp.five_hour }
      if ($resp.seven_day) { $limits.seven_day = $resp.seven_day }
      $obj = [pscustomobject]@{ updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); rate_limits = $limits; no_limits = ($limits.Count -eq 0) }
      Save-Json (Join-Path $cache 'claude-server.json') $obj
    } catch { [Console]::Error.WriteLine("Claude: $($_.Exception.Message)") }
  }
  $codex = Get-Command codex.cmd,codex.exe,codex -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'chrome-native-host|core-command-runner' } | Sort-Object { if ([IO.Path]::GetExtension($_.Source) -in @('.cmd', '.exe')) { 0 } else { 1 } } | Select-Object -First 1
  if (-not $codex) {
    $config = Join-Path $codexHome 'config.toml'
    if (Test-Path $config) {
      $match = Select-String -Path $config -Pattern '^CODEX_CLI_PATH\s*=\s*["'']([^"'']+)["'']' | Select-Object -Last 1
      if ($match) { $candidate = $match.Matches[0].Groups[1].Value; if (Test-Path -LiteralPath $candidate) { $codex = [pscustomobject]@{ Source = $candidate } } }
    }
  }
  $auth = Read-JsonFile (Join-Path $codexHome 'auth.json')
  if ($codex -and $auth.auth_mode -eq 'chatgpt') {
    try {
      $psi = [Diagnostics.ProcessStartInfo]::new()
      $codexPath = [string]$codex.Source
      $extension = [IO.Path]::GetExtension($codexPath).ToLowerInvariant()
      if ($extension -in @('.cmd', '.bat')) {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /s /c ""' + $codexPath + '" app-server"'
      } elseif ($extension -eq '.ps1') {
        $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $codexPath + '" app-server'
      } else {
        $psi.FileName = $codexPath
        $psi.Arguments = 'app-server'
      }
      $psi.UseShellExecute = $false
      $psi.RedirectStandardInput = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $proc = [Diagnostics.Process]::new()
      $proc.StartInfo = $psi
      [void]$proc.Start()
      $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"herdr_agent_limits","title":"Herdr agent limits","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}')
      $initResponse = $null
      $deadline = [DateTime]::UtcNow.AddSeconds(12)
      $readTask = $proc.StandardOutput.ReadLineAsync()
      while ([DateTime]::UtcNow -lt $deadline -and -not $initResponse) {
        if (-not $readTask.Wait([timespan]::FromMilliseconds(500))) { continue }
        $line = $readTask.Result
        if ($null -eq $line) { break }
        try { $message = $line | ConvertFrom-Json; if ($message.id -eq 1) { $initResponse = $message } } catch {}
        if (-not $initResponse) { $readTask = $proc.StandardOutput.ReadLineAsync() }
      }
      if (-not $initResponse) { $proc.Kill(); throw 'Codex app-server did not complete initialize' }
      if ($initResponse.error) { $proc.Kill(); throw "initialize failed: $($initResponse.error.message)" }
      $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialized","params":{}}')
      $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}')
      $response = $null
      $deadline = [DateTime]::UtcNow.AddSeconds(12)
      $readTask = $proc.StandardOutput.ReadLineAsync()
      while ([DateTime]::UtcNow -lt $deadline -and -not $response) {
        if (-not $readTask.Wait([timespan]::FromMilliseconds(500))) { continue }
        $line = $readTask.Result
        if ($null -eq $line) { break }
        try { $message = $line | ConvertFrom-Json; if ($message.id -eq 2) { $response = $message } } catch {}
        if (-not $response) { $readTask = $proc.StandardOutput.ReadLineAsync() }
      }
      $proc.StandardInput.Close()
      if (-not $proc.HasExited) { $proc.Kill() }
      $proc.WaitForExit()
      if (-not $response) { throw 'Codex app-server returned no rate-limit response' }
      if ($response.result.rateLimits) {
        $wins = @()
        foreach ($w in @($response.result.rateLimits.primary, $response.result.rateLimits.secondary)) {
          if ($null -ne $w) { $wins += [pscustomobject]@{ label = if ($w.windowDurationMins -lt 1440) { "$([math]::Floor($w.windowDurationMins / 60))h" } else { "$([math]::Floor($w.windowDurationMins / 1440))d" }; minutes = $w.windowDurationMins; pct = $w.usedPercent; resets_at = $w.resetsAt } }
        }
        Save-Json (Join-Path $cache 'codex.json') ([pscustomobject]@{ agent='codex'; name='Codex'; updated_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); unlimited=($wins.Count -eq 0); windows=$wins })
      } elseif ($response.result.account) {
        Save-Json (Join-Path $cache 'codex.json') ([pscustomobject]@{ agent='codex'; name='Codex'; updated_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); unlimited=$true; windows=@() })
      }
    } catch { [Console]::Error.WriteLine("Codex: $($_.Exception.Message)") }
  }
}
$claudeCandidates = @((Read-JsonFile (Join-Path $cache 'claude.json')), (Read-JsonFile (Join-Path $cache 'claude-server.json'))) | Where-Object { $_ }
$claude = $claudeCandidates | Sort-Object updated_at -Descending | Select-Object -First 1
$out = @()
if ($claude) {
  $wins = @()
  $rl = $claude.rate_limits
  if ($rl.five_hour) { $wins += (Convert-Window $rl.five_hour 300) }
  if ($rl.seven_day) { $wins += (Convert-Window $rl.seven_day 10080) }
  if ($rl.spend_limit) {
    $mins = switch ([string]$rl.spend_limit.period) { daily {1440} weekly {10080} monthly {43200} default {43200} }
    $wins += (Convert-Window $rl.spend_limit $mins)
  }
  if ($wins.Count -gt 0 -or $claude.no_limits) { $out += [pscustomobject]@{ agent='claude'; name='Claude'; updated_at=$claude.updated_at; unlimited=([bool]$claude.no_limits -and $wins.Count -eq 0); windows=$wins } }
}
$logs = Join-Path $codexHome 'sessions'
$recent = Get-ChildItem -LiteralPath $logs -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt [DateTime]::Now.AddDays(-8) } | Sort-Object LastWriteTime -Descending | Select-Object -First 10
$events = foreach ($file in $recent) {
  foreach ($line in [IO.File]::ReadLines($file.FullName)) {
    if ($line -match '"token_count"' -and $line -match '"rate_limits"') {
      try { $e = $line | ConvertFrom-Json; if ($e.payload.rate_limits.primary -or $e.payload.rate_limits.secondary) { $e } } catch {}
    }
  }
}
$localCodex = $events | Sort-Object timestamp -Descending | Select-Object -First 1
$codexCache = Read-JsonFile (Join-Path $cache 'codex.json')
$codexData = @($localCodex, $codexCache) | Where-Object { $_ } | Sort-Object { if ($_.updated_at) { $_.updated_at } else { try { [DateTimeOffset]::Parse($_.timestamp).ToUnixTimeSeconds() } catch { 0 } } } -Descending | Select-Object -First 1
if ($codexData) {
  if ($codexData.agent -eq 'codex') { $out += $codexData }
  else {
    $wins = @()
    foreach ($w in @($codexData.payload.rate_limits.primary, $codexData.payload.rate_limits.secondary)) {
      if ($null -ne $w) { $mins=[int]$w.window_minutes; $wins += [pscustomobject]@{ label=if ($mins -lt 1440) { "$([math]::Floor($mins/60))h" } else { "$([math]::Floor($mins/1440))d" }; minutes=$mins; pct=$w.used_percent; resets_at=$(if ($w.resets_at) { try { [DateTimeOffset]::Parse([string]$w.resets_at).ToUnixTimeSeconds() } catch {$null} } else {$null}) } }
    }
    $stamp = try { [DateTimeOffset]::Parse([string]$codexData.timestamp).ToUnixTimeSeconds() } catch { 0 }
    if ($wins.Count) { $out += [pscustomobject]@{ agent='codex'; name='Codex'; updated_at=$stamp; windows=$wins } }
  }
}
ConvertTo-Json -InputObject @($out) -Depth 20 -Compress
