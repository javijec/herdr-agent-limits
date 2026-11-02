#!/bin/sh
# Prints the agents' usage limits as JSON for main.js:
# [{"agent", "name", "updated_at", "unlimited"?, "windows": [{"label", "minutes", "pct", "resets_at"}]}]
# Plans differ: some have no 5-hour window, some only a weekly or monthly one, some none
# ("unlimited": the server answered with no limits). Only windows that exist are listed.
# Local sources: Claude's rate_limits cached by statusline.sh beside this file (optional, set as
# Claude Code's statusLine), and the newest token_count rate_limits in ~/.codex/sessions.
# --live first asks the servers (Claude's OAuth usage API, Codex's app-server) and caches
# the answers; failures go to stderr and the local data is printed anyway. Accounts without a
# subscription sign-in (API keys) are skipped quietly.

PATH="$PATH:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-limits"
CLAUDE_CACHE="$CACHE_DIR/claude.json"
CLAUDE_SERVER_CACHE="$CACHE_DIR/claude-server.json"
CLAUDE_WAIT="$CACHE_DIR/claude-wait-until"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_CACHE="$CACHE_DIR/codex.json"

# Shared by every jq program below: a window's label from its length in minutes.
LABEL='def win_label: if . < 1440 then "\(. / 60 | floor)h" else "\(. / 1440 | floor)d" end;'

# Writes stdin to $1 only if it is a non-empty JSON value, replacing the file atomically.
save() {
  tmp="$1.$$"
  if jq -e . >"$tmp" 2>/dev/null; then mv -f "$tmp" "$1"; else rm -f "$tmp"; return 1; fi
}

fetch_claude() {
  # Claude Code keeps its sign-in in the macOS Keychain, elsewhere in .credentials.json.
  creds=""
  if command -v security >/dev/null 2>&1; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  fi
  [ -n "$creds" ] || creds=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -n "$token" ] || return 0
  # After a 429 the usage API is left alone until the time it asked for.
  now=$(date +%s)
  until=$(cat "$CLAUDE_WAIT" 2>/dev/null)
  case "$until" in '' | *[!0-9]*) until=0 ;; esac
  if [ "$until" -gt "$now" ]; then
    echo "Claude: the server asked to wait; next check in $(((until - now + 59) / 60)) min" >&2
    return
  fi
  # The token goes through stdin so it never shows in the process list.
  resp=$(printf 'Authorization: Bearer %s\n' "$token" |
    curl -sS -m 10 -H @- -H "anthropic-beta: oauth-2025-04-20" -w '\n%{http_code} %header{retry-after}' \
      https://api.anthropic.com/api/oauth/usage 2>&1)
  status=$(printf '%s' "$resp" | tail -n 1)
  code=${status%% *}
  retry=${status#* }
  body=$(printf '%s' "$resp" | sed '$d')
  case "$code" in
    200) rm -f "$CLAUDE_WAIT" ;;
    429)
      # Retry-After in seconds; a date, or a curl too old to read headers, gets 10 minutes.
      case "$retry" in '' | *[!0-9]*) retry=600 ;; esac
      echo $((now + retry)) >"$CLAUDE_WAIT"
      echo "Claude: too many requests; next check in $(((retry + 59) / 60)) min" >&2
      return
      ;;
    401) echo "Claude: sign-in expired; open Claude Code to renew it" >&2; return ;;
    000) echo "Claude: could not reach the server" >&2; return ;;
    *) echo "Claude: server answered HTTP $code" >&2; return ;;
  esac
  printf '%s' "$body" | jq -c --argjson now "$(date +%s)" '
    def epoch: if . == null then null
      else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // null end;
    def win: if . == null then null else {used_percentage: .utilization, resets_at: (.resets_at | epoch)} end;
    ({five_hour: (.five_hour | win), seven_day: (.seven_day | win)} | with_entries(select(.value != null))) as $rl
    | {updated_at: $now, rate_limits: $rl, no_limits: ($rl == {})}' |
    save "$CLAUDE_SERVER_CACHE" || echo "Claude: unexpected answer from the server" >&2
}

