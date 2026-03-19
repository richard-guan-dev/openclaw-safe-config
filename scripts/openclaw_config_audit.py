#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path


DEFAULT_IGNORE_FILE_CANDIDATES = [
    ".openclaw-config-audit-ignore.json",
    ".openclaw-config-audit-ignore.jsonc",
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def resolve_cfg_path() -> str:
    if os.environ.get("OPENCLAW_CONFIG_PATH"):
        return os.environ["OPENCLAW_CONFIG_PATH"]

    result = run(["bash", "-lc", "openclaw config file 2>/dev/null | awk 'NF { print; exit }'"])
    if result.returncode == 0:
        path = result.stdout.strip()
        if path:
            return os.path.expanduser(path)

    return os.path.expanduser("~/.openclaw/openclaw.json")


def load_json5(path: str):
    node_code = r'''
const fs = require("fs");
const JSON5 = require("json5");
const path = process.argv[1];
const obj = JSON5.parse(fs.readFileSync(path, "utf8"));
process.stdout.write(JSON.stringify(obj));
'''
    result = run(["node", "-e", node_code, path])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"failed to parse JSON5: {path}")
    return json.loads(result.stdout)


def extract_first_json_block(text: str):
    start = None
    opener = None
    for i, ch in enumerate(text):
        if ch in "[{":
            start = i
            opener = ch
            break
    if start is None:
        raise ValueError("no JSON block found")

    closer = "]" if opener == "[" else "}"
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    raise ValueError("unterminated JSON block")


def load_effective_models(raw_cfg):
    if os.environ.get("OPENCLAW_CONFIG_PATH"):
        return raw_cfg.get("models", {})

    result = run(["bash", "-lc", "openclaw config get models 2>/dev/null"])
    if result.returncode != 0 or not result.stdout.strip():
        return raw_cfg.get("models", {})

    try:
        block = extract_first_json_block(result.stdout)
        return json.loads(block)
    except Exception:
        return raw_cfg.get("models", {})


def collect_catalog(model_cfg):
    catalog = set()
    providers = (model_cfg or {}).get("providers", {})
    if isinstance(providers, dict):
        for provider_id, provider in providers.items():
            models = provider.get("models", []) if isinstance(provider, dict) else []
            if isinstance(models, list):
                for model in models:
                    if isinstance(model, dict) and isinstance(model.get("id"), str):
                        catalog.add(f"{provider_id}/{model['id']}")
    return catalog


def collect_aliases(cfg):
    aliases = defaultdict(list)
    models = (((cfg.get("agents") or {}).get("defaults") or {}).get("models") or {})
    if isinstance(models, dict):
        for model_ref, meta in models.items():
            if isinstance(meta, dict) and isinstance(meta.get("alias"), str):
                aliases[meta["alias"]].append(model_ref)
    return aliases


def collect_refs(cfg):
    refs = []
    defaults = ((cfg.get("agents") or {}).get("defaults") or {}).get("model") or {}
    primary = defaults.get("primary")
    if isinstance(primary, str):
        refs.append(("agents.defaults.model.primary", primary))
    fallbacks = defaults.get("fallbacks") or []
    if isinstance(fallbacks, list):
        for i, ref in enumerate(fallbacks):
            if isinstance(ref, str):
                refs.append((f"agents.defaults.model.fallbacks[{i}]", ref))

    agents = ((cfg.get("agents") or {}).get("list") or [])
    if isinstance(agents, list):
        for i, agent in enumerate(agents):
            if isinstance(agent, dict) and isinstance(agent.get("model"), str):
                refs.append((f"agents.list[{i}].model", agent["model"]))
    return refs


def walk(obj, path=""):
    if isinstance(obj, dict):
        for key, value in obj.items():
            next_path = f"{path}.{key}" if path else key
            yield from walk(value, next_path)
    elif isinstance(obj, list):
        for i, value in enumerate(obj):
            next_path = f"{path}[{i}]"
            yield from walk(value, next_path)
    else:
        yield path, obj


def classify_secret_path(path: str, value):
    if not isinstance(value, str):
        return False
    if value.startswith("${") or value.startswith("__OPENCLAW_REDACTED__"):
        return False
    if value.strip() != value:
        return False

    leaf = re.split(r"[.\[]", path)[-1].lower()
    if re.search(r"(apikey|api_key|token|secret|password|passwd)", leaf):
        if leaf in {"source", "provider", "id"}:
            return False
        return True
    return False


