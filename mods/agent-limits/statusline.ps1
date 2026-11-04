$ErrorActionPreference = 'SilentlyContinue'
$inputJson = [Console]::In.ReadToEnd()
$cache = Join-Path (if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }) 'agent-limits'
$file = Join-Path $cache 'claude.json'
try {
  $rl = ($inputJson | ConvertFrom-Json).rate_limits
  if ($rl) {
    $old = if (Test-Path $file) { (Get-Content $file -Raw | ConvertFrom-Json).rate_limits | ConvertTo-Json -Depth 20 -Compress } else { '' }
    $new = $rl | ConvertTo-Json -Depth 20 -Compress
    if ($new -ne $old) {
      New-Item -ItemType Directory -Force -Path $cache | Out-Null
      [pscustomobject]@{ updated_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); rate_limits=$rl } | ConvertTo-Json -Depth 20 -Compress | Set-Content -Path $file -Encoding utf8
    }
  }
} catch {}
