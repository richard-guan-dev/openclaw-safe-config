#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <candidate-config.json> [timeout-seconds]" >&2
  exit 2
fi

CANDIDATE="$1"
TIMEOUT_SECONDS="${2:-90}"

resolve_cfg_path() {
  if [[ -n "${OPENCLAW_CONFIG_PATH:-}" ]]; then
    printf '%s\n' "$OPENCLAW_CONFIG_PATH"
    return 0
  fi

  if command -v openclaw >/dev/null 2>&1; then
    local cli_cfg
    cli_cfg="$(openclaw config file 2>/dev/null | awk 'NF { print; exit }')"
    if [[ -n "$cli_cfg" ]]; then
      printf '%s\n' "$cli_cfg"
      return 0
    fi
  fi

  printf '%s\n' "$HOME/.openclaw/openclaw.json"
}

CFG="$(resolve_cfg_path)"

if [[ ! -f "$CANDIDATE" ]]; then
  echo "Candidate config not found: $CANDIDATE" >&2
  exit 2
fi
if [[ ! -f "$CFG" ]]; then
  echo "Active config not found: $CFG" >&2
  exit 2
fi
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -lt 15 ]]; then
  echo "Timeout must be an integer >= 15 seconds" >&2
  exit 2
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${CFG}.bak.${TS}"
TMP_APPLY="${CFG}.tmpapply.${TS}"
SAFE_CONFIG_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
SAFE_CONFIG_LOG_DIR="${OPENCLAW_SAFE_CONFIG_LOG_DIR:-$SAFE_CONFIG_STATE_DIR/logs/safe-config}"
LOG_BASE="${SAFE_CONFIG_LOG_DIR}/openclaw-safe-config-${TS}"
VALIDATE_LOG="${LOG_BASE}.validate.log"
RESTART_LOG="${LOG_BASE}.restart.log"
HEALTH_LOG="${LOG_BASE}.health.log"
ROLLBACK_LOG="${LOG_BASE}.rollback.log"
ROLLBACK_SH="${LOG_BASE}.rollback.sh"
HISTORY_LOG="${OPENCLAW_SAFE_CONFIG_HISTORY:-$HOME/.openclaw/logs/config-history.jsonl}"
CHECKS=$(( (TIMEOUT_SECONDS + 4) / 5 ))

mkdir -p "$SAFE_CONFIG_LOG_DIR" "$(dirname "$HISTORY_LOG")"

write_history() {
  local status="$1"
  local note="${2:-}"
  python3 - "$HISTORY_LOG" "$status" "$note" "$CFG" "$CANDIDATE" "$BACKUP" "$VALIDATE_LOG" "$RESTART_LOG" "$HEALTH_LOG" "$ROLLBACK_LOG" "$ROLLBACK_SH" "$TIMEOUT_SECONDS" <<'PY'
import datetime
import json
import os
import sys

(
    history_log,
    status,
    note,
    cfg,
    candidate,
    backup,
    validate_log,
    restart_log,
    health_log,
    rollback_log,
    rollback_sh,
    timeout_seconds,
) = sys.argv[1:]

record = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "status": status,
    "note": note,
    "configPath": cfg,
    "candidatePath": candidate,
    "backupPath": backup,
    "validateLog": validate_log,
    "restartLog": restart_log,
    "healthLog": health_log,
    "rollbackLog": rollback_log,
    "rollbackScript": rollback_sh,
    "timeoutSeconds": int(timeout_seconds),
}

with open(history_log, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY
}

python3 -m json.tool "$CANDIDATE" >/dev/null
cp -a "$CFG" "$BACKUP"
cp -a "$CANDIDATE" "$TMP_APPLY"
mv "$TMP_APPLY" "$CFG"
chmod 600 "$CFG" 2>/dev/null || true

if ! openclaw config validate >"$VALIDATE_LOG" 2>&1; then
  cp -a "$BACKUP" "$CFG"
  write_history "validation_failed" "config validate failed; restored backup before restart"
  echo "Validation failed. Restored backup: $BACKUP" >&2
  sed -n '1,120p' "$VALIDATE_LOG" >&2 || true
  exit 1
fi

cat >"$ROLLBACK_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CFG='$CFG'
BACKUP='$BACKUP'
ROLLBACK_LOG='$ROLLBACK_LOG'
CHECKS='$CHECKS'
for i in \$(seq 1 "\$CHECKS"); do
  sleep 5
  if openclaw gateway health >>"\$ROLLBACK_LOG" 2>&1; then
    echo "[\$(date -u +%FT%TZ)] healthy; rollback guard exiting" >>"\$ROLLBACK_LOG"
    exit 0
  fi
done

echo "[\$(date -u +%FT%TZ)] health timeout; restoring backup \$BACKUP" >>"\$ROLLBACK_LOG"
cp -a "\$BACKUP" "\$CFG"
if openclaw config validate >>"\$ROLLBACK_LOG" 2>&1; then
  echo "[\$(date -u +%FT%TZ)] rollback config valid; restarting gateway" >>"\$ROLLBACK_LOG"
  openclaw gateway restart >>"\$ROLLBACK_LOG" 2>&1 || true
else
  echo "[\$(date -u +%FT%TZ)] rollback config invalid; manual intervention required" >>"\$ROLLBACK_LOG"
fi
EOF
chmod +x "$ROLLBACK_SH"
nohup bash "$ROLLBACK_SH" >/dev/null 2>&1 &
GUARD_PID=$!

if ! openclaw gateway restart >"$RESTART_LOG" 2>&1; then
  echo "Gateway restart command returned non-zero; rollback guard remains armed." >&2
fi

for i in $(seq 1 "$CHECKS"); do
  sleep 5
  if openclaw gateway health >"$HEALTH_LOG" 2>&1; then
    write_history "success" "gateway health passed after restart"
    cat <<OUT
SUCCESS
backup=$BACKUP
guard_pid=$GUARD_PID
validate_log=$VALIDATE_LOG
restart_log=$RESTART_LOG
health_log=$HEALTH_LOG
rollback_log=$ROLLBACK_LOG
history_log=$HISTORY_LOG
OUT
    exit 0
  fi
done

write_history "health_timeout" "gateway health timed out; rollback guard remains armed"
echo "Gateway health timed out; rollback guard remains armed. Check: $ROLLBACK_LOG" >&2
exit 1
