# openclaw-safe-config

Safely plan, validate, apply, and roll back OpenClaw `openclaw.json` changes and package-based OpenClaw core upgrades.

## Contents

- `SKILL.md` — skill instructions
- `scripts/openclaw_safe_config_apply.sh` — safe config apply with backup, validate, health check, and rollback guard
- `scripts/openclaw_safe_upgrade.sh` — package-oriented safe OpenClaw upgrade workflow
- `scripts/openclaw_upgrade_smoke_test.sh` — minimal smoke test helper
- `references/` — rollback and upgrade notes

## Use cases

- Change model/provider/alias settings safely
- Change channel/gateway/plugin config with validation before restart
- Apply config candidates atomically instead of editing live config in place
- Run safer OpenClaw package upgrades with rollback planning

## Typical config workflow

```bash
scripts/openclaw_safe_config_apply.sh /path/to/candidate-config.json 120
```

## Typical upgrade workflow

```bash
scripts/openclaw_safe_upgrade.sh
```

## Notes

This repository contains local skill logic and helper scripts only. It does not include secrets or machine-specific credentials.
