#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <candidate-config.json> [timeout-seconds]" >&2
  exit 2
fi

CANDIDATE="$1"
TIMEOUT_SECONDS="${2:-90}"
CFG="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"

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
LOG_BASE="/tmp/openclaw-safe-config-${TS}"
VALIDATE_LOG="${LOG_BASE}.validate.log"
RESTART_LOG="${LOG_BASE}.restart.log"
HEALTH_LOG="${LOG_BASE}.health.log"
ROLLBACK_LOG="${LOG_BASE}.rollback.log"
ROLLBACK_SH="${LOG_BASE}.rollback.sh"
CHECKS=$(( (TIMEOUT_SECONDS + 4) / 5 ))

python3 -m json.tool "$CANDIDATE" >/dev/null
cp -a "$CFG" "$BACKUP"
cp -a "$CANDIDATE" "$TMP_APPLY"
mv "$TMP_APPLY" "$CFG"

if ! openclaw config validate >"$VALIDATE_LOG" 2>&1; then
  cp -a "$BACKUP" "$CFG"
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
    cat <<OUT
SUCCESS
backup=$BACKUP
guard_pid=$GUARD_PID
validate_log=$VALIDATE_LOG
restart_log=$RESTART_LOG
health_log=$HEALTH_LOG
rollback_log=$ROLLBACK_LOG
OUT
    exit 0
  fi
done

echo "Gateway health timed out; rollback guard remains armed. Check: $ROLLBACK_LOG" >&2
exit 1
