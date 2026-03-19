# openclaw-safe-config

Safely plan, validate, preflight, apply, and roll back OpenClaw `openclaw.json` changes and package-based OpenClaw core upgrades.

## Contents

- `SKILL.md` — skill instructions
- `scripts/openclaw_config_audit.py` — static audit for common config safety issues, with optional ignore/suppression rules
- `references/config-audit-policy.md` — suppression policy for accepted audit noise
- `references/config-audit-ignore.example.jsonc` — example ignore file for accepted noise
- `scripts/openclaw_safe_config_preflight.sh` — compare active vs candidate config and summarize changed paths, risk level, and restart likelihood
- `scripts/openclaw_safe_config_apply.sh` — safe config apply with backup, validate, health check, rollback guard, config-path auto-discovery, and JSONL history logging
- `scripts/openclaw_safe_upgrade.sh` — package-oriented safe OpenClaw upgrade workflow
- `scripts/openclaw_upgrade_smoke_test.sh` — minimal smoke test helper
- `references/` — rollback and upgrade notes

## Typical config workflow

```bash
scripts/openclaw_config_audit.py
scripts/openclaw_safe_config_preflight.sh /path/to/candidate-config.json
scripts/openclaw_safe_config_apply.sh /path/to/candidate-config.json 120
```

If the audit has known accepted noise, create a local ignore file next to the active config as `.openclaw-config-audit-ignore.json` (or `.jsonc`) and rerun the audit.

Use the audit step before risky edits (models, aliases, bindings, plugins, auth, or agent list changes).

## Config-path discovery order

`openclaw_safe_config_apply.sh` and `openclaw_safe_config_preflight.sh` resolve the active config path in this order:

1. `OPENCLAW_CONFIG_PATH`
2. `openclaw config file`
3. `~/.openclaw/openclaw.json`

## Audit checks

`openclaw_config_audit.py` currently reports:

- duplicate aliases
- unknown/broken model refs
- duplicate agent IDs
- duplicate provider-local model IDs
- inline secret candidates

It supports `--json` for machine-readable output.

## Ignore / suppression rules

The audit can suppress accepted findings without disabling the whole checker.

Supported approaches:

- auto-load `.openclaw-config-audit-ignore.json` or `.jsonc` from the active config directory
- `--ignore-file /path/to/file.json`
- ad-hoc CLI filters:
  - `--ignore-kind <kind>`
  - `--ignore-alias <alias>`
  - `--ignore-path-regex '<regex>'`

Ignore file format:

```json
{
  "ignore": [
    { "kind": "alias_target_unknown", "alias": "vertex-gemini-flash" },
    { "kind": "inline_secret_candidate", "pathRegex": "^channels\\.discord\\.token$" }
  ]
}
```

Rules are AND-matched by field, and `*Regex` keys are treated as regex matches against the corresponding field.
See `references/config-audit-policy.md` for suppression guidance and `references/config-audit-ignore.example.jsonc` for a ready-made example.

## History log

Apply results are appended to:

- `~/.openclaw/logs/config-history.jsonl`

Override with:

- `OPENCLAW_SAFE_CONFIG_HISTORY`

Current statuses written by the apply wrapper:

- `validation_failed`
- `success`
- `health_timeout`

## Notes

This local skill directory is the source of truth for the workspace copy. Public repo sync can be done separately after local validation.
