# Rollback strategy

Use this reference when a safe config apply stalls or fails.

## What counts as failure

- Candidate JSON is syntactically invalid
- `openclaw config validate` fails after swapping in the candidate
- `openclaw gateway restart` returns non-zero
- `openclaw gateway health` does not recover before the timeout

## Default recovery path

The bundled script already does this:

1. Keep a timestamped backup of the active config
2. Restore the backup if validation fails
3. Start a detached rollback guard before restarting
4. Poll `openclaw gateway health`
5. If health never returns, restore backup and restart again

## Logs to inspect

The apply script writes timestamped logs under `/tmp/`:

- `openclaw-safe-config-*.validate.log`
- `openclaw-safe-config-*.restart.log`
- `openclaw-safe-config-*.health.log`
- `openclaw-safe-config-*.rollback.log`

## Manual recovery checklist

1. Read the latest rollback log and validate log first
2. Confirm the active config path is `~/.openclaw/openclaw.json`
3. If the rollback guard restored a backup, re-run `openclaw config validate`
4. Check `openclaw gateway health`
5. Only make a second config attempt after identifying the exact bad key/path

## Common lessons

- Config changes should start from a candidate copy, not live-file surgery
- Health checks beat simple process checks
- Alias collisions are config debt; resolve them before they cause ambiguous routing
