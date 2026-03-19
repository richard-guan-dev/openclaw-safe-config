#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <candidate-config.json>" >&2
  exit 2
fi

CANDIDATE="$1"

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

node - "$CFG" "$CANDIDATE" <<'NODE'
const fs = require('fs');
const JSON5 = require('json5');

const [cfgPath, candidatePath] = process.argv.slice(2);

function readJson5(path) {
  return JSON5.parse(fs.readFileSync(path, 'utf8'));
}

function diffPaths(a, b, base = '') {
  if (Object.is(a, b)) return [];

  const aIsObj = a && typeof a === 'object';
  const bIsObj = b && typeof b === 'object';
  const aIsArray = Array.isArray(a);
  const bIsArray = Array.isArray(b);

  if (aIsObj && bIsObj && !aIsArray && !bIsArray) {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    const out = [];
    for (const key of [...keys].sort()) {
      const path = base ? `${base}.${key}` : key;
      out.push(...diffPaths(a[key], b[key], path));
    }
    return out;
  }

  if (aIsArray && bIsArray) {
    if (JSON.stringify(a) === JSON.stringify(b)) return [];
    return [base || '<root>'];
  }

  return [base || '<root>'];
}

const currentCfg = readJson5(cfgPath);
const candidateCfg = readJson5(candidatePath);
const changedPaths = [...new Set(diffPaths(currentCfg, candidateCfg))];

const highRiskPrefixes = [
  'models.providers.',
  'gateway.auth.',
  'plugins.entries.',
  'bindings',
  'agents.list',
];
const mediumRiskPrefixes = [
  'channels.',
  'agents.defaults.',
  'models.aliases.',
  'tailscale.',
];
const restartLikelyPrefixes = [
  'models.providers.',
  'gateway.auth.',
  'plugins.entries.',
  'tailscale.mode',
  'agents.list',
];

function matches(path, prefixes) {
  return prefixes.some((prefix) => path === prefix || path.startsWith(prefix));
}

let riskLevel = 'low';
if (changedPaths.some((p) => matches(p, highRiskPrefixes))) {
  riskLevel = 'high';
} else if (changedPaths.some((p) => matches(p, mediumRiskPrefixes))) {
  riskLevel = 'medium';
}

const restartLikely = changedPaths.some((p) => matches(p, restartLikelyPrefixes));

const summary = {
  configPath: cfgPath,
  candidatePath,
  changeCount: changedPaths.length,
  riskLevel,
  restartLikely,
  changedPaths,
};

console.log('PREFLIGHT');
console.log(`config_path=${summary.configPath}`);
console.log(`candidate_path=${summary.candidatePath}`);
console.log(`change_count=${summary.changeCount}`);
console.log(`risk_level=${summary.riskLevel}`);
console.log(`restart_likely=${summary.restartLikely ? 'yes' : 'no'}`);
console.log(`changed_paths_json=${JSON.stringify(summary.changedPaths)}`);
NODE
