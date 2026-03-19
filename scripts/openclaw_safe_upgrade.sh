#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: openclaw_safe_upgrade.sh [openclaw-update-args...]

Examples:
  openclaw_safe_upgrade.sh --dry-run
  openclaw_safe_upgrade.sh --tag beta
  openclaw_safe_upgrade.sh --channel stable --yes

Environment:
  OPENCLAW_UPGRADE_TIMEOUT_SECONDS   Health-check timeout after restart (default: 120)
  OPENCLAW_CONFIG_PATH               Override active config path (default: ~/.openclaw/openclaw.json)
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

REQUESTED_DRYRUN=0
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    REQUESTED_DRYRUN=1
    break
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_SCRIPT="${SCRIPT_DIR}/openclaw_upgrade_smoke_test.sh"
CFG="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
TIMEOUT_SECONDS="${OPENCLAW_UPGRADE_TIMEOUT_SECONDS:-120}"
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -lt 15 ]]; then
  echo "OPENCLAW_UPGRADE_TIMEOUT_SECONDS must be an integer >= 15" >&2
  exit 2
fi
if [[ ! -f "$CFG" ]]; then
  echo "Active config not found: $CFG" >&2
  exit 2
fi
if [[ ! -x "$SMOKE_SCRIPT" ]]; then
  echo "Smoke test script missing or not executable: $SMOKE_SCRIPT" >&2
  exit 2
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
BASE="/tmp/openclaw-safe-upgrade-${TS}"
STATUS_JSON="${BASE}.status.json"
MANIFEST_JSON="${BASE}.manifest.json"
DRYRUN_LOG="${BASE}.dryrun.log"
UPDATE_LOG="${BASE}.update.log"
RESTART_LOG="${BASE}.restart.log"
HEALTH_LOG="${BASE}.health.log"
ROLLBACK_LOG="${BASE}.rollback.log"
BACKUP_DIR="${BASE}.backupdir"
CFG_BACKUP="${CFG}.pre-upgrade.${TS}"
ROLLBACK_SH="${BASE}.rollback.sh"
PRE_SMOKE_LOG="${BASE}.pre-smoke.log"
POST_SMOKE_LOG="${BASE}.post-smoke.log"
CHECKS=$(( (TIMEOUT_SECONDS + 4) / 5 ))
PREV_VERSION="$(openclaw -V | tail -n1)"

mkdir -p "$BACKUP_DIR"
openclaw update status --json >"$STATUS_JSON"
INSTALL_KIND="$(python3 - "$STATUS_JSON" <<'PY'
import json, sys
text = open(sys.argv[1], 'r', encoding='utf-8').read()
start = text.find('{')
if start < 0:
    raise SystemExit('No JSON payload found in update status output')
data = json.loads(text[start:])
print(data.get('update', {}).get('installKind', 'unknown'))
PY
)"
cp -a "$CFG" "$CFG_BACKUP"
openclaw backup create --only-config --verify --output "$BACKUP_DIR" >"${BASE}.backup.log" 2>&1 || true
if ! "$SMOKE_SCRIPT" >"$PRE_SMOKE_LOG" 2>&1; then
  echo "Preflight smoke test failed. See: $PRE_SMOKE_LOG" >&2
  exit 1
fi
python3 - <<PY >"$MANIFEST_JSON"
import json
manifest = {
  'ts': '$TS',
  'prevVersion': '$PREV_VERSION',
  'installKind': '$INSTALL_KIND',
  'configPath': '$CFG',
  'configBackup': '$CFG_BACKUP',
  'statusJson': '$STATUS_JSON',
  'preSmokeLog': '$PRE_SMOKE_LOG',
  'postSmokeLog': '$POST_SMOKE_LOG',
}
print(json.dumps(manifest, indent=2))
PY

if ! openclaw update --dry-run "$@" >"$DRYRUN_LOG" 2>&1; then
  echo "openclaw update --dry-run failed. See: $DRYRUN_LOG" >&2
  exit 1
fi

if [[ "$REQUESTED_DRYRUN" == "1" ]]; then
  cat <<OUT
DRY_RUN_OK
prev_version=$PREV_VERSION
install_kind=$INSTALL_KIND
config_backup=$CFG_BACKUP
status_json=$STATUS_JSON
manifest_json=$MANIFEST_JSON
pre_smoke_log=$PRE_SMOKE_LOG
dryrun_log=$DRYRUN_LOG
OUT
  exit 0
fi

if ! openclaw update --no-restart "$@" >"$UPDATE_LOG" 2>&1; then
  echo "openclaw update failed before restart. See: $UPDATE_LOG" >&2
  exit 1
fi

cat >"$ROLLBACK_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CFG='$CFG'
CFG_BACKUP='$CFG_BACKUP'
PREV_VERSION='$PREV_VERSION'
INSTALL_KIND='$INSTALL_KIND'
ROLLBACK_LOG='$ROLLBACK_LOG'
CHECKS='$CHECKS'
SMOKE_SCRIPT='$SMOKE_SCRIPT'
for i in \$(seq 1 "\$CHECKS"); do
  sleep 5
  if openclaw gateway health >>"\$ROLLBACK_LOG" 2>&1 && "\$SMOKE_SCRIPT" >>"\$ROLLBACK_LOG" 2>&1; then
    echo "[\$(date -u +%FT%TZ)] healthy + smoke test passed; rollback guard exiting" >>"\$ROLLBACK_LOG"
    exit 0
  fi
done

echo "[\$(date -u +%FT%TZ)] post-upgrade health/smoke timeout; starting rollback" >>"\$ROLLBACK_LOG"
if [[ "\$INSTALL_KIND" == "package" ]]; then
  openclaw update --tag "\$PREV_VERSION" --yes --no-restart >>"\$ROLLBACK_LOG" 2>&1 || true
else
  echo "[\$(date -u +%FT%TZ)] installKind=\$INSTALL_KIND requires manual binary rollback" >>"\$ROLLBACK_LOG"
fi
cp -a "\$CFG_BACKUP" "\$CFG"
openclaw config validate >>"\$ROLLBACK_LOG" 2>&1 || true
openclaw gateway restart >>"\$ROLLBACK_LOG" 2>&1 || true
EOF
chmod +x "$ROLLBACK_SH"
nohup bash "$ROLLBACK_SH" >/dev/null 2>&1 &
GUARD_PID=$!

openclaw gateway restart >"$RESTART_LOG" 2>&1 || true

for i in $(seq 1 "$CHECKS"); do
  sleep 5
  if openclaw gateway health >"$HEALTH_LOG" 2>&1 && "$SMOKE_SCRIPT" >"$POST_SMOKE_LOG" 2>&1; then
    cat <<OUT
SUCCESS
prev_version=$PREV_VERSION
install_kind=$INSTALL_KIND
config_backup=$CFG_BACKUP
status_json=$STATUS_JSON
manifest_json=$MANIFEST_JSON
pre_smoke_log=$PRE_SMOKE_LOG
post_smoke_log=$POST_SMOKE_LOG
dryrun_log=$DRYRUN_LOG
update_log=$UPDATE_LOG
restart_log=$RESTART_LOG
health_log=$HEALTH_LOG
rollback_log=$ROLLBACK_LOG
guard_pid=$GUARD_PID
OUT
    exit 0
  fi
done

echo "Post-upgrade health/smoke timed out; rollback guard remains armed. Check: $ROLLBACK_LOG" >&2
exit 1
