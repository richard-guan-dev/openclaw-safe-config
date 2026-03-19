# Config Audit Suppression Policy

Use suppression rules to hide **accepted, well-understood noise** without weakening the audit for everything else.

## Rule of thumb

Prefer the narrowest rule that matches the accepted finding:

1. exact `kind` + exact field match (best)
2. exact `kind` + narrow `pathRegex`
3. exact `kind` only (last resort)

Do **not** suppress a whole finding kind just because one instance is expected.

## Good uses

- a known alias intentionally points at a provider/model ref that is unavailable on this host
- a secret-warning path is intentionally tolerated during migration and has a clear follow-up plan
- a legacy config path is temporarily accepted while staged changes are in progress

## Bad uses

- suppressing all `inline_secret_candidate` warnings globally
- suppressing all `alias_target_unknown` findings because one provider is optional
- using broad regexes like `token` or `secret` that hide unrelated future issues

## Recommended workflow

1. Run the audit without suppressions first.
2. Confirm the finding is real but intentionally accepted.
3. Add the narrowest ignore rule possible.
4. Re-run the audit and verify only the intended finding disappeared.
5. Keep the reason documented in the ignore file when the exception is long-lived.

## File locations

Auto-loaded ignore files live beside the active config:

- `.openclaw-config-audit-ignore.json`
- `.openclaw-config-audit-ignore.jsonc`

Ad-hoc runs can also use `--ignore-file /path/to/file.json`.

## Example

```json
{
  "ignore": [
    {
      "kind": "alias_target_unknown",
      "alias": "vertex-gemini-flash"
    },
    {
      "kind": "inline_secret_candidate",
      "pathRegex": "^channels\\.discord\\.token$"
    }
  ]
}
```

## Review guidance

Review suppressions when:

- providers/models are added or removed
- secrets are moved to env/SecretRef indirection
- a migration completes
- an ignore rule has existed long enough that nobody remembers why

Delete stale suppressions aggressively. A smaller allowlist is safer.
