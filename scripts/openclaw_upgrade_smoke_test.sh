#!/usr/bin/env bash
set -euo pipefail

echo "== openclaw config validate =="
openclaw config validate

echo
echo "== openclaw gateway health =="
openclaw gateway health

echo
echo "== openclaw status =="
openclaw status