fetch_codex() {
  command -v codex >/dev/null 2>&1 || return 0
  [ "$(jq -r '.auth_mode // empty' "$CODEX_HOME/auth.json" 2>/dev/null)" = "chatgpt" ] || return 0
  dir=$(mktemp -d)
  mkfifo "$dir/in"
  codex app-server <"$dir/in" >"$dir/out" 2>/dev/null &
  pid=$!
  exec 3>"$dir/in"
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"herdr_agent_limits","title":"Herdr agent limits","version":"0.1.0"}}}' \
    '{"jsonrpc":"2.0","method":"initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}' >&3
  i=0
  while [ "$i" -lt 75 ] && ! grep -q '"id":2' "$dir/out" && kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
  done
  exec 3>&-
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if ! grep -q '"id":2' "$dir/out"; then
    echo "Codex: no answer from codex app-server" >&2
  else
    err=$(jq -r 'select(.id == 2) | .error.message // empty' "$dir/out" 2>/dev/null)
    if [ -n "$err" ]; then
      echo "Codex: $err" >&2
    else
      jq -c --argjson now "$(date +%s)" "$LABEL"'
        def win: {label: (.windowDurationMins | win_label), minutes: .windowDurationMins,
                  pct: .usedPercent, resets_at: .resetsAt};
        select(.id == 2) | .result.rateLimits
        | [(.primary, .secondary) | select(. != null) | win] as $w
        | {agent: "codex", name: "Codex", updated_at: $now, unlimited: ($w == []), windows: $w}' "$dir/out" |
        save "$CODEX_CACHE" || echo "Codex: unexpected answer from codex app-server" >&2
    fi
  fi
  rm -rf "$dir"
}

# The statusline's numbers and the server's answer: whichever is newer. spend_limit comes
# from the statusline behind a Claude gateway (daily, weekly or monthly budgets).
claude_limits() {
  for f in "$CLAUDE_CACHE" "$CLAUDE_SERVER_CACHE"; do [ -f "$f" ] && cat "$f"; done |
    jq -sc "$LABEL"'
      def win($m): {label: ($m | win_label), minutes: $m, pct: .used_percentage, resets_at};
      max_by(.updated_at // 0) // empty
      | [(.rate_limits.five_hour // empty | win(300)),
         (.rate_limits.seven_day // empty | win(10080)),
         (.rate_limits.spend_limit // empty
          | win({daily: 1440, weekly: 10080, monthly: 43200}[.period // "monthly"] // 43200))] as $w
      | {agent: "claude", name: "Claude", updated_at, unlimited: (.no_limits == true and $w == []), windows: $w}' 2>/dev/null
}

# Resumed Codex sessions keep appending to their original dated file, so order by mtime.
codex_from_logs() {
  [ -d "$CODEX_HOME/sessions" ] || return 0
  find "$CODEX_HOME/sessions" -name '*.jsonl' -mtime -8 -exec ls -t {} + 2>/dev/null | head -10 |
    while IFS= read -r f; do
      grep -h '"token_count"' "$f" | grep -E '"(primary|secondary)":\{' | tail -1
    done |
    jq -Rnc "$LABEL"'
      def win: {label: (.window_minutes | win_label), minutes: .window_minutes, pct: .used_percent, resets_at};
      [inputs | fromjson? | select(.payload.type? == "token_count")
        | select(.payload.rate_limits.primary != null or .payload.rate_limits.secondary != null)]
      | max_by(.timestamp) // empty
      | {agent: "codex", name: "Codex",
         updated_at: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // null),
         windows: [(.payload.rate_limits.primary, .payload.rate_limits.secondary) | select(. != null) | win]}'
}

# The server's answer and the session logs: whichever is newer.
codex_limits() {
  { codex_from_logs; [ -f "$CODEX_CACHE" ] && cat "$CODEX_CACHE"; } |
    jq -sc 'max_by(.updated_at // 0) // empty'
}

if [ "$1" = "--live" ]; then
  mkdir -p "$CACHE_DIR"
  fetch_claude &
  fetch_codex &
  wait
fi

{ claude_limits; codex_limits; } | jq -sc 'map(select((.windows | length > 0) or .unlimited == true))'
