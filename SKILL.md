---
name: openclaw-safe-config
description: Safely plan, validate, apply, and roll back OpenClaw `openclaw.json` changes and package-based OpenClaw core upgrades. Use when modifying model/provider/alias settings, channel or gateway config, plugin config, or when running `openclaw update` with backup, preflight summary, smoke tests, health checks, and rollback guard. Also use when the user asks for safe restart, safe upgrade, or a rollback plan before touching OpenClaw.
---

# OpenClaw Safe Config

Use this skill whenever an OpenClaw change could strand the running gateway.

## Choose the path

- **Config-only change**: Use `scripts/openclaw_safe_config_apply.sh <candidate-config.json> [timeout-seconds]`
- **OpenClaw core upgrade**: Read `references/upgrade-rollback.md`, then use `scripts/openclaw_safe_upgrade.sh [openclaw-update-args...]`

## Config workflow

1. Identify the exact config keys to change. Use targeted schema lookup when field semantics are unclear.
2. Prepare a **candidate JSON file** first. Do not edit the live config and immediately restart.
3. If the change touches models or aliases, search active docs/scripts for live references and update active operator docs. Leave historical memory/media transcripts alone unless they drive current automation.
4. Apply the candidate with the bundled safe-apply script.
5. Treat `openclaw gateway health` as the real readiness check; process-alive alone is not enough.
6. After success, record the change in today's memory file and write one concise reusable lesson to the relevant self-improving file.

## Upgrade workflow

1. Capture the current state first: current version, `openclaw update status --json`, config backup, and preflight smoke-test result.
2. Run `openclaw update --dry-run` before the real upgrade.
3. Run the real update with `--no-restart` so file/package changes and service restart stay separate.
4. Arm an external rollback guard **before** restarting the gateway.
5. Require both `openclaw gateway health` and the bundled smoke test to pass after restart.
6. If health/smoke never recovers and the install kind is `package`, roll back to the exact pre-upgrade version and restore the saved config copy. If the install kind is not `package`, follow the manual matrix in `references/upgrade-rollback.md`.

## Guardrails

- Run `openclaw config validate` before restart after config changes. The config-apply script enforces this.
- Keep aliases unique. One alias should map to one model only.
- Keep timestamped backups after success; do not delete them in the same turn as the change.
- Prefer atomic replacement of the active config file over in-place editing.
- On failure, inspect rollback logs before trying ad-hoc fixes.
- Treat binary rollback as install-source-specific. The bundled upgrade script is deterministic for `package` installs and records enough state to drive manual rollback for other install kinds.

## Bundled resources

- `scripts/openclaw_safe_config_apply.sh`: deterministic apply/rollback wrapper for candidate configs
- `scripts/openclaw_safe_upgrade.sh`: package-oriented safe update wrapper with preflight summary, smoke tests, and rollback guard
- `scripts/openclaw_upgrade_smoke_test.sh`: minimal pre/post-upgrade smoke test profile
- `references/rollback-strategy.md`: config rollback triggers, log locations, and manual recovery checklist
- `references/upgrade-rollback.md`: install-source matrix and binary rollback notes