def normalize_rule(rule):
    if not isinstance(rule, dict):
        raise ValueError(f"ignore rule must be an object, got: {type(rule).__name__}")
    normalized = {}
    for key, value in rule.items():
        if isinstance(value, (str, int, float, bool)) or value is None:
            normalized[key] = value
        else:
            raise ValueError(f"ignore rule field '{key}' must be scalar")
    if not normalized:
        raise ValueError("ignore rule cannot be empty")
    return normalized


def load_ignore_file(path):
    raw = load_json5(path)
    if isinstance(raw, list):
        rules = raw
    elif isinstance(raw, dict) and isinstance(raw.get("ignore"), list):
        rules = raw["ignore"]
    else:
        raise ValueError("ignore file must be a JSON array or an object with an 'ignore' array")
    return [normalize_rule(rule) for rule in rules]


def find_default_ignore_file(cfg_path):
    cfg_dir = str(Path(cfg_path).resolve().parent)
    for name in DEFAULT_IGNORE_FILE_CANDIDATES:
        candidate = Path(cfg_dir) / name
        if candidate.is_file():
            return str(candidate)
    return None


def build_cli_ignore_rules(args):
    rules = []
    for kind in args.ignore_kind:
        rules.append({"kind": kind})
    for alias in args.ignore_alias:
        rules.append({"alias": alias})
    for pattern in args.ignore_path_regex:
        rules.append({"pathRegex": pattern})
    return rules


def item_matches_rule(item, rule):
    for key, expected in rule.items():
        if key.endswith("Regex"):
            field = key[:-5]
            actual = item.get(field)
            if not isinstance(actual, str):
                return False
            if re.search(str(expected), actual) is None:
                return False
        else:
            if item.get(key) != expected:
                return False
    return True


def partition_ignored(items, rules, bucket_name):
    kept = []
    ignored = []
    for item in items:
        matched_rule = None
        for rule in rules:
            if item_matches_rule(item, rule):
                matched_rule = rule
                break
        if matched_rule is None:
            kept.append(item)
            continue
        ignored.append({
            "bucket": bucket_name,
            "item": item,
            "rule": matched_rule,
        })
    return kept, ignored


