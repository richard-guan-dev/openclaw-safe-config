# Upgrade rollback matrix

Use this reference when the task is to upgrade OpenClaw itself rather than only edit `openclaw.json`.

## Core idea

A safe OpenClaw upgrade needs three separate layers:

1. **Preflight summary**: capture the current version, install kind, and pre-upgrade smoke-test result
2. **Config rollback**: restore the previous `openclaw.json`
3. **Binary/version rollback**: restore the previous OpenClaw install version or source checkout state

The bundled `openclaw_safe_upgrade.sh` script automates the package-install path and records pre-upgrade state for the rest.

## Preflight checklist

- Record `openclaw -V`
- Record `openclaw update status --json`
- Create a config backup copy
- Run `openclaw backup create --only-config --verify`
- Run the bundled smoke test before touching packages or files
- Run `openclaw update --dry-run ...`

## Smoke test profile

The bundled smoke test script currently checks:

- `openclaw config validate`
- `openclaw gateway health`
- `openclaw status`

Treat this as the minimum pass gate before and after a core upgrade.

## Rollback matrix

### installKind = package

This is the easiest path and the one the bundled script automates.

Rollback steps:

1. Use the recorded pre-upgrade version as the rollback target
2. Run `openclaw update --tag <previous-version> --yes --no-restart`
3. Restore the saved config copy
4. Restart the gateway
5. Re-run the smoke test

### installKind = git

This path is install-source-specific and should be treated as guided/manual unless you control the repo layout tightly.

Typical rollback steps:

1. Return to the recorded pre-upgrade commit or tag
2. Reinstall dependencies / rebuild as required by that checkout
3. Restore the saved config copy if the config changed during the attempt
4. Restart the gateway
5. Re-run the smoke test

### installKind = unknown / other

Do not invent a rollback command. Keep the pre-upgrade manifest, preserve the config backup, and fall back to the install method that was originally used on that machine.

## Logs

The upgrade script writes timestamped logs under `/tmp/` for:

- preflight summary / manifest
- pre-upgrade smoke test
- dry-run
- update
- restart
- health checks
- post-upgrade smoke test
- rollback

Inspect rollback logs before attempting a second upgrade pass.
