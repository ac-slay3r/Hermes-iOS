#!/usr/bin/env bash
# Fast unsigned Linux/macOS iteration; this is NOT native iOS/release evidence.
# Optional: RELAY_PYTHON=/absolute/venv/bin/python CONNECTOR_PYTHON=/absolute/venv/bin/python
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_PYTHON="${RELAY_PYTHON:-$ROOT/relay/.venv/bin/python}"
if [[ -z "${CONNECTOR_PYTHON:-}" ]]; then
  CONNECTOR_PYTHON="$ROOT/connector/.venv/bin/python"
  if [[ ! -x "$CONNECTOR_PYTHON" ]]; then
    CONNECTOR_PYTHON="$ROOT/../upstream/connector/.venv/bin/python"
  fi
fi
# Resolve overrides before changing directory. Never install dependencies silently.
for name in RELAY_PYTHON CONNECTOR_PYTHON; do
  interpreter="$(command -v -- "${!name}" || true)"
  if [[ -z "$interpreter" || ! -x "$interpreter" ]]; then
    printf 'Missing %s interpreter: %s; create the project dev venv or set an explicit interpreter.\n' "$name" "${!name}" >&2
    exit 1
  fi
  if [[ "$interpreter" != /* ]]; then interpreter="$PWD/$interpreter"; fi
  printf -v "$name" '%s' "$interpreter"
done
cd "$ROOT"
"$RELAY_PYTHON" -m unittest discover -s scripts/tests -v
(cd "$ROOT/relay" && PYTHONPATH="$ROOT/relay" "$RELAY_PYTHON" -m pytest)
(cd "$ROOT/connector" && PYTHONPATH="$ROOT/connector/src" "$CONNECTOR_PYTHON" -m pytest)
printf '\nLocal Python checks passed. Native iOS CI and TestFlight gates are still required.\n'