def main():
    parser = argparse.ArgumentParser(description="Audit OpenClaw config for common safety issues")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of human-readable text")
    parser.add_argument("--ignore-file", help="JSON/JSONC file containing ignore rules")
    parser.add_argument("--no-default-ignore-file", action="store_true", help="do not auto-load .openclaw-config-audit-ignore.json(.jsonc) from the config directory")
    parser.add_argument("--ignore-kind", action="append", default=[], help="suppress all findings of a given kind (repeatable)")
    parser.add_argument("--ignore-alias", action="append", default=[], help="suppress findings matching a specific alias (repeatable)")
    parser.add_argument("--ignore-path-regex", action="append", default=[], help="suppress findings whose path matches the regex (repeatable)")
    args = parser.parse_args()

    cfg_path = resolve_cfg_path()
    if not Path(cfg_path).is_file():
        print(f"Active config not found: {cfg_path}", file=sys.stderr)
        sys.exit(2)

    cfg = load_json5(cfg_path)
    effective_models = load_effective_models(cfg)
    catalog = collect_catalog(effective_models)
    aliases = collect_aliases(cfg)

    ignore_rules = []
    ignore_file = None
    default_ignore_file = None
    if not args.no_default_ignore_file:
        default_ignore_file = find_default_ignore_file(cfg_path)
        if default_ignore_file:
            ignore_rules.extend(load_ignore_file(default_ignore_file))
            ignore_file = default_ignore_file
    if args.ignore_file:
        ignore_rules.extend(load_ignore_file(args.ignore_file))
        ignore_file = args.ignore_file
    ignore_rules.extend(build_cli_ignore_rules(args))

    errors = []
    warnings = []

    # Duplicate alias ownership
    for alias, owners in sorted(aliases.items()):
        if len(owners) > 1:
            errors.append({
                "kind": "duplicate_alias",
                "alias": alias,
                "owners": owners,
                "message": f"alias '{alias}' is assigned to multiple model refs: {', '.join(owners)}",
            })

    # Alias target existence
    for alias, owners in sorted(aliases.items()):
        owner = owners[0]
        if catalog and owner not in catalog:
            warnings.append({
                "kind": "alias_target_unknown",
                "alias": alias,
                "owner": owner,
                "message": f"alias '{alias}' points to model ref not found in effective catalog: {owner}",
            })

    # Agent/default model refs
    alias_names = set(aliases.keys())
    for path, ref in collect_refs(cfg):
        if ref in alias_names:
            continue
        if "/" in ref:
            if catalog and ref not in catalog:
                errors.append({
                    "kind": "unknown_model_ref",
                    "path": path,
                    "value": ref,
                    "message": f"{path} references model ref not found in effective catalog: {ref}",
                })
        else:
            warnings.append({
                "kind": "unresolved_model_name",
                "path": path,
                "value": ref,
                "message": f"{path} is neither an alias nor a provider/model ref: {ref}",
            })

    # Duplicate agent ids
    agents = ((cfg.get("agents") or {}).get("list") or [])
    agent_ids = [a.get("id") for a in agents if isinstance(a, dict) and isinstance(a.get("id"), str)]
    for agent_id, count in sorted(Counter(agent_ids).items()):
        if count > 1:
            errors.append({
                "kind": "duplicate_agent_id",
                "agentId": agent_id,
                "count": count,
                "message": f"agent id '{agent_id}' appears {count} times",
            })

    # Duplicate provider-local model ids
    providers = ((cfg.get("models") or {}).get("providers") or {})
    if isinstance(providers, dict):
        for provider_id, provider in sorted(providers.items()):
            models = provider.get("models", []) if isinstance(provider, dict) else []
            ids = [m.get("id") for m in models if isinstance(m, dict) and isinstance(m.get("id"), str)]
            for model_id, count in sorted(Counter(ids).items()):
                if count > 1:
                    errors.append({
                        "kind": "duplicate_provider_model_id",
                        "provider": provider_id,
                        "modelId": model_id,
                        "count": count,
                        "message": f"provider '{provider_id}' contains duplicate model id '{model_id}' ({count} times)",
                    })

    # Inline secret candidates
    for path, value in walk(cfg):
        if classify_secret_path(path, value):
            warnings.append({
                "kind": "inline_secret_candidate",
                "path": path,
                "message": f"{path} looks like an inline secret string; prefer SecretRef/env indirection",
            })

    errors, ignored_errors = partition_ignored(errors, ignore_rules, "errors")
    warnings, ignored_warnings = partition_ignored(warnings, ignore_rules, "warnings")
    ignored = ignored_errors + ignored_warnings

    status = "OK"
    if errors:
        status = "FAIL"
    elif warnings:
        status = "WARN"

    result = {
        "configPath": cfg_path,
        "status": status,
        "errorCount": len(errors),
        "warningCount": len(warnings),
        "ignoredCount": len(ignored),
        "catalogSize": len(catalog),
        "ignoreRuleCount": len(ignore_rules),
        "ignoreFile": ignore_file,
        "errors": errors,
        "warnings": warnings,
        "ignored": ignored,
    }

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    print("AUDIT")
    print(f"config_path={result['configPath']}")
    print(f"status={result['status']}")
    print(f"error_count={result['errorCount']}")
    print(f"warning_count={result['warningCount']}")
    print(f"ignored_count={result['ignoredCount']}")
    print(f"catalog_size={result['catalogSize']}")
    if result["ignoreFile"]:
        print(f"ignore_file={result['ignoreFile']}")
    print(f"ignore_rule_count={result['ignoreRuleCount']}")

    for item in errors:
        print(f"ERROR {item['kind']}: {item['message']}")
    for item in warnings:
        print(f"WARN {item['kind']}: {item['message']}")
    for entry in ignored:
        item = entry["item"]
        rule = json.dumps(entry["rule"], ensure_ascii=False, sort_keys=True)
        print(f"IGNORED {entry['bucket']} {item['kind']}: {item['message']} [rule={rule}]")


if __name__ == "__main__":
    main()
